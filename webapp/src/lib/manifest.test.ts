import { describe, expect, it } from "vitest";
import { normalizeManifests, parseManifest } from "./manifest";

describe("manifest parsing", () => {
  it("parses valid original manifest", () => {
    const raw = `apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: test
  deviceSpace: device
spec:
  id: id
  sha256: hash
  path: /tmp/a.jpg
  filesize: 1
  mediaType: photo
  width: 10
  height: 10
  isFavorite: false
  isHidden: false
  createdAt: 2026-01-01T00:00:00Z
status: {}`;
    const parsed = parseManifest(raw);
    expect(parsed?.kind).toBe("Original");
  });

  it("normalizes manifests into timelines and refs", () => {
    const original = parseManifest(`apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: test
  deviceSpace: device
spec:
  id: id
  sha256: hash
  path: /tmp/a.heic
  filesize: 1
  mediaType: photo
  width: 10
  height: 10
  mimeType: image/heic
  isFavorite: false
  isHidden: false
  createdAt: 2026-01-01T00:00:00Z
  takenAt: 2025-01-01T00:00:00Z
status: {}`)!;
    const thumb = parseManifest(`apiVersion: media.replycant.com/v1alpha1
kind: ThumbnailSet
metadata:
  name: test-thumbs
  deviceSpace: device
spec:
  originalRef: device/media.replycant.com/v1alpha1/Original/test
  thumbnails:
    - name: test-thumb-100
      sha256: thash
      width: 100
      height: 100
      filesize: 2
status: {}`)!;

    const normalized = normalizeManifests([original, thumb]);
    expect(normalized.originals).toHaveLength(1);
    expect(normalized.thumbnails[0]?.originalKey).toBe("device/test");
  });

  it("keeps yaml timestamps as strings", () => {
    const original = parseManifest(`apiVersion: media.replycant.com/v1alpha1\nkind: Original\nmetadata:\n  name: test-date\n  deviceSpace: device\nspec:\n  id: id\n  sha256: hash\n  path: /tmp/a.heic\n  filesize: 1\n  mediaType: photo\n  width: 10\n  height: 10\n  isFavorite: false\n  isHidden: false\n  createdAt: 2026-01-01T00:00:00Z\n  takenAt: 2025-01-01T00:00:00Z\nstatus: {}`)!;
    expect(original.kind).toBe("Original");
    if (original.kind !== "Original") {
      throw new Error("Expected an Original manifest.");
    }
    expect(typeof original.spec.createdAt).toBe("string");
    expect(typeof original.spec.takenAt).toBe("string");
    expect(original.spec.takenAt).toContain("2025-01-01");
  });

  it("preserves original duration for video playback routing", () => {
    const original = parseManifest(`apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: test-video
  deviceSpace: device
spec:
  id: id
  sha256: hash
  path: /tmp/a.mov
  filesize: 1
  mediaType: video
  width: 10
  height: 10
  duration: 7.5
  isFavorite: false
  isHidden: false
  createdAt: 2026-01-01T00:00:00Z
  takenAt: 2025-01-01T00:00:00Z
status: {}`)!;
    const normalized = normalizeManifests([original]);
    expect(normalized.originals[0]?.duration).toBe(7.5);
  });

  it("excludes originals without takenAt even when guessedTakenAt is present", () => {
    const original = parseManifest(`apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: guessed-only
  deviceSpace: device
spec:
  id: guessed-only
  sha256: hash
  path: /tmp/a.jpg
  filesize: 1
  mediaType: photo
  width: 10
  height: 10
  isFavorite: false
  isHidden: false
  createdAt: 2026-01-01T00:00:00Z
  guessedTakenAt: 2025-01-01T00:00:00Z
status: {}`)!;
    const normalized = normalizeManifests([original]);
    expect(normalized.originals).toHaveLength(0);
  });

  it("preserves decrypted dekBase64 when normalizing pointer metadata", () => {
    const original = parseManifest(`apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: encrypted-photo
  deviceSpace: device
spec:
  id: encrypted-photo
  sha256: hash
  path: /tmp/a.jpg
  filesize: 1
  mediaType: photo
  width: 10
  height: 10
  isFavorite: false
  isHidden: false
  createdAt: 2026-01-01T00:00:00Z
  takenAt: 2025-01-01T00:00:00Z
status: {}`)!;

    const normalized = normalizeManifests([
      {
        manifest: original,
        pointer: {
          oid: "encrypted-oid",
          size: 1,
          kekEpoch: 1,
          wrappedDek: "wrapped-dek",
          dekBase64: "decoded-dek",
        } as any,
      },
    ]);

    expect(normalized.originals[0]?.encryption?.dekBase64).toBe("decoded-dek");
  });
});
