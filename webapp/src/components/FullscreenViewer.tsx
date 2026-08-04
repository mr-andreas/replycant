import { CSSProperties, memo, SyntheticEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { decodeHeicToCanvasBitmap, HeicCanvasBitmap } from "../lib/heicDecoder";
import { runtimeConfig } from "../lib/config";
import { TimelineItem } from "../lib/timeline";
import { AuthImage } from "./AuthImage";
import { MediaFetchPriority } from "../lib/mediaFetchLimiter";
import { decryptBinaryChunked, sha256Hex } from "../lib/gitdb/encryption";
import { fetchAndCacheAuthenticatedMedia } from "../lib/preloadMedia";
import { selectPlaybackStrategy } from "../lib/playback";
import { ensureProxySession, resetProxySession } from "../lib/proxySession";
import { LfsEncryptionMeta } from "../types/manifests";

interface FullscreenViewerProps {
  itemCount: number;
  loadedOffset: number;
  loadedItems: TimelineItem[];
  index: number;
  onClose: () => void;
  onChange: (nextIndex: number) => void;
  mtlsHeaders: Record<string, string> | null;
}

// Tracks the rendered backdrop URL so authenticated LFS sources can be
// represented by browser-safe blob URLs.
interface BackdropImage {
  url: string;
}

// Maintains two backdrop layers so image switches can blend instead of popping.
interface BackdropLayers {
  primary: string | null;
  secondary: string | null;
  visible: "primary" | "secondary";
}

// Scales media to fill the viewport while preserving aspect ratio. Unlike a
// pure max-width/max-height CSS contain, this also enlarges images smaller
// than the viewport so a focused photo always uses the available space, and
// it sizes the element to the visible image so the frosted shadow/rounded
// corners keep hugging the picture instead of an oversized box.
export const computeContainSize = (
  natural: { width: number; height: number },
  container: { width: number; height: number },
): { width: number; height: number } | null => {
  if (natural.width <= 0 || natural.height <= 0 || container.width <= 0 || container.height <= 0) {
    return null;
  }
  const scale = Math.min(container.width / natural.width, container.height / natural.height);
  return { width: natural.width * scale, height: natural.height * scale };
};

// Formats capture timestamps so viewer chrome stays compact while still informative.
const formatViewerDate = (timestamp: string): string =>
  new Date(timestamp).toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });

// Converts byte counts into compact labels so viewers can quickly gauge media size.
const formatFileSize = (bytes: number): string => {
  if (!Number.isFinite(bytes) || bytes <= 0) return "Unknown";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  const rounded = value >= 100 || unitIndex === 0 ? value.toFixed(0) : value.toFixed(1);
  return `${rounded} ${units[unitIndex]}`;
};

// Formats video runtime so media details align with timeline duration labels.
const formatMediaDuration = (duration?: number): string => {
  if (!duration || duration <= 0) return "Unknown";
  const totalSeconds = Math.round(duration);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
  }
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
};

// Maps playback strategies into human labels so users can verify how video is streamed.
const formatPlaybackStrategy = (strategy: ReturnType<typeof selectPlaybackStrategy>): string => {
  if (strategy === "transcode") return "Transcode";
  return "Direct Play";
};

const HEIC_FULL_DECODE_DEBOUNCE_MS = 120;

// Decodes base64 DEK material into bytes for browser-side media decryption.
const base64ToBytes = (encoded: string): Uint8Array =>
  Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));

// Detects expected cancellation signals so rapid navigation does not report
// user-driven supersession as a decoder failure.
const isAbortError = (error: unknown): boolean => {
  if (!(error instanceof Error)) return false;
  return error.name === "AbortError";
};

// Defers expensive HEIC full decode work until selection remains stable long
// enough to matter for what the user is currently viewing.
const waitForAbortableDelay = async (ms: number, signal: AbortSignal): Promise<void> => {
  if (ms <= 0) return;
  if (signal.aborted) {
    const abortError = new Error("Operation aborted");
    abortError.name = "AbortError";
    throw abortError;
  }
  await new Promise<void>((resolve, reject) => {
    const timer = window.setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      window.clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      const abortError = new Error("Operation aborted");
      abortError.name = "AbortError";
      reject(abortError);
    };
    signal.addEventListener("abort", onAbort, { once: true });
  });
};

// Builds a native video URL that carries decryptd inputs; fails closed when
// encryption metadata is absent so ciphertext is never played as plaintext.
const buildDirectPlayVideoUrl = (baseUrl: string, encryption: LfsEncryptionMeta | undefined): string => {
  if (!encryption?.dekBase64) {
    throw new Error(`Missing LFS encryption metadata for video ${baseUrl}`);
  }
  const params = new URLSearchParams({
    dek: encryption.dekBase64,
  });
  return `${baseUrl}?${params.toString()}`;
};

