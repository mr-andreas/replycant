import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { promises as fs } from "node:fs";
import { spawn } from "node:child_process";
import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { x25519 } from "@noble/curves/ed25519.js";
import { encryptManifestYaml as encryptManifestYamlShared } from "../modules/gitdb/testEncryption";

export interface SyntheticGitRepoOptions {
  baselineCommitCount: number;
  manifestCount: number;
  deviceSpaceCount: number;
  treeFanout: number;
}

export interface SyntheticGitRepoFixture {
  rootDir: string;
  remoteDir: string;
  writerDir: string;
  apiBasePath: string;
  remoteUrl: string;
  agePrivateKeyBase64: string;
  baselineHead: string;
  getRemoteObjectCount: () => Promise<number>;
  resetRemoteToBaseline: () => Promise<void>;
  appendSingleCommit: () => Promise<string>;
  dispose: () => Promise<void>;
}

interface GitHttpServer {
  baseUrl: string;
  close: () => Promise<void>;
}

interface ParsedCgiHeaders {
  statusCode: number;
  headers: Record<string, string>;
  body: Buffer;
}

interface SyntheticMediaEntry {
  index: number;
  deviceSpace: string;
  fileName: string;
  mediaType: "photo" | "video";
  mimeType: string;
  width: number;
  height: number;
  durationSeconds?: number;
  createdAt: string;
  takenAt: string;
  originalManifestPath: string;
  originalPointerPath: string;
  thumbnailManifestPath: string;
  thumbnailPointerPaths: string[];
}

interface EncryptionFixtureState {
  agePrivateKeyBase64: string;
  kekRaw: Uint8Array;
  currentFileContent: string;
  epochFileContent: string;
}

const textEncoder = new TextEncoder();
const WRAP_SALT = textEncoder.encode("replycant-age-wrap-salt");
const WRAP_INFO = textEncoder.encode("replycant-age-wrap-info");

// Encodes bytes as base64 text so fixture key material can be stored in repo files and benchmark inputs.
const bytesToBase64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString("base64");

// Returns random bytes from the WebCrypto RNG so benchmark crypto data stays standards-compliant.
const randomBytes = (length: number): Uint8Array => crypto.getRandomValues(new Uint8Array(length));

// Encrypts data with AES-GCM and returns nonce+ciphertext+tag in the combined layout expected by sync decryptors.
const encryptAesGcmCombined = async (rawKey: Uint8Array, plaintext: Uint8Array): Promise<Uint8Array> => {
  const nonce = randomBytes(12);
  const key = await crypto.subtle.importKey("raw", rawKey, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
  const ciphertextWithTag = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, plaintext);
  const out = new Uint8Array(nonce.length + ciphertextWithTag.byteLength);
  out.set(nonce, 0);
  out.set(new Uint8Array(ciphertextWithTag), nonce.length);
  return out;
};

// Derives the age stanza wrapping key so fixture envelopes match the production decryptAgeEnvelope HKDF contract.
const deriveWrapKey = async (sharedSecret: Uint8Array): Promise<Uint8Array> => {
  const keyMaterial = await crypto.subtle.importKey("raw", sharedSecret, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: WRAP_SALT,
      info: WRAP_INFO,
    },
    keyMaterial,
    256,
  );
  return new Uint8Array(bits);
};

// Encrypts payload bytes with ChaCha20-Poly1305 and returns nonce+ciphertext+tag for age envelope stanzas.
const encryptChaChaCombined = (plaintext: Uint8Array, key: Uint8Array): Uint8Array => {
  const nonce = randomBytes(12);
  const ciphertextWithTag = chacha20poly1305(key, nonce).encrypt(plaintext);
  const out = new Uint8Array(nonce.length + ciphertextWithTag.length);
  out.set(nonce, 0);
  out.set(ciphertextWithTag, nonce.length);
  return out;
};

