type Task<T> = () => Promise<T>;

const DEFAULT_MAX_CONCURRENT = 8;
const PRELOADED_BLOB_CACHE_LIMIT = 200;

interface QueueItem<T> {
  task: Task<T>;
  resolve: (value: T) => void;
  reject: (reason?: unknown) => void;
}

export type MediaFetchPriority = "visible" | "preload";

// Limits parallel authenticated media fetches so large timelines do not exhaust browser resources.
class MediaFetchLimiter {
  private readonly visibleQueue: QueueItem<unknown>[] = [];
  private readonly preloadQueue: QueueItem<unknown>[] = [];
  private visibleRunning = 0;
  private preloadRunning = 0;

  constructor(private readonly maxConcurrent: number) {}

  // Enqueues media work by priority so visible items always start before speculative preload.
  run<T>(task: Task<T>, priority: MediaFetchPriority): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const queuedTask: Task<unknown> = () => task();
      const resolveQueued = (value: unknown) => resolve(value as T);
      const queueItem: QueueItem<unknown> = { task: queuedTask, resolve: resolveQueued, reject };
      if (priority === "preload") {
        this.preloadQueue.push(queueItem);
      } else {
        this.visibleQueue.push(queueItem);
      }
      this.drain();
    });
  }

  // Resolves aggregate running count to enforce the global concurrency cap.
  private totalRunning(): number {
    return this.visibleRunning + this.preloadRunning;
  }

  // Dequeues the next item while preserving strict visible-first behavior.
  private dequeueNext(): { item: QueueItem<unknown>; priority: MediaFetchPriority } | null {
    const visibleItem = this.visibleQueue.shift();
    if (visibleItem) return { item: visibleItem, priority: "visible" };
    if (this.visibleRunning > 0) return null;
    const preloadItem = this.preloadQueue.shift();
    if (!preloadItem) return null;
    return { item: preloadItem, priority: "preload" };
  }

  private drain(): void {
    while (this.totalRunning() < this.maxConcurrent) {
      const next = this.dequeueNext();
      if (!next) return;
      const { item, priority } = next;
      if (priority === "visible") {
        this.visibleRunning += 1;
      } else {
        this.preloadRunning += 1;
      }
      void item.task()
        .then((value) => item.resolve(value))
        .catch((error) => item.reject(error))
        .finally(() => {
          if (priority === "visible") {
            this.visibleRunning = Math.max(0, this.visibleRunning - 1);
          } else {
            this.preloadRunning = Math.max(0, this.preloadRunning - 1);
          }
          this.drain();
        });
    }
  }
}

const sharedLimiter = new MediaFetchLimiter(DEFAULT_MAX_CONCURRENT);

// Tracks cached media metadata needed to reuse URLs without repaint flicker.
interface CachedBlob {
  blob: Blob;
  decoded?: boolean;
  priority: MediaFetchPriority;
  objectUrl?: string;
  refCount: number;
}

const preloadedBlobCache = new Map<string, CachedBlob>();

// Describes whether a cached object URL is safe to paint immediately.
export interface CachedObjectUrl {
  decoded: boolean;
  url: string;
}

// Detects whether the current browser can explicitly decode object URLs before display.
const supportsImageDecode = (): boolean =>
  typeof HTMLImageElement !== "undefined" && typeof HTMLImageElement.prototype.decode === "function";

// Promotes visible media cache entries so speculative preload cannot evict them first.
const touchPreloadedBlob = (src: string, entry: CachedBlob, priority: MediaFetchPriority): CachedBlob => {
  preloadedBlobCache.delete(src);
  preloadedBlobCache.set(src, {
    blob: entry.blob,
    decoded: entry.decoded,
    objectUrl: entry.objectUrl,
    priority: priority === "visible" ? "visible" : entry.priority,
    refCount: entry.refCount,
  });
  return preloadedBlobCache.get(src)!;
};

// Revokes object URLs only when their cache entry leaves the shared cache.
const deletePreloadedBlob = (src: string): void => {
  const entry = preloadedBlobCache.get(src);
  if (entry?.objectUrl) {
    URL.revokeObjectURL(entry.objectUrl);
  }
  preloadedBlobCache.delete(src);
};

