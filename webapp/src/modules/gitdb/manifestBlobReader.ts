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
  DatabaseVersionUnreadableError,
  parseDatabaseVersion,
  requireAcceptedDatabaseVersion,
} from "./databaseVersion";

// Distinguishes isomorphic-git "path is not in this tree" from a
// failed object read so absence can be proven instead of guessed.
const isNotFoundError = (error: unknown): boolean => {
  if (!(error instanceof Error)) return false;
  const code = (error as Error & { code?: string }).code;
  if (code === "NotFoundError" || error.name === "NotFoundError") return true;
  const message = error.message.toLowerCase();
  return message.includes("does not exist") || message.includes("filepath");
};

// Serializes decrypted key bytes so pointer rows can persist ready-to-use DEKs.
const bytesToBase64 = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes));

// A key set this client opened is unreadable. Sync must stop and leave
// the cache untouched: falling back to another key would hide a swap.
export class EncryptionIntegrityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EncryptionIntegrityError";
  }
}

const spaceModeStorageKey = (gitdir: string, space: string): string =>
  `replycant.encryptionSpaceMode.${gitdir}.${space}`;

// The pin survives a reload. Storage can be unavailable in a worker
// or a private window; the in-memory pin still covers the session.
const readStoredSpaceMode = (gitdir: string, space: string): "own" | "global" | null => {
  try {
    const value = globalThis.localStorage?.getItem(spaceModeStorageKey(gitdir, space));
    return value === "own" || value === "global" ? value : null;
  } catch {
    return null;
  }
};

const writeStoredSpaceMode = (gitdir: string, space: string, mode: "own" | "global"): void => {
  try {
    globalThis.localStorage?.setItem(spaceModeStorageKey(gitdir, space), mode);
  } catch {
    // The in-memory pin is enough when storage is blocked.
  }
};

// Owns blob-level manifest/pointer reads so sync flows can share one decryption cache.
export class ManifestBlobReader {
  private readonly fs: FsClient;
  private readonly gitdir: string;
  private readonly registry: ManifestRegistry;
  private readonly agePrivateKeyProvider: AgePrivateKeyProvider;
  private readonly kekCache = new Map<string, CryptoKey>();
  private encryptionCurrentBlobOid: string | null = null;
  private readonly spaceModes = new Map<string, "own" | "global">();
  // One commit names a handful of spaces, but a full resync asks which
  // key set a space uses once per manifest. The answer is fixed for
  // that commit, so the first lookup is remembered.
  private readonly keySetRoots = new Map<string, string>();
  private keySetCommit: string | null = null;
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

  // Reads gitdb/version by filepath after proving the commit exists
  // so sync can compare the observed format against the local cache.
  // A readable tree with no `gitdb` path is a missing marker, which
  // is an error. A failed object read is not absence.
  async inspectDatabaseVersion(commitHash: string): Promise<{ version: number; rootPaths: string[] }> {
    let commit;
    try {
      commit = await git.readCommit({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: commitHash,
        cache: this.cache,
      });
    } catch (error) {
      throw new DatabaseVersionUnreadableError(
        `could not read gitdb/version at ${commitHash}`,
        { cause: error },
      );
    }
    try {
      const blob = await git.readBlob({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: commitHash,
        filepath: DATABASE_VERSION_PATH,
        cache: this.cache,
      });
      return {
        version: parseDatabaseVersion(blob.blob as Uint8Array),
        rootPaths: [],
      };
    } catch (error) {
      if (error instanceof DatabaseVersionError) {
        throw error;
      }
      let rootPaths: string[];
      try {
        const root = await git.readTree({
          fs: this.fs,
          dir: this.gitdir,
          gitdir: this.gitdir,
          oid: commit.commit.tree,
          cache: this.cache,
        });
        rootPaths = root.tree.map((entry) => entry.path);
      } catch (treeError) {
        throw new DatabaseVersionUnreadableError(
          `could not read gitdb/version at ${commitHash}`,
          { cause: treeError },
        );
      }
      if (isNotFoundError(error) && !rootPaths.includes("gitdb")) {
        throw new DatabaseVersionError("gitdb/version is missing");
      }
      throw new DatabaseVersionUnreadableError(
        `could not read gitdb/version at ${commitHash}`,
        { cause: error },
      );
    }
  }

