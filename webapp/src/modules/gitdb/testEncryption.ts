import {
  CHUNK_SIZE,
  chunkAad,
  chunkNonce,
  dekWrapAad,
  importAes256Key,
} from "./encryption";

const textEncoder = new TextEncoder();

// Deterministic test KEK so unit tests can encrypt fixtures without age envelopes.
export const TEST_KEK_RAW = new Uint8Array(32).fill(0x42);

// Deterministic test DEK so e2e/unit fixtures encrypt LFS bodies without age unwrap.
export const TEST_DEK_RAW = new Uint8Array(32).fill(0x11);

// Base64 form of TEST_DEK_RAW for pointer rows that store unwrapped DEKs.
export const TEST_DEK_BASE64 = btoa(String.fromCharCode(...TEST_DEK_RAW));

// Alias kept for existing e2e imports; production chunk size is the only valid value.
export const TEST_LFS_CHUNK_SIZE = CHUNK_SIZE;

// Narrows Uint8Array to DOM BufferSource for strict TS lib compatibility.
const asBufferSource = (bytes: Uint8Array): BufferSource => bytes as unknown as BufferSource;

// Encrypts AES-GCM in the nonce+ciphertext+tag layout used by production decryptors.
const encryptAesGcmCombined = async (
  rawKey: Uint8Array,
  plaintext: Uint8Array,
  additionalData?: Uint8Array,
): Promise<Uint8Array> => {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const key = await crypto.subtle.importKey(
    "raw",
    asBufferSource(rawKey),
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
  const ciphertextWithTag = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: nonce,
      ...(additionalData ? { additionalData: asBufferSource(additionalData) } : {}),
    },
    key,
    asBufferSource(plaintext),
  );
  const out = new Uint8Array(nonce.length + ciphertextWithTag.byteLength);
  out.set(nonce, 0);
  out.set(new Uint8Array(ciphertextWithTag), nonce.length);
  return out;
};

// Wraps plaintext YAML in a REPLYCANT-ENC-V1 envelope so sync tests exercise real decrypt paths.
export const encryptManifestYaml = async (
  yaml: string,
  kekRaw: Uint8Array = TEST_KEK_RAW,
  epoch = 1,
): Promise<Uint8Array> => {
  const encryptedBody = await encryptAesGcmCombined(kekRaw, textEncoder.encode(yaml));
  const header = textEncoder.encode(`REPLYCANT-ENC-V1\nkek-epoch: ${epoch}\n---\n`);
  const out = new Uint8Array(header.length + encryptedBody.length);
  out.set(header, 0);
  out.set(encryptedBody, header.length);
  return out;
};

// Wraps a DEK with epoch-bound AAD so tests can exercise unwrapDEK authentication.
export const wrapTestDEK = async (
  dekRaw: Uint8Array = TEST_DEK_RAW,
  kekRaw: Uint8Array = TEST_KEK_RAW,
  kekEpoch = 1,
): Promise<string> => {
  const combined = await encryptAesGcmCombined(kekRaw, dekRaw, dekWrapAad(kekEpoch));
  return btoa(String.fromCharCode(...combined));
};

// Encrypts binary payloads in the v2 chunked AES-GCM framing decryptBinaryChunked expects.
// Empty plaintext produces zero chunks to match Go and Swift.
export const encryptBinaryChunked = async (
  plaintext: Uint8Array,
  dekRaw: Uint8Array = TEST_DEK_RAW,
): Promise<Uint8Array> => {
  if (plaintext.length === 0) {
    return new Uint8Array(0);
  }
  const key = await crypto.subtle.importKey(
    "raw",
    asBufferSource(dekRaw),
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
  const totalChunks = Math.ceil(plaintext.length / CHUNK_SIZE);
  const encryptedChunks: Uint8Array[] = [];
  for (let index = 0; index < totalChunks; index += 1) {
    const start = index * CHUNK_SIZE;
    const end = Math.min(start + CHUNK_SIZE, plaintext.length);
    const slice = plaintext.subarray(start, end);
    const ciphertextWithTag = await crypto.subtle.encrypt(
      {
        name: "AES-GCM",
        iv: asBufferSource(chunkNonce(index)),
        additionalData: asBufferSource(chunkAad(index, index === totalChunks - 1)),
      },
      key,
      asBufferSource(slice),
    );
    encryptedChunks.push(new Uint8Array(ciphertextWithTag));
  }
  const totalLength = encryptedChunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const out = new Uint8Array(totalLength);
  let outOffset = 0;
  for (const chunk of encryptedChunks) {
    out.set(chunk, outOffset);
    outOffset += chunk.length;
  }
  return out;
};

// Imports the shared test KEK for ManifestBlobReader.loadKekEpoch spies.
export const importTestKek = async (kekRaw: Uint8Array = TEST_KEK_RAW): Promise<CryptoKey> =>
  importAes256Key(kekRaw);