// Builds a one-recipient age-style envelope so web sync can unwrap KEKs using the same code path as production repos.
const buildAgeEnvelopeForRecipient = async (recipientPublicKey: Uint8Array, kekRaw: Uint8Array): Promise<string> => {
  const fileKey = randomBytes(32);
  const ephemeralPrivateKey = x25519.utils.randomSecretKey();
  const ephemeralPublicKey = x25519.getPublicKey(ephemeralPrivateKey);
  const sharedSecret = x25519.getSharedSecret(ephemeralPrivateKey, recipientPublicKey);
  const wrapKey = await deriveWrapKey(sharedSecret);
  const wrappedFileKeyCombined = encryptChaChaCombined(fileKey, wrapKey);
  const payloadCombined = encryptChaChaCombined(kekRaw, fileKey);
  return [
    "age-encryption.org/v1",
    `-> X25519 ${bytesToBase64(ephemeralPublicKey)} ${bytesToBase64(wrappedFileKeyCombined)}`,
    `payload ${bytesToBase64(payloadCombined)}`,
    "",
  ].join("\n");
};

// Produces deterministic fixture encryption state so benchmark repos include valid epoch files and a usable local age key.
const buildEncryptionFixtureState = async (): Promise<EncryptionFixtureState> => {
  const agePrivateKey = x25519.utils.randomSecretKey();
  const agePublicKey = x25519.getPublicKey(agePrivateKey);
  const kekRaw = randomBytes(32);
  const epochFileContent = await buildAgeEnvelopeForRecipient(agePublicKey, kekRaw);
  return {
    agePrivateKeyBase64: bytesToBase64(agePrivateKey),
    kekRaw,
    currentFileContent: "1\n",
    epochFileContent,
  };
};

// Wraps plaintext YAML in the encrypted manifest envelope so sync reads exercise real decrypt logic.
const encryptManifestYaml = async (yaml: string, kekRaw: Uint8Array): Promise<Uint8Array> =>
  encryptManifestYamlShared(yaml, kekRaw, 1);

// Encrypts one per-object DEK for pointer metadata so attachDecryptedDekMetadata can unwrap realistic values.
const wrapDekForPointer = async (kekRaw: Uint8Array): Promise<{ wrappedDekBase64: string }> => {
  const dekRaw = randomBytes(32);
  const wrappedDekCombined = await encryptAesGcmCombined(kekRaw, dekRaw);
  return { wrappedDekBase64: bytesToBase64(wrappedDekCombined) };
};

// Shards synthetic filenames so benchmark repos exercise bounded git tree fanout.
const shardName = (name: string): string =>
  name.length < 5 ? name : `${name.slice(0, 2)}/${name.slice(2, 4)}/${name.slice(4)}`;

// Formats encrypted LFS pointer files with the metadata fields used by webapp pointer parsing.
const buildLfsPointer = (oidSha256: string, fileSize: number, wrappedDekBase64: string): string =>
  [
    "version https://git-lfs.github.com/spec/v1",
    `oid sha256:${oidSha256}`,
    `size ${fileSize}`,
    "x-replycant-kek-epoch 1",
    `x-replycant-wrapped-dek ${wrappedDekBase64}`,
    "",
  ].join("\n");

// Builds deterministic synthetic repo parameters so benchmark runs can scale without changing harness logic.
export const parseSyntheticRepoOptions = (): SyntheticGitRepoOptions => ({
  baselineCommitCount: Number(process.env.GIT_BENCH_BASELINE_COMMITS ?? "6"),
  manifestCount: Number(process.env.GIT_BENCH_MANIFEST_COUNT ?? "600"),
  deviceSpaceCount: Number(process.env.GIT_BENCH_DEVICE_SPACES ?? "4"),
  treeFanout: Number(process.env.GIT_BENCH_TREE_FANOUT ?? "10"),
});

// Executes git CLI calls so fixture setup can produce real commit graphs and object packs.
const runGit = async (args: string[], cwd: string): Promise<string> => {
  await fs.mkdir(cwd, { recursive: true });
  return new Promise<string>((resolve, reject) => {
    const child = spawn("git", args, {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
      env: process.env,
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve(stdout.trim());
        return;
      }
      reject(new Error(`git ${args.join(" ")} failed (${code}): ${stderr.trim()}`));
    });
  });
};