  async readDatabaseVersion(commitHash: string): Promise<number> {
    return (await this.inspectDatabaseVersion(commitHash)).version;
  }

  // Returns the observed format when the tree is readable, or null
  // when the objects cannot be opened yet. Callers that must not
  // fail use this instead of treating a throw as absence.
  async readDatabaseVersionOrNull(commitHash: string): Promise<number | null> {
    try {
      return await this.readDatabaseVersion(commitHash);
    } catch (error) {
      if (error instanceof DatabaseVersionError) {
        throw error;
      }
      return null;
    }
  }

  // Refuses a commit whose gitdb/version is not in the accepted set
  // so sync never decrypts an unrecognized repository layout.
  async assertSupportedDatabaseVersion(commitHash: string): Promise<void> {
    requireAcceptedDatabaseVersion(await this.readDatabaseVersion(commitHash));
  }

  // Invalidates cached KEKs when a key set's current epoch changes.
  // Rewrapping an epoch keeps the same key bytes, so the cache stays valid
  // until current moves. A new commit can point a space at a different
  // key set even when the library epoch blob is unchanged, so the
  // per-commit key-set answers are dropped with the commit.
  async refreshKekCacheState(commitHash: string): Promise<void> {
    if (commitHash !== this.keySetCommit) {
      this.keySetRoots.clear();
      this.keySetCommit = commitHash;
    }
    const currentEntry = await this.readBlobAtCommitPathOrNull(commitHash, "encryption/current");
    const nextOid = currentEntry?.oid ?? null;
    if (nextOid === this.encryptionCurrentBlobOid) return;
    this.kekCache.clear();
    this.encryptionCurrentBlobOid = nextOid;
  }

  // The path chooses the key set. A missing space current means the
  // space uses the library key. Remembering that choice refuses a
  // later file that adds or removes the space's own key set. Later
  // manifests in the same commit reuse that answer.
  async keySetRoot(commitHash: string, path: string): Promise<string> {
    const space = spaceFromManifestPath(path);
    if (!space) return "encryption";
    const cacheKey = `${commitHash}\n${space}`;
    const cached = this.keySetRoots.get(cacheKey);
    if (cached) return cached;
    const currentPath = `encryptionspaces/${space}/encryption/current`;
    const current = await this.readBlobAtCommitPathOrNull(commitHash, currentPath);
    const mode = current ? "own" : "global";
    const previous = this.spaceModes.get(space) ?? readStoredSpaceMode(this.gitdir, space);
    if (previous && previous !== mode) {
      throw new EncryptionIntegrityError(
        `Could not open ${space}: the space changed key set.`,
      );
    }
    if (!previous) {
      this.spaceModes.set(space, mode);
      writeStoredSpaceMode(this.gitdir, space, mode);
    } else if (!this.spaceModes.has(space)) {
      this.spaceModes.set(space, previous);
    }
    const root = current ? `encryptionspaces/${space}/encryption` : "encryption";
    this.keySetRoots.set(cacheKey, root);
    return root;
  }

