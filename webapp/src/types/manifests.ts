import type { LfsEncryptionMeta } from "../modules/gitdb/encryption";

export interface ManifestMetadata {
  name: string;
  deviceSpace: string;
}

export interface ManifestEnvelope<TKind extends string, TSpec> {
  apiVersion: "media.replycant.com/v1alpha1";
  kind: TKind;
  metadata: ManifestMetadata;
  spec: TSpec;
  status: Record<string, never>;
}

export interface OriginalLocation {
  latitude: number;
  longitude: number;
  altitude?: number;
}

export interface OriginalSpec {
  id: string;
  localID?: string;
  sha256: string;
  path: string;
  filesize: number;
  mediaType: string;
  width: number;
  height: number;
  modifiedAt?: string;
  duration?: number;
  mimeType?: string;
  location?: OriginalLocation;
  isFavorite: boolean;
  isHidden: boolean;
  burstIdentifier?: string;
  createdAt: string;
  takenAt?: string;
  clientCTime?: string;
  guessedTakenAt?: string;
}

export interface ThumbnailEntry {
  name: string;
  sha256: string;
  width: number;
  height: number;
  filesize: number;
}

export interface ThumbnailSetSpec {
  originalRef: string;
  thumbnails: ThumbnailEntry[];
}

export type OriginalManifest = ManifestEnvelope<"Original", OriginalSpec>;
export type ThumbnailSetManifest = ManifestEnvelope<"ThumbnailSet", ThumbnailSetSpec>;
export type AnyManifest = OriginalManifest | ThumbnailSetManifest;

// Re-exported from its canonical gitdb-owned location for backwards compatibility.
export type { LfsEncryptionMeta } from "../modules/gitdb/encryption";

// Captures the normalized media fields the timeline and fullscreen viewer require for rendering decisions.
export interface NormalizedOriginal {
  key: string;
  deviceSpace: string;
  name: string;
  id: string;
  sha256: string;
  filesize: number;
  mediaType: string;
  mimeType: string;
  width: number;
  height: number;
  duration?: number;
  takenAt: string;
  files: {
    originalPath: string;
    lfsHash: string;
  };
  encryption?: LfsEncryptionMeta;
}

export interface NormalizedThumbnail {
  key: string;
  originalKey: string;
  width: number;
  height: number;
  sha256: string;
  encryption?: LfsEncryptionMeta;
}

export interface NormalizedManifestSet {
  originals: NormalizedOriginal[];
  thumbnails: NormalizedThumbnail[];
}