// Resolves which encryption metadata applies to a given fullscreen image source URL.
const resolveStageEncryption = (item: TimelineItem, src: string): LfsEncryptionMeta | undefined => {
  if (src === item.thumbnailUrl) return item.thumbnailEncryption;
  if (src === item.intermediateViewerUrl) return item.intermediateEncryption ?? item.thumbnailEncryption;
  if (src === item.viewerUrl) return item.encryption;
  if (src === item.heicOriginalUrl) return item.encryption;
  return undefined;
};

// Preloads image URLs so fullscreen transitions can swap sources only after bytes are ready.
const preloadImage = async (
  src: string,
  headers: Record<string, string> | null,
  encryption: LfsEncryptionMeta | undefined,
  expectedSha256?: string,
  priority: MediaFetchPriority = "visible",
): Promise<void> => {
  if (src.startsWith("/api/lfs/") && headers) {
    if (!encryption) {
      throw new Error(`Missing LFS encryption metadata for ${src}`);
    }
    await fetchAndCacheAuthenticatedMedia({
      src,
      headers,
      encryption,
      expectedSha256,
      priority,
    });
    return;
  }
  await new Promise<void>((resolve, reject) => {
    const image = new Image();
    image.decoding = "async";
    image.onload = () => resolve();
    image.onerror = () => reject(new Error(`Failed to preload ${src}`));
    image.src = src;
  });
};

// Fetches and decrypts HEIC source bytes; rejects missing encryption or integrity
// mismatches so attacker-substituted ciphertext cannot be decoded as an image.
const fetchHeicBytes = async (
  src: string,
  headers: Record<string, string>,
  encryption: LfsEncryptionMeta | undefined,
  expectedSha256: string,
  signal: AbortSignal,
): Promise<ArrayBuffer> => {
  if (!encryption?.dekBase64) {
    throw new Error(`Missing LFS encryption metadata for HEIC ${src}`);
  }
  const response = await fetch(src, { headers, signal });
  if (!response.ok) {
    throw new Error(`Failed to fetch HEIC source: ${response.status}`);
  }
  const encryptedBytes = await response.arrayBuffer();
  const decryptedBytes = await decryptBinaryChunked(
    encryptedBytes,
    base64ToBytes(encryption.dekBase64),
  );
  const actualSha = await sha256Hex(decryptedBytes);
  if (actualSha !== expectedSha256) {
    throw new Error(
      `Decrypted HEIC sha256 mismatch for ${src}: expected ${expectedSha256}, got ${actualSha}`,
    );
  }
  return decryptedBytes;
};

// Collects progressive image stages so viewer can upgrade quality without blank frames.
const imageStages = (item: TimelineItem): Array<{ src: string; stage: "thumbnail" | "intermediate" | "full" }> => {
  const stages: Array<{ src: string; stage: "thumbnail" | "intermediate" | "full" }> = [
    { src: item.thumbnailUrl, stage: "thumbnail" },
  ];
  if (item.intermediateViewerUrl && item.intermediateViewerUrl !== item.thumbnailUrl) {
    stages.push({ src: item.intermediateViewerUrl, stage: "intermediate" });
  }
  if (!stages.some((candidate) => candidate.src === item.viewerUrl)) {
    stages.push({ src: item.viewerUrl, stage: "full" });
  }
  return stages;
};

// Delivers just the preloadable URLs for adjacent photo entries to accelerate arrow navigation.
const adjacentImageUrls = (item: TimelineItem | undefined): string[] => {
  if (!item || item.mediaType.toLowerCase().includes("video")) return [];
  if (item.isHeic) return [item.thumbnailUrl];
  return imageStages(item)
    .slice(0, 2)
    .map((stage) => stage.src);
};

// Couples each preload URL to its owning timeline item so request metadata stays accurate.
interface AdjacentPreloadCandidate {
  owner: TimelineItem;
  src: string;
}

// Normalizes configured preload depth so runtime tweaks cannot produce invalid traversal behavior.
const normalizePreloadCount = (value: number): number => {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.floor(value));
};