// Generates deterministic pseudo-hashes so synthetic manifests resemble real sha256 metadata.
const pseudoSha256 = (seed: string): string => {
  let state = 0x9e3779b1;
  for (const char of seed) {
    state ^= char.charCodeAt(0);
    state = Math.imul(state, 2654435761) >>> 0;
  }
  let out = "";
  for (let i = 0; i < 64; i += 1) {
    state = Math.imul(state ^ (state >>> 13), 1597334677) >>> 0;
    out += (state & 0xf).toString(16);
  }
  return out;
};

// Produces deterministic UUID-like ids so key-rotation commits look like real device registration events.
const pseudoUuid = (seed: number): string => {
  const hex = pseudoSha256(`uuid-${seed}`);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
};

// Encodes media distribution that roughly mirrors the Browser timeline (mostly HEIC photos with periodic MOV videos).
const buildMediaEntry = (
  index: number,
  _treeFanout: number,
  deviceSpaceCount: number,
): SyntheticMediaEntry => {
  const deviceSpace = `linux-webapp-${index % Math.max(1, deviceSpaceCount)}`;
  const isVideo = index % 8 === 0;
  const extension = isVideo ? "MOV" : "HEIC";
  const fileNumber = 5500 + index;
  const fileName = `IMG_${fileNumber}.${extension}`;
  const createdDate = new Date(Date.UTC(2026, 1, 1, 12, Math.floor(index / 60), index % 60));
  const takenDate = new Date(createdDate.getTime() - 90_000);
  const stem = fileName.replace(/\.[^.]+$/, "");
  const originalManifestPath = path.join(
    "manifests",
    deviceSpace,
    "media.replycant.com",
    "v1alpha1",
    "Original",
    shardName(`${fileName}.yaml`),
  );
  const thumbnailManifestPath = path.join(
    "manifests",
    deviceSpace,
    "media.replycant.com",
    "v1alpha1",
    "ThumbnailSet",
    shardName(`${stem}-thumbs.yaml`),
  );
  const originalPointerPath = path.join(
    "binary",
    deviceSpace,
    "media.replycant.com",
    "v1alpha1",
    "Original",
    shardName(fileName),
  );
  const thumbnailPointerPaths = [640, 1024].map((width) =>
    path.join(
      "binary",
      deviceSpace,
      "media.replycant.com",
      "v1alpha1",
      "ThumbnailSet",
      shardName(`${stem}-${width}.jpg`),
    ),
  );
  return {
    index,
    deviceSpace,
    fileName,
    mediaType: isVideo ? "video" : "photo",
    mimeType: isVideo ? "video/quicktime" : "image/heic",
    width: isVideo ? 1920 : 4032,
    height: isVideo ? 1080 : 3024,
    durationSeconds: isVideo ? 9 + (index % 6) : undefined,
    createdAt: createdDate.toISOString(),
    takenAt: takenDate.toISOString(),
    originalManifestPath,
    originalPointerPath,
    thumbnailManifestPath,
    thumbnailPointerPaths,
  };
};

// Produces Original manifests in the same API shape used by app sync and normalization.
const buildOriginalManifestYaml = (entry: SyntheticMediaEntry, revision: number): string => {
  const mediaSha = pseudoSha256(`${entry.fileName}-original-${revision}`);
  const fileSize = entry.mediaType === "video" ? 4_000_000 + entry.index * 31 : 2_000_000 + entry.index * 17;
  return [
    "apiVersion: media.replycant.com/v1alpha1",
    "kind: Original",
    "metadata:",
    `  name: ${entry.fileName}`,
    `  deviceSpace: ${entry.deviceSpace}`,
    "spec:",
    `  id: ${entry.deviceSpace}-${entry.index}`,
    `  sha256: ${mediaSha}`,
    `  path: /originals/${entry.deviceSpace}/${entry.fileName}`,
    `  filesize: ${fileSize}`,
    `  mediaType: ${entry.mediaType}`,
    `  mimeType: ${entry.mimeType}`,
    `  width: ${entry.width}`,
    `  height: ${entry.height}`,
    ...(entry.durationSeconds ? [`  duration: ${entry.durationSeconds}`] : []),
    "  isFavorite: false",
    "  isHidden: false",
    `  createdAt: ${entry.createdAt}`,
    `  takenAt: ${entry.takenAt}`,
    "status: {}",
    "",
  ].join("\n");
};

