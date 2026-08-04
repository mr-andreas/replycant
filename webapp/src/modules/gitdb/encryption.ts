import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { x25519 } from "@noble/curves/ed25519.js";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

const ENCRYPTED_MANIFEST_HEADER = "REPLYCANT-ENC-V1";
const ENCRYPTED_MANIFEST_DELIMITER = textEncoder.encode("\n---\n");
const WRAP_SALT = textEncoder.encode("replycant-age-wrap-salt");
const WRAP_INFO = textEncoder.encode("replycant-age-wrap-info");
const AGE_RECIPIENT_PREFIX = "-> X25519 ";
const AGE_PAYLOAD_PREFIX = "payload ";
const AES_GCM_NONCE_BYTES = 12;
const AES_GCM_TAG_BYTES = 16;
const CHACHA_NONCE_BYTES = 12;
const CHACHA_TAG_BYTES = 16;
// Per-chunk wire overhead is the GCM tag only; nonces are derived and not stored.
const CHUNK_OVERHEAD_BYTES = AES_GCM_TAG_BYTES;
// Repo-wide plaintext chunk size shared with Go/Swift/decryptd (64 KiB).
export const CHUNK_SIZE = 65536;
const CHUNK_AAD_PREFIX = textEncoder.encode("replycant-lfs-chunk-v1");
const DEK_WRAP_AAD_PREFIX = textEncoder.encode("replycant-dek-wrap-v1");

// Carries pointer-derived decryption metadata so media fetchers can unwrap per-object keys.
// dekBase64 is required so fetchers never silently treat ciphertext as plaintext.
export interface LfsEncryptionMeta {
  encryptedOid: string;
  wrappedDek: string;
  kekEpoch: number;
  dekBase64: string;
}

export interface EncryptedManifestPayload {
  kekEpoch: number;
  ciphertext: Uint8Array;
}

export interface LfsPointerFields {
  oid: string;
  size: number;
  kekEpoch: number | null;
  wrappedDek: string | null;
  dekBase64?: string;
}

// Scans binary input for a delimiter so manifest header parsing can stop before ciphertext bytes.
const indexOfBytes = (haystack: Uint8Array, needle: Uint8Array): number => {
  outer: for (let i = 0; i <= haystack.length - needle.length; i += 1) {
    for (let j = 0; j < needle.length; j += 1) {
      if (haystack[i + j] !== needle[j]) continue outer;
    }
    return i;
  }
  return -1;
};

// Converts a base64 string to bytes for key and envelope decoding.
const base64ToBytes = (encoded: string): Uint8Array =>
  Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));

// Converts bytes to lower-case hex for plaintext integrity checks.
const bytesToHex = (bytes: Uint8Array): string =>
  Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

// Narrows Uint8Array to DOM BufferSource for strict TS lib compatibility.
const asBufferSource = (bytes: Uint8Array): BufferSource => bytes as unknown as BufferSource;

// Detects encrypted manifest blobs so callers can decrypt before YAML parsing.
export const isEncryptedManifest = (raw: Uint8Array): boolean => {
  const prefix = textEncoder.encode(`${ENCRYPTED_MANIFEST_HEADER}\n`);
  if (raw.length < prefix.length) return false;
  for (let i = 0; i < prefix.length; i += 1) {
    if (raw[i] !== prefix[i]) return false;
  }
  return true;
};

// Parses encrypted manifest metadata and ciphertext payload from the repo blob format.
export const parseEncryptedManifestHeader = (raw: Uint8Array): EncryptedManifestPayload => {
  const delimiterIndex = indexOfBytes(raw, ENCRYPTED_MANIFEST_DELIMITER);
  if (delimiterIndex < 0) {
    throw new Error("Encrypted manifest is missing metadata delimiter.");
  }
  const headerText = textDecoder.decode(raw.slice(0, delimiterIndex));
  const lines = headerText.split("\n").map((line) => line.trim());
  if (lines[0] !== ENCRYPTED_MANIFEST_HEADER) {
    throw new Error("Encrypted manifest header version is invalid.");
  }
  const kekEpochLine = lines.find((line) => line.startsWith("kek-epoch:"));
  if (!kekEpochLine) {
    throw new Error("Encrypted manifest is missing kek-epoch metadata.");
  }
  const parsedEpoch = Number.parseInt(kekEpochLine.replace("kek-epoch:", "").trim(), 10);
  if (!Number.isInteger(parsedEpoch) || parsedEpoch < 1) {
    throw new Error("Encrypted manifest kek-epoch metadata is invalid.");
  }
  return {
    kekEpoch: parsedEpoch,
    ciphertext: raw.slice(delimiterIndex + ENCRYPTED_MANIFEST_DELIMITER.length),
  };
};