// Produces ordered adjacent preload targets (+N then -N) to optimize perceived next/previous latency.
const buildAdjacentPreloadCandidates = (
  loadedOffset: number,
  loadedItems: TimelineItem[],
  index: number,
  afterCount: number,
  beforeCount: number,
): AdjacentPreloadCandidate[] => {
  const candidates: AdjacentPreloadCandidate[] = [];
  const maxDistance = Math.max(afterCount, beforeCount);
  for (let distance = 1; distance <= maxDistance; distance += 1) {
    if (distance <= afterCount) {
      const next = itemAt(index + distance, loadedOffset, loadedItems);
      if (next) {
        for (const src of adjacentImageUrls(next)) {
          candidates.push({ owner: next, src });
        }
      }
    }
    if (distance <= beforeCount) {
      const previous = itemAt(index - distance, loadedOffset, loadedItems);
      if (previous) {
        for (const src of adjacentImageUrls(previous)) {
          candidates.push({ owner: previous, src });
        }
      }
    }
  }
  return candidates;
};

// Resolves a loaded item by global index from the sparse window.
const itemAt = (
  globalIndex: number,
  loadedOffset: number,
  loadedItems: TimelineItem[],
): TimelineItem | undefined => {
  const localIndex = globalIndex - loadedOffset;
  if (localIndex < 0 || localIndex >= loadedItems.length) return undefined;
  return loadedItems[localIndex];
};

