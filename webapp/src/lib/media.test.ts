import { describe, expect, it } from "vitest";
import { pickBestThumbnail, resolveMediaUrl } from "./media";

const encryption = {
  encryptedOid: "encrypted-oid",
  wrappedDek: "wrapped",
  kekEpoch: 1,
  dekBase64: "ZGVr",
};

describe("media resolver", () => {
  it("picks nearest matching thumbnail", () => {
    const selected = pickBestThumbnail(
      [
        { key: "a", originalKey: "o", width: 150, height: 150, sha256: "x" },
        { key: "b", originalKey: "o", width: 600, height: 600, sha256: "y" },
      ],
      220,
      2,
    );
    expect(selected?.sha256).toBe("y");
  });

  it("routes heic originals through lfs endpoint", () => {
    const url = resolveMediaUrl(
      {
        key: "k",
        deviceSpace: "d",
        name: "n",
        id: "id",
        sha256: "hash",
        filesize: 1024,
        mediaType: "photo",
        mimeType: "image/heic",
        width: 10,
        height: 10,
        duration: undefined,
        takenAt: "2026-01-01T00:00:00Z",
        files: { originalPath: "/x", lfsHash: "hash" },
        encryption: { ...encryption, encryptedOid: "hash" },
      },
      null,
      true,
    );
    expect(url).toBe("/api/lfs/objects/hash");
  });

  it("routes video originals through decryptd direct play endpoint", () => {
    const url = resolveMediaUrl(
      {
        key: "k2",
        deviceSpace: "d",
        name: "n2",
        id: "id2",
        sha256: "hash2",
        filesize: 2048,
        mediaType: "video",
        mimeType: "video/quicktime",
        width: 10,
        height: 10,
        duration: 12.6,
        takenAt: "2026-01-01T00:00:00Z",
        files: { originalPath: "/v.mov", lfsHash: "hash2" },
        encryption: { ...encryption, encryptedOid: "hash2" },
      },
      null,
      true,
    );
    expect(url).toBe("/api/decryptd/objects/hash2");
  });

  // Ensures plaintext sha256 is never used once encryption metadata is absent.
  it("does not fall back to thumbnail sha256 when encryption metadata is missing", () => {
    const url = resolveMediaUrl(
      {
        key: "k3",
        deviceSpace: "d",
        name: "n3",
        id: "id3",
        sha256: "plaintext-hash",
        filesize: 1,
        mediaType: "photo",
        mimeType: "image/jpeg",
        width: 10,
        height: 10,
        takenAt: "2026-01-01T00:00:00Z",
        files: { originalPath: "/x", lfsHash: "" },
      },
      { key: "t", originalKey: "k3", width: 10, height: 10, sha256: "thumb-plaintext" },
      false,
    );
    expect(url).toBe("/api/lfs/objects/");
    expect(url).not.toContain("thumb-plaintext");
  });
});