// Decrypts AES-GCM content encoded as <nonce><ciphertext><tag> combined bytes.
// AAD must match the value supplied at seal time or authentication fails.
const decryptAesGcmCombined = async (
  combined: Uint8Array,
  key: CryptoKey,
  additionalData?: Uint8Array,
): Promise<Uint8Array> => {
  if (combined.length < AES_GCM_NONCE_BYTES + AES_GCM_TAG_BYTES) {
    throw new Error("Ciphertext is too short for AES-GCM.");
  }
  const nonce = combined.slice(0, AES_GCM_NONCE_BYTES);
  const ciphertextWithTag = combined.slice(AES_GCM_NONCE_BYTES);
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: nonce,
      ...(additionalData ? { additionalData: asBufferSource(additionalData) } : {}),
    },
    key,
    ciphertextWithTag,
  );
  return new Uint8Array(plaintext);
};

// Derives the 12-byte AES-GCM nonce for chunk index so encryptors never place an
// attacker-controlled nonce on the wire.
export const chunkNonce = (index: number): Uint8Array => {
  if (!Number.isInteger(index) || index < 0) {
    throw new Error("Chunk index must be a non-negative integer.");
  }
  const nonce = new Uint8Array(AES_GCM_NONCE_BYTES);
  new DataView(nonce.buffer).setBigUint64(4, BigInt(index), false);
  return nonce;
};

// Binds each seal to its index and last-chunk status so reorder and trailing
// truncation fail authentication.
export const chunkAad = (index: number, isLast: boolean): Uint8Array => {
  if (!Number.isInteger(index) || index < 0) {
    throw new Error("Chunk index must be a non-negative integer.");
  }
  const aad = new Uint8Array(CHUNK_AAD_PREFIX.length + 8 + 1);
  aad.set(CHUNK_AAD_PREFIX, 0);
  new DataView(aad.buffer).setBigUint64(CHUNK_AAD_PREFIX.length, BigInt(index), false);
  aad[aad.length - 1] = isLast ? 1 : 0;
  return aad;
};

// Binds a wrapped DEK to its kek-epoch so pointer metadata cannot move across epochs.
export const dekWrapAad = (kekEpoch: number): Uint8Array => {
  if (!Number.isInteger(kekEpoch) || kekEpoch < 1) {
    throw new Error("KEK epoch must be a positive integer.");
  }
  const aad = new Uint8Array(DEK_WRAP_AAD_PREFIX.length + 8);
  aad.set(DEK_WRAP_AAD_PREFIX, 0);
  new DataView(aad.buffer).setBigUint64(DEK_WRAP_AAD_PREFIX.length, BigInt(kekEpoch), false);
  return aad;
};

// Imports raw 32-byte material into an AES-256-GCM key for decrypt/unwrap operations.
export const importAes256Key = async (rawKey: Uint8Array, usages: KeyUsage[] = ["decrypt"]): Promise<CryptoKey> => {
  if (rawKey.length !== 32) {
    throw new Error("AES-256 key must be exactly 32 bytes.");
  }
  return crypto.subtle.importKey("raw", asBufferSource(rawKey), { name: "AES-GCM", length: 256 }, false, usages);
};

// Derives the stanza wrap key to mirror iOS KEK epoch HKDF semantics exactly.
const deriveWrapKey = async (sharedSecret: Uint8Array): Promise<Uint8Array> => {
  const keyMaterial = await crypto.subtle.importKey("raw", asBufferSource(sharedSecret), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: asBufferSource(WRAP_SALT),
      info: asBufferSource(WRAP_INFO),
    },
    keyMaterial,
    256,
  );
  return new Uint8Array(bits);
};

