import git from "isomorphic-git";
import {
  decryptManifestBody,
  isEncryptedManifest,
  loadAndUnwrapKEK,
  parseEncryptedManifestHeader,
  unwrapDEK,
} from "./encryption";
import type { LfsPointerFields } from "./encryption";
import { ManifestRegistry } from "./manifestRegistry";
import type { RegisteredManifestRecord } from "./manifestRegistry";
import type { AgePrivateKeyProvider } from "./syncTypes";
import type { FsClient } from "./fsClient";
import {
  DATABASE_VERSION_PATH,
  DatabaseVersionError,
  requireSupportedDatabaseVersion,
} from "./databaseVersion";

// Serializes decrypted key bytes so pointer rows can persist ready-to-use DEKs.
const bytesToBase64 = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes));

// Owns blob-level manifest/pointer reads so sync flows can share one decryption cache.
export class ManifestBlobReader {
  private readonly fs: FsClient;
  private readonly gitdir: string;
  private readonly registry: ManifestRegistry;
  private readonly agePrivateKeyProvider: AgePrivateKeyProvider;
  private readonly kekCache = new Map<number, CryptoKey>();
  private encryptionCurrentBlobOid: string | null = null;
  // Shared isomorphic-git pack-index cache so every readBlob this class issues
  // reuses the parsed .idx across calls and across other gitdb collaborators.
  private readonly cache: object;

  // Captures read/decode dependencies once so orchestration code avoids wiring noise.
  constructor(opts: {
    fs: FsClient;
    gitdir: string;
    registry: ManifestRegistry;
    agePrivateKeyProvider: AgePrivateKeyProvider;
    cache: object;
  }) {
    this.fs = opts.fs;
    this.gitdir = opts.gitdir;
    this.registry = opts.registry;
    this.agePrivateKeyProvider = opts.agePrivateKeyProvider;
    this.cache = opts.cache;
  }

  // Reads one blob at commit/path and returns null when that path is absent.
  async readBlobAtCommitPathOrNull(
    commitHash: string,
    filepath: string,
  ): Promise<{ blob: Uint8Array; oid: string } | null> {
    try {
      const result = await git.readBlob({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: commitHash,
        filepath,
        cache: this.cache,
      });
      return {
        blob: result.blob as Uint8Array,
        oid: result.oid,
      };
    } catch {
      return null;
    }
  }

  // Reads one blob object by OID so callers that already computed diffs can
  // avoid re-walking commit trees by path.
  async readBlobByOidOrNull(
    oid: string,
  ): Promise<Uint8Array | null> {
    try {
      const result = await git.readBlob({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid,
        cache: this.cache,
      });
      return result.blob as Uint8Array;
    } catch {
      return null;
    }
  }

  // Refuses a commit whose gitdb/version is missing or not the pinned
  // format so sync never decrypts an unrecognized repository layout.
  async assertSupportedDatabaseVersion(commitHash: string): Promise<void> {
    const entry = await this.readBlobAtCommitPathOrNull(commitHash, DATABASE_VERSION_PATH);
    if (!entry) {
      throw new DatabaseVersionError("missing gitdb/version");
    }
    requireSupportedDatabaseVersion(entry.blob);
  }

  // Invalidates cached KEKs when encryption/current changes to prevent stale key reuse.
  async refreshKekCacheState(commitHash: string): Promise<void> {
    const currentEntry = await this.readBlobAtCommitPathOrNull(commitHash, "encryption/current");
    const nextOid = currentEntry?.oid ?? null;
    if (nextOid === this.encryptionCurrentBlobOid) return;
    this.kekCache.clear();
    this.encryptionCurrentBlobOid = nextOid;
  }

  // Loads one KEK epoch from git and caches it for repeated decrypt/unwrap operations.
  async loadKekEpoch(commitHash: string, epoch: number): Promise<CryptoKey> {
    const cached = this.kekCache.get(epoch);
    if (cached) return cached;
    const agePrivateKeyBase64 = this.agePrivateKeyProvider();
    if (!agePrivateKeyBase64) {
      throw new Error("Age private key is required for encrypted manifest decryption.");
    }
    const epochEntry = await this.readBlobAtCommitPathOrNull(commitHash, `encryption/epochs/${epoch}.age`);
    if (!epochEntry) {
      throw new Error(`Missing KEK epoch file encryption/epochs/${epoch}.age.`);
    }
    const key = await loadAndUnwrapKEK(epochEntry.blob, agePrivateKeyBase64);
    this.kekCache.set(epoch, key);
    return key;
  }

