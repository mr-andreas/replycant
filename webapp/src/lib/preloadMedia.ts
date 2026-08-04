import { decryptBinaryChunked, sha256Hex } from "./gitdb/encryption";
import { LfsEncryptionMeta } from "../types/manifests";
import {
  MediaFetchPriority,
  cachePreloadedBlob,
  getPreloadedBlob,
  getPreloadedObjectUrl,
  markPreloadedObjectUrlDecoded,
  runWithMediaFetchLimit,
} from "./mediaFetchLimiter";

interface PreloadMediaOptions {
  src: string;
  headers: Record<string, string>;
  encryption: LfsEncryptionMeta;
  expectedSha256?: string;
  signal?: AbortSignal;
  priority?: MediaFetchPriority;
}

// Decodes base64 DEK material so encrypted media objects can be decrypted client-side.
const base64ToBytes = (encoded: string): Uint8Array =>
  Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));

// Infers image MIME from magic bytes so object URLs decode in Firefox after
// ciphertext responses lose their Content-Type at the decrypt boundary.
const sniffImageMimeType = (bytes: ArrayBuffer): string => {
  const u8 = new Uint8Array(bytes);
  if (u8.length >= 3 && u8[0] === 0xff && u8[1] === 0xd8 && u8[2] === 0xff) {
    return "image/jpeg";
  }
  if (
    u8.length >= 8
    && u8[0] === 0x89
    && u8[1] === 0x50
    && u8[2] === 0x4e
    && u8[3] === 0x47
    && u8[4] === 0x0d
    && u8[5] === 0x0a
    && u8[6] === 0x1a
    && u8[7] === 0x0a
  ) {
    return "image/png";
  }
  if (u8.length >= 6 && u8[0] === 0x47 && u8[1] === 0x49 && u8[2] === 0x46 && u8[3] === 0x38) {
    return "image/gif";
  }
  if (
    u8.length >= 12
    && u8[0] === 0x52
    && u8[1] === 0x49
    && u8[2] === 0x46
    && u8[3] === 0x46
    && u8[8] === 0x57
    && u8[9] === 0x45
    && u8[10] === 0x42
    && u8[11] === 0x50
  ) {
    return "image/webp";
  }
  return "application/octet-stream";
};

// Warms cached object URLs so thumbnails are decoded before mounted tiles point at them.
const warmCachedImage = async (src: string, priority: MediaFetchPriority): Promise<void> => {
  if (typeof Image === "undefined") return;
  if (typeof HTMLImageElement === "undefined" || typeof HTMLImageElement.prototype.decode !== "function") return;
  const objectUrl = getPreloadedObjectUrl(src, priority);
  if (!objectUrl) return;
  const image = new Image();
  image.decoding = "async";
  image.src = objectUrl;
  await image.decode()
    .then(() => markPreloadedObjectUrlDecoded(src))
    .catch(() => undefined);
};

// Fetches authenticated media bytes, decrypts them, verifies integrity, and caches the blob.
// Rejects missing encryption metadata so a stripped pointer cannot render attacker content.
export const fetchAndCacheAuthenticatedMedia = async ({
  src,
  headers,
  encryption,
  expectedSha256,
  signal,
  priority = "visible",
}: PreloadMediaOptions): Promise<Blob> => {
  if (!encryption?.dekBase64) {
    throw new Error(`Missing LFS encryption metadata for ${src}`);
  }
  const cachedBlob = getPreloadedBlob(src, priority);
  if (cachedBlob) {
    await warmCachedImage(src, priority);
    return cachedBlob;
  }
  const blob = await runWithMediaFetchLimit(async () => {
    const response = await fetch(src, { headers, signal });
    if (!response.ok) throw new Error(`Media fetch failed: ${response.status}`);
    const encryptedBytes = await response.arrayBuffer();
    const decryptedBytes = await decryptBinaryChunked(
      encryptedBytes,
      base64ToBytes(encryption.dekBase64),
    );
    if (expectedSha256) {
      const actualSha = await sha256Hex(decryptedBytes);
      if (actualSha !== expectedSha256) {
        throw new Error(
          `Decrypted media sha256 mismatch for ${src}: expected ${expectedSha256}, got ${actualSha}`,
        );
      }
    }
    return new Blob([decryptedBytes], { type: sniffImageMimeType(decryptedBytes) });
  }, priority);
  cachePreloadedBlob(src, blob, priority);
  await warmCachedImage(src, priority);
  return blob;
};