// Produces one ThumbnailSet manifest so incremental diff logic sees grouped derived media rows.
const buildThumbnailSetManifestYaml = (
  entry: SyntheticMediaEntry,
  revision: number,
): string => {
  const stem = entry.fileName.replace(/\.[^.]+$/, "");
  const widths = [640, 1024];
  const thumbnailLines = widths.flatMap((thumbnailWidth) => {
    const thumbName = `${stem}-${thumbnailWidth}.jpg`;
    const thumbHeight = Math.max(1, Math.round((thumbnailWidth * entry.height) / entry.width));
    const thumbSha = pseudoSha256(`${entry.fileName}-thumb-${thumbnailWidth}-${revision}`);
    return [
      `    - name: ${thumbName}`,
      `      sha256: ${thumbSha}`,
      `      width: ${thumbnailWidth}`,
      `      height: ${thumbHeight}`,
      `      filesize: ${64_000 + entry.index * 7 + thumbnailWidth}`,
    ];
  });
  return [
    "apiVersion: media.replycant.com/v1alpha1",
    "kind: ThumbnailSet",
    "metadata:",
    `  name: ${stem}-thumbs`,
    `  deviceSpace: ${entry.deviceSpace}`,
    "spec:",
    `  originalRef: ${entry.deviceSpace}/media.replycant.com/v1alpha1/Original/${entry.fileName}`,
    "  thumbnails:",
    ...thumbnailLines,
    "status: {}",
    "",
  ].join("\n");
};

// Writes a plausible public-key payload so fixture history includes device-key churn seen in the Browser timeline.
const buildDeviceKeyContent = (seed: number): string =>
  [
    "-----BEGIN REPLYCANT DEVICE KEY-----",
    pseudoSha256(`device-key-${seed}`),
    "-----END REPLYCANT DEVICE KEY-----",
    "",
  ].join("\n");

// Persists one media asset's original+thumbnail manifests so commit transitions mimic production repository updates.
const writeMediaEntry = async (
  writerDir: string,
  entry: SyntheticMediaEntry,
  revision: number,
  kekRaw: Uint8Array,
): Promise<void> => {
  const originalFileSize = entry.mediaType === "video" ? 4_000_000 + entry.index * 31 : 2_000_000 + entry.index * 17;
  const originalAbsolute = path.join(writerDir, entry.originalManifestPath);
  await fs.mkdir(path.dirname(originalAbsolute), { recursive: true });
  await fs.writeFile(
    originalAbsolute,
    await encryptManifestYaml(buildOriginalManifestYaml(entry, revision), kekRaw),
  );
  const originalPointerPath = entry.originalPointerPath;
  const originalWrappedDek = await wrapDekForPointer(kekRaw);
  await fs.mkdir(path.dirname(path.join(writerDir, originalPointerPath)), { recursive: true });
  await fs.writeFile(
    path.join(writerDir, originalPointerPath),
    buildLfsPointer(
      pseudoSha256(`${entry.fileName}-original-pointer-${revision}`),
      originalFileSize,
      originalWrappedDek.wrappedDekBase64,
    ),
    "utf8",
  );
  for (const pointerPath of entry.thumbnailPointerPaths) {
    const match = pointerPath.match(/-(\d+)\.jpg$/);
    const width = Number(match?.[1] ?? "640");
    const thumbFileSize = 64_000 + entry.index * 7 + width;
    const wrappedDek = await wrapDekForPointer(kekRaw);
    await fs.mkdir(path.dirname(path.join(writerDir, pointerPath)), { recursive: true });
    await fs.writeFile(
      path.join(writerDir, pointerPath),
      buildLfsPointer(
        pseudoSha256(`${entry.fileName}-thumb-${width}-pointer-${revision}`),
        thumbFileSize,
        wrappedDek.wrappedDekBase64,
      ),
      "utf8",
    );
  }
  const thumbnailManifestAbsolute = path.join(writerDir, entry.thumbnailManifestPath);
  await fs.mkdir(path.dirname(thumbnailManifestAbsolute), { recursive: true });
  await fs.writeFile(
    thumbnailManifestAbsolute,
    await encryptManifestYaml(buildThumbnailSetManifestYaml(entry, revision), kekRaw),
  );
};