// Removes cache entries by priority so preload blobs are discarded before visible thumbnails.
const trimPreloadedBlobCache = (): void => {
  while (preloadedBlobCache.size > PRELOADED_BLOB_CACHE_LIMIT) {
    let keyToDelete: string | undefined;
    for (const [key, entry] of preloadedBlobCache) {
      if (entry.priority === "preload" && entry.refCount === 0) {
        keyToDelete = key;
        break;
      }
    }
    if (!keyToDelete) {
      for (const [key, entry] of preloadedBlobCache) {
        if (entry.refCount === 0) {
          keyToDelete = key;
          break;
        }
      }
    }
    if (!keyToDelete) break;
    deletePreloadedBlob(keyToDelete);
  }
};

// Stores media blobs with their request priority so visible thumbnails survive preload churn.
export const cachePreloadedBlob = (
  src: string,
  blob: Blob,
  priority: MediaFetchPriority = "visible",
): void => {
  const existingEntry = preloadedBlobCache.get(src);
  if (existingEntry) {
    // Keeps a live blob URL stable so duplicate completion races do not blank rendered thumbnails.
    const preservedEntry: CachedBlob = {
      blob: existingEntry.blob,
      decoded: existingEntry.decoded,
      objectUrl: existingEntry.objectUrl,
      priority: priority === "visible" ? "visible" : existingEntry.priority,
      refCount: existingEntry.refCount,
    };
    preloadedBlobCache.delete(src);
    preloadedBlobCache.set(src, preservedEntry);
    return;
  }
  preloadedBlobCache.set(src, { blob, priority, refCount: 0 });
  trimPreloadedBlobCache();
};

// Returns cached media and upgrades entries used by visible rendering.
export const getPreloadedBlob = (
  src: string,
  priority: MediaFetchPriority = "visible",
): Blob | undefined => {
  const entry = preloadedBlobCache.get(src);
  if (!entry) return undefined;
  return touchPreloadedBlob(src, entry, priority).blob;
};

// Returns stable object URL state so callers can avoid painting undecoded cached images.
export const getPreloadedObjectUrlState = (
  src: string,
  priority: MediaFetchPriority = "visible",
): CachedObjectUrl | undefined => {
  const entry = preloadedBlobCache.get(src);
  if (!entry) return undefined;
  const touchedEntry = touchPreloadedBlob(src, entry, priority);
  if (!touchedEntry.objectUrl) {
    touchedEntry.objectUrl = URL.createObjectURL(touchedEntry.blob);
    touchedEntry.decoded = !supportsImageDecode();
  }
  return { decoded: Boolean(touchedEntry.decoded), url: touchedEntry.objectUrl };
};

// Returns a stable object URL for cached media so remounted images avoid URL churn.
export const getPreloadedObjectUrl = (
  src: string,
  priority: MediaFetchPriority = "visible",
): string | undefined => getPreloadedObjectUrlState(src, priority)?.url;

// Retains a mounted image reference so trim never revokes its active object URL.
export const retainPreloadedObjectUrl = (src: string): void => {
  const entry = preloadedBlobCache.get(src);
  if (!entry) return;
  entry.refCount += 1;
};

// Releases mounted image ownership so trim can evict once no tile uses the URL.
export const releasePreloadedObjectUrl = (src: string): void => {
  const entry = preloadedBlobCache.get(src);
  if (!entry) return;
  entry.refCount = Math.max(0, entry.refCount - 1);
};

// Marks cached object URLs as decoded once a preload has warmed them in the browser.
export const markPreloadedObjectUrlDecoded = (src: string): void => {
  const entry = preloadedBlobCache.get(src);
  if (!entry) return;
  entry.decoded = true;
};

// Reuses one limiter process-wide so all AuthImage/fullscreen requests share backpressure and priority.
export const runWithMediaFetchLimit = <T>(
  task: Task<T>,
  priority: MediaFetchPriority = "visible",
): Promise<T> => sharedLimiter.run(task, priority);
