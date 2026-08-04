import yaml from "js-yaml";
import {
  AnyManifest,
  LfsEncryptionMeta,
  NormalizedManifestSet,
  NormalizedOriginal,
  NormalizedThumbnail,
  OriginalManifest,
  ThumbnailSetManifest,
} from "../types/manifests";
import { LfsPointerFields, toLfsEncryptionMeta } from "./gitdb/encryption";

// Normalizes yaml timestamps so timeline sorting is stable regardless of parser date coercion.
const toIsoTimestamp = (value: unknown, fallback: string): string => {
  if (typeof value === "string" && value.length > 0) return value;
  return fallback;
};

// Keeps parsing strict so corrupt manifests fail fast and are user-visible.
export const parseManifest = (raw: string): AnyManifest | null => {
  const parsed = yaml.load(raw, { schema: yaml.JSON_SCHEMA });
  if (!parsed || typeof parsed !== "object") return null;
  const manifest = parsed as Partial<AnyManifest>;
  if (manifest.apiVersion !== "media.replycant.com/v1alpha1") return null;
  if (manifest.kind !== "Original" && manifest.kind !== "ThumbnailSet") return null;
  if (!manifest.metadata || !manifest.spec) return null;
  return manifest as AnyManifest;
};

// Couples parsed manifests with optional pointer metadata so normalization can carry decryption context.
export interface ParsedManifestRecord {
  manifest: AnyManifest;
  pointer: LfsPointerFields | null;
  thumbnailPointers?: Record<string, LfsPointerFields>;
}

// Resolves LFS OID and encryption metadata only when pointer fields are complete,
// so plaintext or stripped-metadata objects are never addressable for media fetch.
const resolveLfsMetadata = (
  pointer: LfsPointerFields | null,
): { lfsHash: string; encryption: LfsEncryptionMeta | undefined } => {
  if (!pointer) {
    return { lfsHash: "", encryption: undefined };
  }
  const encryption = toLfsEncryptionMeta(pointer);
  if (!encryption) {
    return { lfsHash: "", encryption: undefined };
  }
  return { lfsHash: encryption.encryptedOid, encryption };
};

// Converts protocol manifests into read-optimized rows used by timeline and viewer.
export const normalizeManifests = (
  manifests: AnyManifest[] | ParsedManifestRecord[],
): NormalizedManifestSet => {
  const originals: NormalizedOriginal[] = [];
  const thumbnails: NormalizedThumbnail[] = [];

  for (const input of manifests) {
    const manifest = "manifest" in input ? input.manifest : input;
    const pointer = "manifest" in input ? input.pointer : null;
    if (manifest.kind === "Original") {
      const original = manifest as OriginalManifest;
      if (!original.spec.takenAt) continue;
      const key = `${original.metadata.deviceSpace}/${original.metadata.name}`;
      const lfsMetadata = resolveLfsMetadata(pointer);
      originals.push({
        key,
        deviceSpace: original.metadata.deviceSpace,
        name: original.metadata.name,
        id: original.spec.id,
        sha256: original.spec.sha256,
        filesize: original.spec.filesize,
        mediaType: original.spec.mediaType,
        mimeType: original.spec.mimeType ?? "application/octet-stream",
        width: original.spec.width,
        height: original.spec.height,
        duration: original.spec.duration,
        takenAt: toIsoTimestamp(original.spec.takenAt, ""),
        files: {
          originalPath: original.spec.path,
          lfsHash: lfsMetadata.lfsHash,
        },
        encryption: lfsMetadata.encryption,
      });
      continue;
    }

    const thumb = manifest as ThumbnailSetManifest;
    const originalRefBits = thumb.spec.originalRef.split("/");
    const originalName = originalRefBits.at(-1);
    if (!originalName) continue;
    const originalDeviceSpace = originalRefBits[0] ?? thumb.metadata.deviceSpace;
    const thumbnailPointers = "manifest" in input ? input.thumbnailPointers : undefined;

    for (const entry of thumb.spec.thumbnails) {
      const entryPointer = thumbnailPointers?.[entry.name] ?? null;
      const lfsMetadata = resolveLfsMetadata(entryPointer);
      thumbnails.push({
        key: `${thumb.metadata.deviceSpace}/${entry.name}`,
        originalKey: `${originalDeviceSpace}/${originalName}`,
        width: entry.width,
        height: entry.height,
        sha256: entry.sha256,
        encryption: lfsMetadata.encryption,
      });
    }
  }

  originals.sort((a, b) => String(a.takenAt).localeCompare(String(b.takenAt)));
  return { originals, thumbnails };
};