// Writes baseline manifests and key files to create a repo shape close to the Browser-cloned history.
const writeSyntheticManifests = async (
  writerDir: string,
  manifestCount: number,
  treeFanout: number,
  deviceSpaceCount: number,
  revision: number,
  encryptionState: EncryptionFixtureState,
): Promise<{ mediaEntries: SyntheticMediaEntry[]; keyPaths: string[] }> => {
  const mediaEntries: SyntheticMediaEntry[] = [];
  const keyPaths: string[] = [];
  const currentPath = path.join(writerDir, "encryption", "current");
  await fs.mkdir(path.dirname(currentPath), { recursive: true });
  await fs.writeFile(currentPath, encryptionState.currentFileContent, "utf8");
  const epochPath = path.join(writerDir, "encryption", "epochs", "1.age");
  await fs.mkdir(path.dirname(epochPath), { recursive: true });
  await fs.writeFile(epochPath, encryptionState.epochFileContent, "utf8");
  for (let deviceIndex = 0; deviceIndex < Math.max(1, deviceSpaceCount); deviceIndex += 1) {
    const keyUuid = pseudoUuid(deviceIndex);
    const keyPath = path.join("keys", "linux-webapp", `${keyUuid}.pub`);
    await fs.mkdir(path.dirname(path.join(writerDir, keyPath)), { recursive: true });
    await fs.writeFile(path.join(writerDir, keyPath), buildDeviceKeyContent(deviceIndex), "utf8");
    keyPaths.push(keyPath);
  }
  for (let i = 0; i < manifestCount; i += 1) {
    const entry = buildMediaEntry(i, treeFanout, deviceSpaceCount);
    await writeMediaEntry(writerDir, entry, revision, encryptionState.kekRaw);
    mediaEntries.push(entry);
  }
  return { mediaEntries, keyPaths };
};

// Parses git-http-backend CGI headers so HTTP responses preserve git smart-protocol metadata.
const parseCgiHeaders = (chunk: Buffer): ParsedCgiHeaders | null => {
  const delimiter = chunk.indexOf(Buffer.from("\r\n\r\n"));
  const fallbackDelimiter = delimiter === -1 ? chunk.indexOf(Buffer.from("\n\n")) : -1;
  const splitIndex = delimiter >= 0 ? delimiter : fallbackDelimiter;
  if (splitIndex < 0) return null;
  const headerBytes = chunk.subarray(0, splitIndex);
  const bodyOffset = delimiter >= 0 ? splitIndex + 4 : splitIndex + 2;
  const body = chunk.subarray(bodyOffset);
  const lines = headerBytes.toString("utf8").split(/\r?\n/).filter(Boolean);
  const headers: Record<string, string> = {};
  let statusCode = 200;
  for (const line of lines) {
    const separator = line.indexOf(":");
    if (separator < 0) continue;
    const name = line.slice(0, separator).trim();
    const value = line.slice(separator + 1).trim();
    if (name.toLowerCase() === "status") {
      const parsed = Number(value.split(" ")[0]);
      if (!Number.isNaN(parsed)) statusCode = parsed;
      continue;
    }
    headers[name] = value;
  }
  return { statusCode, headers, body };
};