  // Loads one KEK epoch from one key set. The same epoch number in
  // another space is a different key.
  async loadKekEpoch(commitHash: string, epoch: number, root = "encryption"): Promise<CryptoKey> {
    const cacheKey = `${root}\n${epoch}`;
    const cached = this.kekCache.get(cacheKey);
    if (cached) return cached;
    const agePrivateKeyBase64 = this.agePrivateKeyProvider();
    if (!agePrivateKeyBase64) {
      throw new Error("Age private key is required for encrypted manifest decryption.");
    }
    const epochPath = `${root}/epochs/${epoch}.age`;
    const epochEntry = await this.readBlobAtCommitPathOrNull(commitHash, epochPath);
    if (!epochEntry) {
      throw new EncryptionIntegrityError(`Could not open ${root}: missing key epoch ${epoch}.`);
    }
    const key = await loadAndUnwrapKEK(epochEntry.blob, agePrivateKeyBase64);
    this.kekCache.set(cacheKey, key);
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
      [...pointers.entries()].map(async ([path, pointer]) => {
        if (!pointer.wrappedDek || !pointer.kekEpoch) {
          done += 1;
          onProgress?.(done, total);
          return;
        }
        const root = await this.keySetRoot(commitHash, path);
        const kek = await this.loadKekEpoch(commitHash, pointer.kekEpoch, root);
        let dekRaw: Uint8Array;
        try {
          dekRaw = await unwrapDEK(pointer.wrappedDek, kek, pointer.kekEpoch);
        } catch (error) {
          if (error instanceof EncryptionIntegrityError) throw error;
          const space = spaceFromManifestPath(path) ?? "library";
          throw new EncryptionIntegrityError(
            `Could not open ${space} (${path}): the object did not open.`,
          );
        }
        pointer.dekBase64 = bytesToBase64(dekRaw);
        done += 1;
        onProgress?.(done, total);
      }),
    );
  }

  // Decrypts one encrypted manifest envelope so sync never accepts plaintext
  // YAML that a hostile server could substitute for ciphertext.
  async decodeManifestBlobToYaml(commitHash: string, blob: Uint8Array, path = ""): Promise<string> {
    const space = spaceFromManifestPath(path) ?? "library";
    const label = path || "manifest";
    if (!isEncryptedManifest(blob)) {
      throw new EncryptionIntegrityError(
        `Could not open ${space} (${label}): the manifest is plaintext.`,
      );
    }
    const encrypted = parseEncryptedManifestHeader(blob);
    const root = path ? await this.keySetRoot(commitHash, path) : "encryption";
    try {
      const kek = await this.loadKekEpoch(commitHash, encrypted.kekEpoch, root);
      return await decryptManifestBody(encrypted.ciphertext, kek);
    } catch (error) {
      if (error instanceof EncryptionIntegrityError) throw error;
      throw new EncryptionIntegrityError(
        `Could not open ${space} (${label}): the manifest did not open.`,
      );
    }
  }

  // Decodes YAML via registry and resolves stable record identity for persistence.
  // The path's space overwrites metadata.deviceSpace so a stale field
  // cannot point the cache at a different encryption space.
  decodeYamlToRecord(
    rawYaml: string,
    expectedKind?: { apiVersion: string; kind: string } | null,
    path?: string,
  ): RegisteredManifestRecord | null {
    const decoded = expectedKind
      ? this.registry.decodeYamlForExpectedKind(rawYaml, expectedKind)
      : this.registry.decodeYaml(rawYaml);
    if (!decoded) return null;
    const space = path ? spaceFromManifestPath(path) : null;
    if (space && decoded.decoded && typeof decoded.decoded === "object") {
      const metadata = (decoded.decoded as { metadata?: { deviceSpace?: string } }).metadata;
      if (metadata) metadata.deviceSpace = space;
    }
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
    const rawYaml = await this.decodeManifestBlobToYaml(commitHash, entry.blob, path);
    return this.decodeYamlToRecord(rawYaml, this.inferExpectedKindFromPath(path), path);
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
    const rawYaml = await this.decodeManifestBlobToYaml(commitHash, blob, path);
    return this.decodeYamlToRecord(rawYaml, this.inferExpectedKindFromPath(path), path);
  }

  // Derives expected apiVersion/kind from canonical manifest path structure.
  inferExpectedKindFromPath(manifestPath: string): { apiVersion: string; kind: string } | null {
    const parts = manifestPath.split("/");
    if (parts[0] !== "encryptionspaces" || parts[2] !== "manifests" || parts.length < 6) return null;
    const apiVersionPart1 = parts[3];
    const apiVersionPart2 = parts[4];
    const kind = parts[5];
    if (!apiVersionPart1 || !apiVersionPart2 || !kind) return null;
    return { apiVersion: `${apiVersionPart1}/${apiVersionPart2}`, kind };
  }
}

// The space name is the directory under encryptionspaces. Files that
// are not manifests or binaries do not name a space.
export const spaceFromManifestPath = (path: string): string | null => {
  const parts = path.split("/");
  if (parts[0] !== "encryptionspaces" || (parts[2] !== "manifests" && parts[2] !== "binary")) {
    return null;
  }
  return parts[1] ? parts[1] : null;
};