// Delivers focused media browsing that mirrors native photo app keyboard flows.
export const FullscreenViewer = memo(({ itemCount, loadedOffset, loadedItems, index, onClose, onChange, mtlsHeaders }: FullscreenViewerProps) => {
  const item = itemAt(index, loadedOffset, loadedItems);
  const [activeSrc, setActiveSrc] = useState<string>(item?.thumbnailUrl ?? "");
  const [activeStage, setActiveStage] = useState<"thumbnail" | "intermediate" | "full">("thumbnail");
  const [heicBitmap, setHeicBitmap] = useState<HeicCanvasBitmap | null>(null);
  const [heicCanvasPainted, setHeicCanvasPainted] = useState(false);
  const [backdropImage, setBackdropImage] = useState<BackdropImage | null>(null);
  const [backdropLayers, setBackdropLayers] = useState<BackdropLayers>({
    primary: null,
    secondary: null,
    visible: "primary",
  });
  const isVideo = item?.mediaType.toLowerCase().includes("video") ?? false;
  const viewerUrl = item?.viewerUrl ?? "";
  const viewerRef = useRef<HTMLElement | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const heicCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const imageContainerRef = useRef<HTMLDivElement | null>(null);
  const [containerSize, setContainerSize] = useState<{ width: number; height: number } | null>(null);
  const [videoNaturalSize, setVideoNaturalSize] = useState<{ width: number; height: number } | null>(null);
  const [videoReady, setVideoReady] = useState(false);
  const preloadedUrlsRef = useRef(new Set<string>());
  const mtlsHeadersRef = useRef<Record<string, string> | null>(mtlsHeaders);
  const idleTimerRef = useRef<number | null>(null);
  const [chromeIdle, setChromeIdle] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [isDownloading, setIsDownloading] = useState(false);
  const [showInfo, setShowInfo] = useState(false);
  const loadedEnd = loadedOffset + loadedItems.length;

  // Reveals controls and starts inactivity timeout so fullscreen chrome stays unobtrusive.
  const bumpChromeVisibility = useCallback(() => {
    setChromeIdle(false);
    if (idleTimerRef.current !== null) {
      window.clearTimeout(idleTimerRef.current);
    }
    idleTimerRef.current = window.setTimeout(() => {
      setChromeIdle(true);
    }, 2500);
  }, []);

  // Toggles browser fullscreen so focused image review can use a true black canvas.
  const handleToggleFullscreen = useCallback(async () => {
    if (document.fullscreenElement === viewerRef.current) {
      await document.exitFullscreen();
      return;
    }
    await viewerRef.current?.requestFullscreen();
  }, []);

  // Prevents key-repeat from outrunning sparse paging by allowing only one step
  // beyond loaded boundaries until new data arrives.
  const canNavigateTo = useCallback((nextIndex: number): boolean => {
    if (nextIndex < 0 || nextIndex >= itemCount) return false;
    if (itemAt(nextIndex, loadedOffset, loadedItems)) return true;
    return nextIndex === loadedOffset - 1 || nextIndex === loadedEnd;
  }, [itemCount, loadedEnd, loadedItems, loadedOffset]);

  // Centralizes sparse-aware stepping so buttons and keyboard share the same
  // boundary behavior under rapid navigation.
  const stepIndex = useCallback((delta: -1 | 1): void => {
    const nextIndex = index + delta;
    if (!canNavigateTo(nextIndex)) return;
    onChange(nextIndex);
  }, [canNavigateTo, index, onChange]);

  // Keeps deferred playback/session-recovery callbacks aligned with the latest
  // mTLS headers without retriggering video source setup.
  useEffect(() => {
    mtlsHeadersRef.current = mtlsHeaders;
  }, [mtlsHeaders]);

  // Maintains expected keyboard navigation for fullscreen media review sessions.
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        if (document.fullscreenElement === viewerRef.current) {
          void document.exitFullscreen();
        } else {
          onClose();
        }
      }
      if (
        event.key.toLowerCase() === "f" &&
        !event.ctrlKey &&
        !event.metaKey &&
        !event.altKey
      ) {
        event.preventDefault();
        void handleToggleFullscreen();
      }
      if (
        event.key.toLowerCase() === "i" &&
        !event.ctrlKey &&
        !event.metaKey &&
        !event.altKey
      ) {
        event.preventDefault();
        setShowInfo((current) => !current);
      }
      if (event.key === " " && isVideo) {
        event.preventDefault();
        const video = videoRef.current;
        if (video) {
          if (video.paused) {
            void video.play();
          } else {
            video.pause();
          }
        }
      }
      if (event.key === "ArrowRight") stepIndex(1);
      if (event.key === "ArrowLeft") stepIndex(-1);
      bumpChromeVisibility();
    };

    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [bumpChromeVisibility, handleToggleFullscreen, isVideo, onClose, stepIndex]);

  // Tracks browser fullscreen transitions so icon/title reflect the actual mode.
  useEffect(() => {
    const handleFullscreenChange = () => {
      setIsFullscreen(document.fullscreenElement === viewerRef.current);
      bumpChromeVisibility();
    };
    document.addEventListener("fullscreenchange", handleFullscreenChange);
    return () => document.removeEventListener("fullscreenchange", handleFullscreenChange);
  }, [bumpChromeVisibility]);

  // Tracks the available stage area so media can be scaled to fill it. Driven
  // by the rendered container (rather than the window) so the 56px chrome
  // padding and native fullscreen transitions are accounted for automatically.
  useEffect(() => {
    const element = imageContainerRef.current;
    if (!element) return;
    const measure = () => setContainerSize({ width: element.clientWidth, height: element.clientHeight });
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [isVideo]);

  useEffect(() => {
    if (isVideo) setVideoNaturalSize(null);
  }, [isVideo, item?.key]);

  // Resets video readiness on item changes so each clip keeps its own loading placeholder.
  useEffect(() => {
    setVideoReady(false);
  }, [item?.key, isVideo]);

  const updateVideoNaturalSize = useCallback((video: HTMLVideoElement) => {
    const { videoWidth, videoHeight } = video;
    if (videoWidth > 0 && videoHeight > 0) {
      setVideoNaturalSize({ width: videoWidth, height: videoHeight });
    }
  }, []);

  const handleVideoMetadata = useCallback((event: SyntheticEvent<HTMLVideoElement>) => {
    updateVideoNaturalSize(event.currentTarget);
  }, [updateVideoNaturalSize]);

  // Hides the poster overlay once the browser can render playable frames.
  const handleVideoCanPlay = useCallback(() => {
    setVideoReady(true);
  }, []);

  useEffect(() => {
    if (!isVideo) return;
    const video = videoRef.current;
    if (!video) return;
    const update = () => updateVideoNaturalSize(video);
    update();
    video.addEventListener("loadedmetadata", update);
    video.addEventListener("resize", update);
    return () => {
      video.removeEventListener("loadedmetadata", update);
      video.removeEventListener("resize", update);
    };
  }, [isVideo, item?.key, viewerUrl, updateVideoNaturalSize]);

  // Sizes the visible media to fill the viewport while preserving aspect ratio,
  // using known dimensions up front and video metadata as a fallback.
  const fittedMediaStyle = useMemo<CSSProperties | undefined>(() => {
    if (!item || !containerSize) return undefined;
    const naturalSize =
      isVideo && videoNaturalSize
        ? videoNaturalSize
        : item.width > 0 && item.height > 0
          ? { width: item.width, height: item.height }
          : null;
    if (!naturalSize) return undefined;
    const fit = computeContainSize(naturalSize, containerSize);
    if (!fit) return undefined;
    return { width: `${fit.width}px`, height: `${fit.height}px` };
  }, [isVideo, item?.width, item?.height, videoNaturalSize, containerSize?.width, containerSize?.height]);

  // Materializes LFS-backed backdrop images as blob URLs because CSS image
  // requests cannot attach the browser-owned mTLS headers required by the proxy.
  useEffect(() => {
    if (!activeSrc) {
      setBackdropImage(null);
      return;
    }
    if (!activeSrc.startsWith("/api/lfs/")) {
      setBackdropImage({ url: activeSrc });
      return;
    }
    if (!item || !mtlsHeaders) {
      setBackdropImage(null);
      return;
    }

    let cancelled = false;
    let objectUrl: string | null = null;
    const controller = new AbortController();
    void (async () => {
      try {
        const encryption = resolveStageEncryption(item, activeSrc);
        if (!encryption) {
          throw new Error(`Missing LFS encryption metadata for ${activeSrc}`);
        }
        const blob = await fetchAndCacheAuthenticatedMedia({
          src: activeSrc,
          headers: mtlsHeaders,
          encryption,
          expectedSha256: activeSrc === item.viewerUrl && !item.isHeic ? item.sha256 : undefined,
          signal: controller.signal,
        });
        if (cancelled) return;
        objectUrl = URL.createObjectURL(blob);
        setBackdropImage({ url: objectUrl });
      } catch {
        if (!cancelled) setBackdropImage(null);
      }
    })();

    return () => {
      cancelled = true;
      controller.abort();
      if (objectUrl) {
        const urlToRevoke = objectUrl;
        window.setTimeout(() => URL.revokeObjectURL(urlToRevoke), 350);
      }
    };
  }, [activeSrc, item, mtlsHeaders]);

  // Alternates two backdrop layers so rapid image navigation always crossfades.
  useEffect(() => {
    const nextUrl = backdropImage?.url ?? null;

    // Stages the incoming backdrop URL on the hidden layer so blur compositing
    // can begin before the opacity transition makes the layer visible.
    setBackdropLayers((current) => {
      const visibleUrl =
        current.visible === "primary" ? current.primary : current.secondary;
      if (visibleUrl === nextUrl) {
        return current;
      }
      const hiddenLayer = current.visible === "primary" ? "secondary" : "primary";
      if (hiddenLayer === "primary") {
        return {
          ...current,
          primary: nextUrl,
        };
      }
      return {
        ...current,
        secondary: nextUrl,
      };
    });

    const frameHandle = window.requestAnimationFrame(() => {
      setBackdropLayers((current) => {
        const visibleUrl =
          current.visible === "primary" ? current.primary : current.secondary;
        if (visibleUrl === nextUrl) {
          return current;
        }
        return {
          ...current,
          visible: current.visible === "primary" ? "secondary" : "primary",
        };
      });
    });

    return () => {
      window.cancelAnimationFrame(frameHandle);
    };
  }, [backdropImage?.url]);

  // Keeps controls visible briefly whenever a new media item opens.
  useEffect(() => {
    bumpChromeVisibility();
    return () => {
      if (idleTimerRef.current !== null) {
        window.clearTimeout(idleTimerRef.current);
      }
    };
  }, [bumpChromeVisibility, index]);

  // Resets image source when selection changes so fullscreen always tries original first.
  useEffect(() => {
    if (!item || isVideo) return;
    setActiveSrc(item.thumbnailUrl);
    setActiveStage("thumbnail");
    setHeicBitmap(null);
    setHeicCanvasPainted(false);

    let cancelled = false;
    const controller = new AbortController();
    // Steps media quality up progressively while keeping HEIC full decode
    // cancellable and avoiding unsupported direct HEIC image promotion.
    const progressiveLoad = async () => {
      const stages = imageStages(item);
      for (const stage of stages.slice(1)) {
        if (
          stage.stage === "full" &&
          item.isHeic &&
          item.heicOriginalUrl &&
          mtlsHeaders
        ) {
          try {
            await waitForAbortableDelay(HEIC_FULL_DECODE_DEBOUNCE_MS, controller.signal);
            const sourceBuffer = await fetchHeicBytes(
              item.heicOriginalUrl,
              mtlsHeaders,
              item.encryption,
              item.sha256,
              controller.signal,
            );
            const decoded = await decodeHeicToCanvasBitmap(sourceBuffer, 50_000_000, controller.signal);
            if (cancelled) return;
            setHeicBitmap(decoded);
            setActiveStage("full");
            continue;
          } catch (error) {
            if (cancelled) return;
            if (!isAbortError(error)) {
              console.warn("[replycant-heic] client decode failed", error);
            }
            continue;
          }
        }
        if (
          stage.stage === "full" &&
          item.isHeic &&
          stage.src === item.viewerUrl
        ) {
          // Keeps HEIC fallback on the thumbnail/intermediate raster path because
          // many browsers cannot render the original HEIC blob in <img>.
          continue;
        }
        try {
          await preloadImage(
            stage.src,
            mtlsHeaders,
            resolveStageEncryption(item, stage.src),
            stage.stage === "full" ? item.sha256 : undefined,
          );
        } catch {
          continue;
        }
        if (cancelled) return;
        setActiveSrc(stage.src);
        setActiveStage(stage.stage);
      }
    };

    void progressiveLoad();
    return () => {
      cancelled = true;
      controller.abort();
    };
  }, [
    isVideo,
    item?.heicOriginalUrl,
    item?.intermediateViewerUrl,
    item?.isHeic,
    item?.key,
    item?.thumbnailUrl,
    item?.viewerUrl,
    mtlsHeaders,
  ]);

  // Draws decoded HEIC pixel data into canvas and promotes it only after painting completes.
  useEffect(() => {
    if (!heicBitmap) {
      setHeicCanvasPainted(false);
      return;
    }
    if (typeof ImageData === "undefined") return;
    const canvas = heicCanvasRef.current;
    if (!canvas) return;
    const context = canvas.getContext("2d");
    if (!context) return;
    canvas.width = heicBitmap.width;
    canvas.height = heicBitmap.height;
    const imageData = new ImageData(
      new Uint8ClampedArray(heicBitmap.pixels),
      heicBitmap.width,
      heicBitmap.height,
    );
    context.putImageData(imageData, 0, 0);
    setHeicCanvasPainted(true);
  }, [heicBitmap]);

  // Forces hls.js playback so encrypted streams can always attach DEK headers per request.
  useEffect(() => {
    if (!item || !isVideo || !viewerUrl) return;
    const video = videoRef.current;
    if (!video) return;
    const strategy = selectPlaybackStrategy();
    if (strategy === "directPlay") {
      if (!item.encryption?.dekBase64) {
        console.error("[replycant-video] missing LFS encryption metadata for direct play");
        return;
      }
      const directPlayUrl = buildDirectPlayVideoUrl(viewerUrl, item.encryption);
      video.src = directPlayUrl;

      // The proxy holds mTLS material in memory, so a proxy restart drops the
      // session a media element depends on. Re-register once and retry before
      // surfacing a playback failure to the user.
      let hasRetried = false;
      const recoverFromLostSession = () => {
        if (hasRetried) return;
        hasRetried = true;
        resetProxySession();
        void ensureProxySession(mtlsHeadersRef.current)
          .then(() => {
            video.src = directPlayUrl;
            video.load();
          })
          .catch(() => undefined);
      };
      video.addEventListener("error", recoverFromLostSession);

      return () => {
        video.removeEventListener("error", recoverFromLostSession);
        video.removeAttribute("src");
      };
    }

    let cancelled = false;
    let disposeHls: (() => void) | undefined;

    const setupPlayback = async () => {
      const hlsModule = await import("hls.js");
      if (cancelled) return;
      const Hls = hlsModule.default;
      if (!Hls.isSupported()) {
        console.warn("[replycant-video] hls.js is not supported in this browser runtime");
        return;
      }

      if (!item.encryption?.dekBase64) {
        console.error("[replycant-video] missing LFS encryption metadata for HLS playback");
        return;
      }
      const encryptionHeaders = {
        "X-Replycant-DEK": item.encryption.dekBase64,
      };
      const hls = new Hls({
        xhrSetup: (xhr) => {
          const latestMtlsHeaders = mtlsHeadersRef.current;
          if (latestMtlsHeaders) {
            for (const [key, value] of Object.entries(latestMtlsHeaders)) {
              xhr.setRequestHeader(key, value);
            }
          }
          for (const [key, value] of Object.entries(encryptionHeaders)) {
            xhr.setRequestHeader(key, value);
          }
        },
      });
      hls.on(Hls.Events.MANIFEST_PARSED, () => {
        // Starts on the sharpest rendition so users don't see an initially blurry frame.
        hls.startLevel = hls.levels.length - 1;
      });
      hls.loadSource(viewerUrl);
      hls.attachMedia(video);
      disposeHls = () => hls.destroy();
    };

    void setupPlayback();

    return () => {
      cancelled = true;
      disposeHls?.();
      video.removeAttribute("src");
    };
  }, [isVideo, item?.encryption?.dekBase64, item?.key, viewerUrl]);

  // Preloads adjacent photo variants so moving prev/next feels immediate during rapid browsing.
  useEffect(() => {
    const timer = window.setTimeout(() => {
      const preloadAfterCount = normalizePreloadCount(runtimeConfig.viewerPreloadAfterCount);
      const preloadBeforeCount = normalizePreloadCount(runtimeConfig.viewerPreloadBeforeCount);
      const candidates = buildAdjacentPreloadCandidates(loadedOffset, loadedItems, index, preloadAfterCount, preloadBeforeCount);
      for (const { owner, src } of candidates) {
        if (preloadedUrlsRef.current.has(src)) continue;
        preloadedUrlsRef.current.add(src);
        const encryption = resolveStageEncryption(owner, src);
        const expectedSha256 = src === owner.viewerUrl ? owner.sha256 : undefined;
        void preloadImage(src, mtlsHeaders, encryption, expectedSha256, "preload").catch(() => undefined);
      }
    }, 120);
    return () => {
      window.clearTimeout(timer);
    };
  }, [index, loadedItems, loadedOffset, mtlsHeaders]);

  // Downloads the original media bytes so users can export exactly what they captured.
  const handleDownload = useCallback(async () => {
    if (!item || !mtlsHeaders || isDownloading) return;
    setIsDownloading(true);
    try {
      if (!item.encryption) {
        throw new Error(`Missing LFS encryption metadata for ${item.downloadUrl}`);
      }
      const blob = await fetchAndCacheAuthenticatedMedia({
        src: item.downloadUrl,
        headers: mtlsHeaders,
        encryption: item.encryption,
        expectedSha256: item.sha256,
      });
      const objectUrl = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = objectUrl;
      anchor.download = item.originalFileName;
      anchor.rel = "noopener";
      anchor.click();
      URL.revokeObjectURL(objectUrl);
    } catch (error) {
      console.warn("[replycant-media] failed to download original media", error);
    } finally {
      setIsDownloading(false);
    }
  }, [isDownloading, item, mtlsHeaders]);

  if (!item) {
    return (
      <aside
        ref={viewerRef}
        className={`viewer${chromeIdle ? " idle" : ""}`}
        aria-modal="true"
        role="dialog"
        onMouseMove={bumpChromeVisibility}
      >
        <div className="viewer-backdrop" />
        <div className="viewer-scrim" />
        <div className="viewer-stage">
          <div className="viewer-image-container">
            <div className="media-placeholder">Loading media...</div>
          </div>
        </div>
      </aside>
    );
  }

  // Once the decoded HEIC canvas has painted it covers the thumbnail exactly,
  // so the underlying fallback img is hidden to avoid stacking a second
  // identical drop shadow. The img stays mounted as a decode-failure fallback.
  const heicCanvasCovers = Boolean(item.isHeic && heicBitmap && heicCanvasPainted);
  const playbackStrategy = selectPlaybackStrategy();
  const videoResolution = isVideo && videoNaturalSize ? videoNaturalSize : null;
  const resolutionWidth = videoResolution?.width ?? item.width;
  const resolutionHeight = videoResolution?.height ?? item.height;
  const resolutionLabel =
    resolutionWidth > 0 && resolutionHeight > 0 ? `${resolutionWidth} x ${resolutionHeight}` : "Unknown";

  return (
    <aside
      ref={viewerRef}
      className={`viewer${chromeIdle ? " idle" : ""}${showInfo ? " info-open" : ""}`}
      aria-modal="true"
      role="dialog"
      onMouseMove={bumpChromeVisibility}
    >
      <div
        className={`viewer-backdrop${backdropLayers.visible === "primary" ? "" : " viewer-backdrop-hidden"}`}
        style={backdropLayers.primary ? { backgroundImage: `url(${backdropLayers.primary})` } : undefined}
      />
      <div
        className={`viewer-backdrop${backdropLayers.visible === "secondary" ? "" : " viewer-backdrop-hidden"}`}
        style={backdropLayers.secondary ? { backgroundImage: `url(${backdropLayers.secondary})` } : undefined}
      />
      <div className="viewer-scrim" />
      <div className="viewer-stage">
        <div className="viewer-image-container" ref={imageContainerRef}>
          {isVideo ? (
            <>
              <video
                ref={videoRef}
                className="viewer-video"
                controls
                playsInline
                autoPlay
                preload="metadata"
                style={fittedMediaStyle}
                onLoadedMetadata={handleVideoMetadata}
                onCanPlay={handleVideoCanPlay}
              />
              <div
                className={`viewer-video-poster${videoReady ? " viewer-video-poster-hidden" : ""}`}
                aria-hidden="true"
              >
                <AuthImage
                  src={item.thumbnailUrl}
                  alt=""
                  className="viewer-video-poster-image"
                  decoding="async"
                  loading="eager"
                  headers={mtlsHeaders}
                  encryption={item.thumbnailEncryption}
                  style={fittedMediaStyle}
                />
                <svg viewBox="0 0 24 24" aria-hidden="true" className="viewer-video-spinner">
                  <path d="M12 4a8 8 0 1 0 8 8" />
                </svg>
              </div>
            </>
          ) : (
            <>
              <AuthImage
                src={activeSrc}
                alt={item.timestamp}
                className={`viewer-image${heicCanvasCovers ? " viewer-image-covered" : ""}`}
                decoding="async"
                loading="eager"
                headers={mtlsHeaders}
                encryption={resolveStageEncryption(item, activeSrc)}
                expectedSha256={activeStage === "full" && !item.isHeic ? item.sha256 : undefined}
                style={fittedMediaStyle}
              />
              {item.isHeic && heicBitmap ? (
                <canvas
                  ref={heicCanvasRef}
                  role="img"
                  aria-label={item.timestamp}
                  className={`viewer-heic-canvas${heicCanvasPainted ? " viewer-heic-ready" : ""}`}
                  style={fittedMediaStyle}
                />
              ) : null}
            </>
          )}
        </div>
      </div>
      <div className="viewer-chrome">
        <div className="viewer-top-actions">
          <button
            type="button"
            className="viewer-circle-button"
            title="Info"
            aria-label="Info"
            aria-pressed={showInfo}
            onClick={() => setShowInfo((current) => !current)}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <circle cx="12" cy="12" r="9" />
              <path d="M12 11v5M12 8h.01" />
            </svg>
          </button>
          <button type="button" className="viewer-circle-button" title="Close (Esc)" aria-label="Close" onClick={onClose}>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>
        <button
          type="button"
          className="viewer-nav viewer-nav-left"
          title="Previous (ArrowLeft)"
          aria-label="Previous"
          onClick={() => stepIndex(-1)}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M15 5l-7 7 7 7" />
          </svg>
        </button>
        <button
          type="button"
          className="viewer-nav viewer-nav-right"
          title="Next (ArrowRight)"
          aria-label="Next"
          onClick={() => stepIndex(1)}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M9 5l7 7-7 7" />
          </svg>
        </button>
        {showInfo ? (
          <section className="viewer-info-panel" aria-label="Media details">
            <h2 className="viewer-info-title">Details</h2>
            <dl className="viewer-info-list">
              <div className="viewer-info-row">
                <dt>Filename</dt>
                <dd>{item.originalFileName}</dd>
              </div>
              <div className="viewer-info-row">
                <dt>Date</dt>
                <dd>{formatViewerDate(item.timestamp)}</dd>
              </div>
              <div className="viewer-info-row">
                <dt>Resolution</dt>
                <dd>{resolutionLabel}</dd>
              </div>
              <div className="viewer-info-row">
                <dt>MIME type</dt>
                <dd>{item.mimeType}</dd>
              </div>
              <div className="viewer-info-row">
                <dt>File size</dt>
                <dd>{formatFileSize(item.filesize)}</dd>
              </div>
              {isVideo ? (
                <>
                  <div className="viewer-info-row">
                    <dt>Duration</dt>
                    <dd>{formatMediaDuration(item.duration)}</dd>
                  </div>
                  <div className="viewer-info-row">
                    <dt>Playback</dt>
                    <dd>{formatPlaybackStrategy(playbackStrategy)}</dd>
                  </div>
                </>
              ) : null}
            </dl>
          </section>
        ) : null}
        <div className="viewer-toolbar">
          <span className="viewer-date-label">{formatViewerDate(item.timestamp)}</span>
          <span className="viewer-toolbar-separator" />
          <button
            type="button"
            className={`viewer-tool-button${isDownloading ? " loading" : ""}`}
            title={!mtlsHeaders ? "Download unavailable" : isDownloading ? "Downloading" : "Download"}
            aria-label="Download"
            onClick={() => {
              void handleDownload();
            }}
            disabled={isDownloading || !mtlsHeaders}
          >
            {isDownloading ? (
              <svg viewBox="0 0 24 24" aria-hidden="true" className="viewer-spinner">
                <path d="M12 4a8 8 0 1 0 8 8" />
              </svg>
            ) : (
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M12 3v12M7 10l5 5 5-5M5 21h14" />
              </svg>
            )}
          </button>
          <button
            type="button"
            className="viewer-tool-button"
            title={isFullscreen ? "Exit fullscreen" : "Enter fullscreen"}
            aria-label={isFullscreen ? "Exit fullscreen" : "Enter fullscreen"}
            onClick={() => {
              void handleToggleFullscreen();
            }}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              {isFullscreen ? (
                <path d="M9 9H5V5M15 9h4V5M9 15H5v4M15 15h4v4" />
              ) : (
                <path d="M8 3H5a2 2 0 0 0-2 2v3M16 3h3a2 2 0 0 1 2 2v3M8 21H5a2 2 0 0 1-2-2v-3M16 21h3a2 2 0 0 0 2-2v-3" />
              )}
            </svg>
          </button>
        </div>
      </div>
    </aside>
  );
});

FullscreenViewer.displayName = "FullscreenViewer";