// Decrypts one ChaCha20-Poly1305 sealed-box combined payload from iOS AgeCrypto format.
const decryptChaChaCombined = (combined: Uint8Array, key: Uint8Array): Uint8Array => {
  if (combined.length < CHACHA_NONCE_BYTES + CHACHA_TAG_BYTES) {
    throw new Error("ChaCha20-Poly1305 payload is too short.");
  }
  const nonce = combined.slice(0, CHACHA_NONCE_BYTES);
  const ciphertextWithTag = combined.slice(CHACHA_NONCE_BYTES);
  return chacha20poly1305(key, nonce).decrypt(ciphertextWithTag);
};

// Decrypts the custom age-like envelope used by iOS to store KEK epoch files.
export const decryptAgeEnvelope = async (
  encryptedEnvelope: Uint8Array,
  agePrivateKeyBase64: string,
): Promise<Uint8Array> => {
  const privateKey = base64ToBytes(agePrivateKeyBase64);
  if (privateKey.length !== 32) {
    throw new Error("Age private key material is invalid.");
  }
  const text = textDecoder.decode(encryptedEnvelope);
  const lines = text.split("\n").map((line) => line.trim()).filter((line) => line.length > 0);
  if (lines[0] !== "age-encryption.org/v1") {
    throw new Error("KEK epoch file header is invalid.");
  }

  const recipientLines = lines.filter((line) => line.startsWith(AGE_RECIPIENT_PREFIX));
  const payloadLine = lines.find((line) => line.startsWith(AGE_PAYLOAD_PREFIX));
  if (!payloadLine) {
    throw new Error("KEK epoch payload stanza is missing.");
  }

  let fileKey: Uint8Array | null = null;
  for (const line of recipientLines) {
    const stanza = line.slice(AGE_RECIPIENT_PREFIX.length).trim();
    const parts = stanza.split(/\s+/);
    if (parts.length !== 2) continue;
    try {
      const ephemeralPublicKey = base64ToBytes(parts[0]);
      const wrappedFileKeyCombined = base64ToBytes(parts[1]);
      const sharedSecret = x25519.getSharedSecret(privateKey, ephemeralPublicKey);
      const wrapKey = await deriveWrapKey(sharedSecret);
      const candidate = decryptChaChaCombined(wrappedFileKeyCombined, wrapKey);
      if (candidate.length === 32) {
        fileKey = candidate;
        break;
      }
    } catch {
      // Keep trying other stanzas until one matches this identity.
    }
  }

  if (!fileKey) {
    throw new Error("No matching recipient stanza found for local age key.");
  }

  const payloadCombined = base64ToBytes(payloadLine.slice(AGE_PAYLOAD_PREFIX.length).trim());
  return decryptChaChaCombined(payloadCombined, fileKey);
};

// Loads a KEK epoch and imports it as AES-GCM key material for manifest/DEK decryption.
export const loadAndUnwrapKEK = async (
  epochEnvelope: Uint8Array,
  agePrivateKeyBase64: string,
): Promise<CryptoKey> => {
  const kekRaw = await decryptAgeEnvelope(epochEnvelope, agePrivateKeyBase64);
  return importAes256Key(kekRaw);
};

// Decrypts encrypted manifest body bytes into plaintext YAML text.
export const decryptManifestBody = async (ciphertext: Uint8Array, kek: CryptoKey): Promise<string> => {
  try {
    const plaintext = await decryptAesGcmCombined(ciphertext, kek);
    return textDecoder.decode(plaintext);
  } catch (primaryError) {
    // Supports text-safe manifest envelopes where ciphertext is stored as base64 after the header delimiter.
    const encodedCiphertext = textDecoder.decode(ciphertext).trim();
    if (encodedCiphertext.length === 0) {
      throw primaryError;
    }
    try {
      const decodedCiphertext = base64ToBytes(encodedCiphertext);
      const plaintext = await decryptAesGcmCombined(decodedCiphertext, kek);
      return textDecoder.decode(plaintext);
    } catch {
      throw primaryError;
    }
  }
};

