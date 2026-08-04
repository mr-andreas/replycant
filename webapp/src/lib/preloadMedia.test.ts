import { beforeEach, describe, expect, it, vi } from "vitest";
import { runtimeConfig } from "./config";
import { fetchAndCacheAuthenticatedMedia } from "./preloadMedia";
import * as encryption from "./gitdb/encryption";

const testEncryption = {
  encryptedOid: "oid",
  wrappedDek: "wrapped",
  kekEpoch: 1,
  dekBase64: btoa(String.fromCharCode(...new Uint8Array(32).fill(1))),
};

describe("preloadMedia", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  // Ensures missing encryption metadata fails closed instead of rendering ciphertext as an image.
  it("rejects media fetches without encryption metadata", async () => {
    await expect(
      fetchAndCacheAuthenticatedMedia({
        src: "/api/lfs/objects/preload-1",
        headers: { authorization: "x" },
        encryption: undefined as never,
        priority: "preload",
      }),
    ).rejects.toThrow(/Missing LFS encryption metadata/);
  });

  // Ensures decrypted plaintext integrity mismatches are hard failures, not warnings.
  it("throws when decrypted sha256 does not match expected", async () => {
    vi.spyOn(encryption, "decryptBinaryChunked").mockResolvedValue(new TextEncoder().encode("payload").buffer);
    vi.spyOn(encryption, "sha256Hex").mockResolvedValue("actual-hash");
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        arrayBuffer: async () => new ArrayBuffer(8),
      })) as unknown as typeof fetch,
    );

    await expect(
      fetchAndCacheAuthenticatedMedia({
        src: "/api/lfs/objects/preload-2",
        headers: { authorization: "x" },
        encryption: testEncryption,
        expectedSha256: "expected-hash",
        priority: "preload",
      }),
    ).rejects.toThrow(/sha256 mismatch/);
  });

  it("caches authenticated fetches so repeated preloads skip network", async () => {
    vi.spyOn(encryption, "decryptBinaryChunked").mockResolvedValue(new TextEncoder().encode("x").buffer);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        arrayBuffer: async () => new ArrayBuffer(8),
      })) as unknown as typeof fetch,
    );

    await fetchAndCacheAuthenticatedMedia({
      src: "/api/lfs/objects/preload-cache-1",
      headers: { authorization: "x" },
      encryption: testEncryption,
      priority: "preload",
    });
    await fetchAndCacheAuthenticatedMedia({
      src: "/api/lfs/objects/preload-cache-1",
      headers: { authorization: "x" },
      encryption: testEncryption,
      priority: "preload",
    });
    expect(global.fetch).toHaveBeenCalledTimes(1);
  });

  // Ensures decrypted PNG bytes get a MIME type so Firefox can paint object URLs.
  it("sets blob type from sniffed PNG magic bytes", async () => {
    const pngHeader = Uint8Array.from([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    ]);
    vi.spyOn(encryption, "decryptBinaryChunked").mockResolvedValue(pngHeader.buffer);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        ok: true,
        arrayBuffer: async () => new ArrayBuffer(8),
      })) as unknown as typeof fetch,
    );

    const blob = await fetchAndCacheAuthenticatedMedia({
      src: "/api/lfs/objects/preload-png-type",
      headers: { authorization: "x" },
      encryption: testEncryption,
      priority: "visible",
    });
    expect(blob.type).toBe("image/png");
  });

  it("defaults timeline preload depth to 25 before and 25 after", () => {
    expect(runtimeConfig.timelinePreloadBeforeCount).toBe(25);
    expect(runtimeConfig.timelinePreloadAfterCount).toBe(25);
  });
});
