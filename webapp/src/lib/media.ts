import { NormalizedOriginal, NormalizedThumbnail } from "../types/manifests";
import { selectPlaybackStrategy } from "./playback";

// Selects an efficient thumbnail candidate to reduce bandwidth while preserving clarity.
export const pickBestThumbnail = (
  thumbnails: NormalizedThumbnail[],
  targetWidth: number,
  devicePixelRatio: number,
): NormalizedThumbnail | null => {
  if (!thumbnails.length) return null;
  const target = targetWidth * devicePixelRatio;
  const sorted = [...thumbnails].sort((a, b) => a.width - b.width);
  return sorted.find((thumb) => thumb.width >= target) ?? sorted.at(-1) ?? null;
};

// Addresses media only by encryption-backed OIDs so plaintext sha256 hashes
// cannot be used after a hostile server strips pointer metadata.
export const resolveMediaUrl = (
  original: NormalizedOriginal,
  thumbnail: NormalizedThumbnail | null,
  useOriginal: boolean,
): string => {
  if (!useOriginal) {
    if (!thumbnail) return `/api/lfs/objects/${original.files.lfsHash}`;
    return `/api/lfs/objects/${thumbnail.encryption?.encryptedOid ?? ""}`;
  }

  const mime = original.mimeType.toLowerCase();
  const mediaType = original.mediaType.toLowerCase();
  const isVideo = mediaType.includes("video") || mime.startsWith("video/");
  if (isVideo) {
    const strategy = selectPlaybackStrategy();
    if (strategy === "directPlay") {
      return `/api/decryptd/objects/${original.files.lfsHash}`;
    }
    if (strategy === "transcode") {
      const duration = Math.max(1, Math.round(original.duration ?? 1));
      return `/api/transcoded/hls/${original.files.lfsHash}/${duration}/playlist.m3u8`;
    }
    return `/api/decryptd/objects/${original.files.lfsHash}`;
  }

  return `/api/lfs/objects/${original.files.lfsHash}`;
};

// Provides a high-quality stepping stone image so fullscreen can appear sharp quickly before final media resolves.
export const resolveIntermediateMediaUrl = (
  original: NormalizedOriginal,
  thumbnail: NormalizedThumbnail | null,
): string | null => {
  const mime = original.mimeType.toLowerCase();
  const mediaType = original.mediaType.toLowerCase();
  const isVideo = mediaType.includes("video") || mime.startsWith("video/");
  if (isVideo) return null;

  if (thumbnail) return `/api/lfs/objects/${thumbnail.encryption?.encryptedOid ?? ""}`;

  const isHeic = mime.includes("heic") || mime.includes("heif");
  if (isHeic) return null;

  return `/api/lfs/objects/${original.files.lfsHash}`;
};