  // Unwraps DEKs in pointer rows so persistence stores normalized dekBase64 values.
  async unwrapDeksForPointers(
    commitHash: string,
    pointers: Map<string, LfsPointerFields>,
    onProgress?: (loaded: number, total: number) => void,
  ): Promise<void> {
    let done = 0;
    const total = pointers.size;
    await Promise.all(
      [...pointers.values()].map(async (pointer) => {
        if (!pointer.wrappedDek || !pointer.kekEpoch) {
          done += 1;
          onProgress?.(done, total);
          return;
        }
        const kek = await this.loadKekEpoch(commitHash, pointer.kekEpoch);
        const dekRaw = await unwrapDEK(pointer.wrappedDek, kek, pointer.kekEpoch);
        pointer.dekBase64 = bytesToBase64(dekRaw);
        done += 1;
        onProgress?.(done, total);
      }),
    );
  }

  // Decrypts one encrypted manifest envelope so sync never accepts plaintext
  // YAML that a hostile server could substitute for ciphertext.
  async decodeManifestBlobToYaml(commitHash: string, blob: Uint8Array): Promise<string> {
    if (!isEncryptedManifest(blob)) {
      throw new Error("plaintext manifest rejected: missing REPLYCANT-ENC-V1 envelope");
    }
    const encrypted = parseEncryptedManifestHeader(blob);
    const kek = await this.loadKekEpoch(commitHash, encrypted.kekEpoch);
    return decryptManifestBody(encrypted.ciphertext, kek);
  }

  // Decodes YAML via registry and resolves stable record identity for persistence.
  decodeYamlToRecord(
    rawYaml: string,
    expectedKind?: { apiVersion: string; kind: string } | null,
  ): RegisteredManifestRecord | null {
    const decoded = expectedKind
      ? this.registry.decodeYamlForExpectedKind(rawYaml, expectedKind)
      : this.registry.decodeYaml(rawYaml);
    if (!decoded) return null;
    const key = this.registry.resolveKey(decoded.apiVersion, decoded.kind, decoded.decoded);
    return {
      apiVersion: decoded.apiVersion,
      kind: decoded.kind,
      key,
      manifest: decoded.decoded,
    };
  }

  // Reads one manifest blob at a commit/path and returns a decoded record or null.
  async readManifestRecordAtCommitOrNull(
    commitHash: string,
    path: string,
  ): Promise<RegisteredManifestRecord | null> {
    const entry = await this.readBlobAtCommitPathOrNull(commitHash, path);
    if (!entry) return null;
    const rawYaml = await this.decodeManifestBlobToYaml(commitHash, entry.blob);
    return this.decodeYamlToRecord(rawYaml, this.inferExpectedKindFromPath(path));
  }

  // Decodes one manifest from a known blob OID so transition planners can
  // classify changes without resolving each path from the commit root again.
  async readManifestRecordAtBlobOid(
    commitHash: string,
    blobOid: string,
    path: string,
  ): Promise<RegisteredManifestRecord | null> {
    const blob = await this.readBlobByOidOrNull(blobOid);
    if (!blob) return null;
    const rawYaml = await this.decodeManifestBlobToYaml(commitHash, blob);
    return this.decodeYamlToRecord(rawYaml, this.inferExpectedKindFromPath(path));
  }

  // Derives expected apiVersion/kind from canonical manifest path structure.
  inferExpectedKindFromPath(manifestPath: string): { apiVersion: string; kind: string } | null {
    const parts = manifestPath.split("/");
    if (parts.length < 5) return null;
    const apiVersionPart1 = parts[2];
    const apiVersionPart2 = parts[3];
    const kind = parts[4];
    if (!apiVersionPart1 || !apiVersionPart2 || !kind) return null;
    return { apiVersion: `${apiVersionPart1}/${apiVersionPart2}`, kind };
  }
}