// Serves a bare repository over smart HTTP through git-http-backend so browser pulls mirror production protocol.
const startGitHttpServer = async (rootDir: string): Promise<GitHttpServer> => {
  const server = createServer(async (req, res) => {
    if (!req.url) {
      res.statusCode = 400;
      res.end("missing url");
      return;
    }
    if (req.method === "OPTIONS") {
      res.setHeader("Access-Control-Allow-Origin", "*");
      res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
      res.setHeader("Access-Control-Allow-Headers", "*");
      res.setHeader("Cache-Control", "no-store");
      res.statusCode = 200;
      res.end();
      return;
    }

    const requestUrl = new URL(req.url, "http://127.0.0.1");
    const pathInfo = decodeURIComponent(requestUrl.pathname);
    const backend = spawn("git", ["http-backend"], {
      cwd: rootDir,
      env: {
        ...process.env,
        GIT_PROJECT_ROOT: rootDir,
        GIT_HTTP_EXPORT_ALL: "1",
        PATH_INFO: pathInfo,
        QUERY_STRING: requestUrl.search.slice(1),
        REQUEST_METHOD: req.method ?? "GET",
        CONTENT_TYPE: req.headers["content-type"] ?? "",
        CONTENT_LENGTH: req.headers["content-length"] ?? "0",
      },
      stdio: ["pipe", "pipe", "pipe"],
    });

    req.pipe(backend.stdin);
    let buffered = Buffer.alloc(0);
    let headersSent = false;
    let backendStderr = "";
    backend.stderr.on("data", (chunk: Buffer) => {
      backendStderr += String(chunk);
    });
    backend.stdout.on("data", (chunk: Buffer) => {
      if (headersSent) {
        res.write(chunk);
        return;
      }
      buffered = Buffer.concat([buffered, chunk]);
      const parsed = parseCgiHeaders(buffered);
      if (!parsed) return;
      headersSent = true;
      const responseHeaders = {
        ...parsed.headers,
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
        "Access-Control-Allow-Headers": "*",
        "Cache-Control": "no-store",
      };
      res.writeHead(parsed.statusCode, responseHeaders);
      if (parsed.body.length > 0) {
        res.write(parsed.body);
      }
      buffered = Buffer.alloc(0);
    });
    backend.on("close", (code: number | null) => {
      if (!headersSent) {
        const message = backendStderr.trim() || `git http-backend exited with code ${String(code)}`;
        res.statusCode = 500;
        res.end(message);
        return;
      }
      res.end();
    });
  });
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("Failed to determine benchmark git server address.");
  }
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    close: async () => {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) reject(error);
          else resolve();
        });
      });
    },
  };
};

