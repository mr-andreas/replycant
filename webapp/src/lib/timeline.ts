import { NormalizedOriginal, NormalizedThumbnail } from "../types/manifests";
import { pickBestThumbnail, resolveIntermediateMediaUrl, resolveMediaUrl } from "./media";

// Represents a rendered timeline entry with enough metadata for viewer behavior and navigation.
export interface TimelineItem {
  key: string;
  dayKey: string;
  monthKey: string;
  yearKey: string;
  timestamp: string;
  mediaType: string;
  sha256: string;
  filesize: number;
  duration?: number;
  width: number;
  height: number;
  isHeic: boolean;
  heicOriginalUrl: string | null;
  mimeType: string;
  encryption?: NormalizedOriginal["encryption"];
  thumbnailEncryption?: NormalizedThumbnail["encryption"];
  intermediateEncryption?: NormalizedThumbnail["encryption"];
  thumbnailUrl: string;
  intermediateViewerUrl: string | null;
  viewerUrl: string;
  downloadUrl: string;
  originalFileName: string;
}

// Describes one sidebar month bucket backed by the gitdb derived store.
export interface MonthEntry {
  yearKey: string;
  monthKey: string;
  count: number;
  firstTakenAt: string;
  globalOffset: number;
}

// Stable position marker for cursor-based timeline pagination.
export interface TimelineCursor {
  takenAt: string;
  key: string;
}

// Builds MonthEntry[] with cumulative globalOffset from raw month count rows.
export const buildMonthEntries = (
  rows: Array<{ monthKey: string; count: number; firstTakenAt: string }>,
): MonthEntry[] => {
  let offset = 0;
  return rows.map((row) => {
    const entry: MonthEntry = {
      yearKey: row.monthKey.slice(0, 4),
      monthKey: row.monthKey,
      count: row.count,
      firstTakenAt: row.firstTakenAt,
      globalOffset: offset,
    };
    offset += row.count;
    return entry;
  });
};

// Derives total item count from the month index without a separate query.
export const totalCountFromMonthIndex = (months: MonthEntry[]): number => {
  if (months.length === 0) return 0;
  const last = months[months.length - 1];
  return last.globalOffset + last.count;
};

// Finds which month a global index belongs to via binary search on globalOffset (O(log months)).
export const monthKeyForGlobalIndex = (months: MonthEntry[], globalIndex: number): string | null => {
  if (months.length === 0) return null;
  let lo = 0;
  let hi = months.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (months[mid].globalOffset <= globalIndex) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return months[lo].monthKey;
};

// Identifies HEIC/HEIF originals so fullscreen can try client-side decode before server fallback.
const isHeicMimeType = (mimeType: string): boolean => {
  const mime = mimeType.toLowerCase();
  return mime.includes("heic") || mime.includes("heif");
};

// Extracts a stable file name for downloads from manifest paths.
const fileNameFromPath = (path: string): string => {
  const parts = path.split("/").filter(Boolean);
  return parts.at(-1) ?? "download";
};

// Builds month-grouped timeline entries so navigation can jump predictably.
export const buildTimeline = (
  originals: NormalizedOriginal[],
  thumbByOriginalKey: Map<string, NormalizedThumbnail[]>,
  tileWidth: number,
  dpr: number,
): TimelineItem[] =>
  originals.map((original) => {
    const thumbnails = thumbByOriginalKey.get(original.key) ?? [];
    const thumbnail = pickBestThumbnail(thumbnails, tileWidth, dpr);
    const intermediateThumbnail = pickBestThumbnail(thumbnails, Math.max(tileWidth * 2, 960), dpr);
    const takenDate = new Date(original.takenAt);
    const dayKey = takenDate.toISOString().slice(0, 10);
    const monthKey = `${takenDate.getUTCFullYear()}-${String(takenDate.getUTCMonth() + 1).padStart(2, "0")}`;
    const yearKey = String(takenDate.getUTCFullYear());

    const isHeic = isHeicMimeType(original.mimeType);

    return {
      key: original.key,
      dayKey,
      monthKey,
      yearKey,
      timestamp: original.takenAt,
      mediaType: original.mediaType,
      sha256: original.sha256,
      filesize: original.filesize,
      duration: original.duration,
      width: original.width,
      height: original.height,
      isHeic,
      heicOriginalUrl: isHeic ? `/api/lfs/objects/${original.files.lfsHash}` : null,
      mimeType: original.mimeType,
      encryption: original.encryption,
      thumbnailEncryption: thumbnail?.encryption,
      intermediateEncryption: intermediateThumbnail?.encryption,
      thumbnailUrl: resolveMediaUrl(original, thumbnail, false),
      intermediateViewerUrl: resolveIntermediateMediaUrl(original, intermediateThumbnail),
      viewerUrl: resolveMediaUrl(original, thumbnail, true),
      downloadUrl: `/api/lfs/objects/${original.files.lfsHash}`,
      originalFileName: fileNameFromPath(original.files.originalPath),
    };
  });

// Finds the first item whose timestamp matches or follows `takenAt` using binary search
// so month-jump scrolling resolves an index without scanning the full list.
export const findItemIndexByTakenAt = (items: TimelineItem[], takenAt: string): number => {
  let lo = 0;
  let hi = items.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (items[mid].timestamp < takenAt) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return Math.min(lo, items.length - 1);
};