// Extracts LFS pointer fields including optional replycant encryption metadata.
export const parseLfsPointer = (raw: string): LfsPointerFields => {
  const lines = raw.split("\n").map((line) => line.trim()).filter((line) => line.length > 0);
  let oid = "";
  let size = 0;
  let kekEpoch: number | null = null;
  let wrappedDek: string | null = null;

  for (const line of lines) {
    if (line.startsWith("oid sha256:")) {
      oid = line.slice("oid sha256:".length).trim();
      continue;
    }
    if (line.startsWith("size ")) {
      const parsedSize = Number.parseInt(line.slice("size ".length).trim(), 10);
      size = Number.isFinite(parsedSize) && parsedSize > 0 ? parsedSize : 0;
      continue;
    }
    if (line.startsWith("x-replycant-kek-epoch ")) {
      const parsedEpoch = Number.parseInt(line.slice("x-replycant-kek-epoch ".length).trim(), 10);
      kekEpoch = Number.isInteger(parsedEpoch) && parsedEpoch > 0 ? parsedEpoch : null;
      continue;
    }
    if (line.startsWith("x-replycant-wrapped-dek ")) {
      const parsedWrapped = line.slice("x-replycant-wrapped-dek ".length).trim();
      wrappedDek = parsedWrapped.length > 0 ? parsedWrapped : null;
    }
  }

  return { oid, size, kekEpoch, wrappedDek };
};

// Converts parsed pointer values into usable encryption metadata, or null when
// any required field is missing so callers cannot address plaintext LFS objects.
export const toLfsEncryptionMeta = (pointer: LfsPointerFields): LfsEncryptionMeta | null => {
  if (!pointer.kekEpoch || !pointer.wrappedDek || !pointer.oid || !pointer.dekBase64) {
    return null;
  }
  return {
    encryptedOid: pointer.oid,
    wrappedDek: pointer.wrappedDek,
    kekEpoch: pointer.kekEpoch,
    dekBase64: pointer.dekBase64,
  };
};

// Unwraps per-object DEK from pointer metadata using the already-unwrapped KEK.
// kekEpoch is authenticated so DEKs cannot be swapped across epochs.
export const unwrapDEK = async (
  wrappedDekBase64: string,
  kek: CryptoKey,
  kekEpoch: number,
): Promise<Uint8Array> => {
  const wrappedCombined = base64ToBytes(wrappedDekBase64);
  return decryptAesGcmCombined(wrappedCombined, kek, dekWrapAad(kekEpoch));
};

// Decrypts chunked AES-GCM binary payloads using index-derived nonces and AAD so
// reorder and trailing truncation fail authentication.
export const decryptBinaryChunked = async (
  encrypted: ArrayBufferLike,
  dek: CryptoKey | Uint8Array,
): Promise<ArrayBuffer> => {
  const dekKey = dek instanceof Uint8Array ? await importAes256Key(dek) : dek;
  const source = new Uint8Array(encrypted);
  if (source.length === 0) {
    return new ArrayBuffer(0);
  }
  const fullEncryptedChunkSize = CHUNK_SIZE + CHUNK_OVERHEAD_BYTES;
  const plaintextChunks: Uint8Array[] = [];
  let offset = 0;
  let index = 0;

  while (offset < source.length) {
    const remaining = source.length - offset;
    const currentChunkSize = Math.min(remaining, fullEncryptedChunkSize);
    if (currentChunkSize < CHUNK_OVERHEAD_BYTES) {
      throw new Error("Encrypted chunk is smaller than tag overhead.");
    }
    const isLast = offset + currentChunkSize === source.length;
    const ciphertextWithTag = source.slice(offset, offset + currentChunkSize);
    const plaintext = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: asBufferSource(chunkNonce(index)),
        additionalData: asBufferSource(chunkAad(index, isLast)),
      },
      dekKey,
      ciphertextWithTag,
    );
    plaintextChunks.push(new Uint8Array(plaintext));
    offset += currentChunkSize;
    index += 1;
  }

  const totalLength = plaintextChunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const output = new Uint8Array(totalLength);
  let outputOffset = 0;
  for (const chunk of plaintextChunks) {
    output.set(chunk, outputOffset);
    outputOffset += chunk.length;
  }
  return output.buffer;
};

// Hashes plaintext bytes as lowercase hex for integrity checks against manifest sha256 fields.
export const sha256Hex = async (data: ArrayBuffer): Promise<string> => {
  const digest = await crypto.subtle.digest("SHA-256", data);
  return bytesToHex(new Uint8Array(digest));
};