// Creates a synthetic remote and mutator clone so each iteration can reset to baseline then add one commit.
export const createSyntheticGitRepoFixture = async (
  options: SyntheticGitRepoOptions,
): Promise<SyntheticGitRepoFixture> => {
  const rootDir = await fs.mkdtemp(path.join(tmpdir(), "replycant-gitpull-bench-"));
  const remoteDir = path.join(rootDir, "git");
  const writerDir = path.join(rootDir, "writer");
  await runGit(["init", "--bare", remoteDir], rootDir);
  await runGit(["clone", remoteDir, writerDir], rootDir);
  await runGit(["checkout", "-B", "main"], writerDir);
  await runGit(["config", "user.name", "Replycant Bench"], writerDir);
  await runGit(["config", "user.email", "bench@replycant.local"], writerDir);
  const encryptionState = await buildEncryptionFixtureState();

  const { mediaEntries, keyPaths } = await writeSyntheticManifests(
    writerDir,
    Math.max(1, options.manifestCount),
    Math.max(1, options.treeFanout),
    Math.max(1, options.deviceSpaceCount),
    0,
    encryptionState,
  );
  await runGit(["add", "."], writerDir);
  await runGit(["commit", "-m", "baseline synthetic snapshot"], writerDir);
  for (let i = 1; i < Math.max(1, options.baselineCommitCount); i += 1) {
    if (i % 5 === 0 && keyPaths.length > 0) {
      const keyPath = keyPaths[i % keyPaths.length];
      await fs.writeFile(path.join(writerDir, keyPath), buildDeviceKeyContent(i), "utf8");
      await runGit(["add", keyPath], writerDir);
      await runGit(["commit", "-m", `Add device key for linux-webapp (${pseudoUuid(i)})`], writerDir);
      continue;
    }
    const target = mediaEntries[i % mediaEntries.length];
    await writeMediaEntry(writerDir, target, i, encryptionState.kekRaw);
    await runGit(
      [
        "add",
        target.originalManifestPath,
        target.thumbnailManifestPath,
        target.originalPointerPath,
        ...target.thumbnailPointerPaths,
      ],
      writerDir,
    );
    const mediaLabel = target.mediaType === "video" ? "video" : "photo";
    await runGit(["commit", "-m", `Add ${mediaLabel}: ${target.fileName}`], writerDir);
  }
  await runGit(["push", "-u", "origin", "main"], writerDir);
  await runGit(["symbolic-ref", "HEAD", "refs/heads/main"], remoteDir);
  await runGit(["--git-dir", remoteDir, "update-server-info"], rootDir);
  const baselineHead = await runGit(["rev-parse", "HEAD"], writerDir);
  const gitServer = await startGitHttpServer(rootDir);
  let revision = Math.max(1, options.baselineCommitCount);

  // Keeps the remote branch pinned to baseline so each benchmark sample starts from identical history.
  const resetRemoteToBaseline = async (): Promise<void> => {
    await runGit(["--git-dir", remoteDir, "update-ref", "refs/heads/main", baselineHead], rootDir);
    await runGit(["--git-dir", remoteDir, "update-server-info"], rootDir);
    await runGit(["fetch", "origin", "main"], writerDir);
    await runGit(["reset", "--hard", "origin/main"], writerDir);
  };

  // Appends one deterministic manifest mutation and publishes it so pull benchmarks measure one-commit updates.
  const appendSingleCommit = async (): Promise<string> => {
    await runGit(["fetch", "origin", "main"], writerDir);
    await runGit(["checkout", "main"], writerDir);
    await runGit(["reset", "--hard", "origin/main"], writerDir);
    const targetIndex = revision % mediaEntries.length;
    const target = mediaEntries[targetIndex];
    await writeMediaEntry(writerDir, target, revision, encryptionState.kekRaw);
    await runGit(
      [
        "add",
        target.originalManifestPath,
        target.thumbnailManifestPath,
        target.originalPointerPath,
        ...target.thumbnailPointerPaths,
      ],
      writerDir,
    );
    const mediaLabel = target.mediaType === "video" ? "video" : "photo";
    await runGit(["commit", "-m", `Add ${mediaLabel}: ${target.fileName}`], writerDir);
    await runGit(["push", "--force", "origin", "main"], writerDir);
    await runGit(["--git-dir", remoteDir, "update-server-info"], rootDir);
    revision += 1;
    return runGit(["rev-parse", "HEAD"], writerDir);
  };

  // Reports packed+loose object totals so benchmark outputs can document fixture scale.
  const getRemoteObjectCount = async (): Promise<number> => {
    const output = await runGit(["--git-dir", remoteDir, "count-objects", "-v"], rootDir);
    const countMatch = output.match(/^count:\\s+(\\d+)$/m);
    const inPackMatch = output.match(/^in-pack:\\s+(\\d+)$/m);
    const loose = Number(countMatch?.[1] ?? "0");
    const packed = Number(inPackMatch?.[1] ?? "0");
    return loose + packed;
  };

  // Cleans temporary fixture state so benchmark runs do not leak disk usage across sessions.
  const dispose = async (): Promise<void> => {
    await gitServer.close();
    await fs.rm(rootDir, { recursive: true, force: true });
  };

  return {
    rootDir,
    remoteDir,
    writerDir,
    apiBasePath: gitServer.baseUrl,
    remoteUrl: `${gitServer.baseUrl}/git`,
    agePrivateKeyBase64: encryptionState.agePrivateKeyBase64,
    baselineHead,
    getRemoteObjectCount,
    resetRemoteToBaseline,
    appendSingleCommit,
    dispose,
  };
};
