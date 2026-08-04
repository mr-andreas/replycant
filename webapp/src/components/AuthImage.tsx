import { CSSProperties, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  getPreloadedObjectUrlState,
  releasePreloadedObjectUrl,
  retainPreloadedObjectUrl,
} from "../lib/mediaFetchLimiter";
import { fetchAndCacheAuthenticatedMedia } from "../lib/preloadMedia";
import { LfsEncryptionMeta } from "../types/manifests";

interface AuthImageProps {
  src: string;
  alt: string;
  className?: string;
  loading?: "eager" | "lazy";
  decoding?: "async" | "sync" | "auto";
  headers: Record<string, string> | null;
  encryption?: LfsEncryptionMeta;
  expectedSha256?: string;
  style?: CSSProperties;
}

interface BlobUrlState {
  src: string;
  url: string;
  ready: boolean;
}

// Creates an object URL during initial mount when preload cache already has the authenticated bytes.
const cachedBlobUrlState = (
  src: string,
  requiresAuth: boolean,
  headers: Record<string, string> | null,
): BlobUrlState | null => {
  if (!requiresAuth || !headers) return null;
  const objectUrl = getPreloadedObjectUrlState(src);
  if (!objectUrl) return null;
  return { src, url: objectUrl.url, ready: false };
};

// Fetches LFS-backed image content with mTLS headers so browser-owned identities work for media rendering.
export const AuthImage = ({
  src,
  alt,
  className,
  loading,
  decoding,
  headers,
  encryption,
  expectedSha256,
  style,
}: AuthImageProps) => {
  const requiresAuth = src.startsWith("/api/lfs/");
  const anchorRef = useRef<HTMLSpanElement | null>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);
  const [blobUrl, setBlobUrl] = useState<BlobUrlState | null>(() => {
    const cachedState = cachedBlobUrlState(src, requiresAuth, headers);
    return cachedState;
  });
  const [fallbackBlobUrl, setFallbackBlobUrl] = useState<BlobUrlState | null>(null);
  const [failed, setFailed] = useState(false);
  const [isNearViewport, setIsNearViewport] = useState(false);

  // Delays authenticated media fetches until tiles are near viewport to avoid
  // request floods.
  useEffect(() => {
    if (!requiresAuth) return;
    const element = anchorRef.current;
    if (!element) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          setIsNearViewport(true);
        }
      },
      { rootMargin: "300px" },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [requiresAuth, src]);

  useEffect(() => {
    if (!requiresAuth || !headers) {
      setBlobUrl(null);
      setFallbackBlobUrl(null);
      return;
    }
    setFailed(false);
    const shouldLoad = loading === "eager" || isNearViewport;
    if (!shouldLoad) return;
    if (blobUrl?.src === src) return;
    let cancelled = false;
    const controller = new AbortController();
    void (async () => {
      try {
        const cachedObjectUrl = getPreloadedObjectUrlState(src);
        if (cachedObjectUrl) {
          if (cancelled) return;
          setBlobUrl((current) => {
            if (current && current.src !== src) setFallbackBlobUrl(current);
            return { src, url: cachedObjectUrl.url, ready: false };
          });
          setFailed(false);
          return;
        }
        if (!encryption) {
          throw new Error(`Missing LFS encryption metadata for ${src}`);
        }
        await fetchAndCacheAuthenticatedMedia({
          src,
          headers,
          encryption,
          expectedSha256,
          signal: controller.signal,
          priority: "visible",
        });
        const objectUrl = getPreloadedObjectUrlState(src);
        if (!objectUrl) throw new Error("Cached media object URL unavailable after fetch");
        if (cancelled) return;
        setBlobUrl((current) => {
          if (current && current.src !== src) setFallbackBlobUrl(current);
          return { src, url: objectUrl.url, ready: false };
        });
        setFailed(false);
      } catch {
        if (!cancelled) {
          setFailed(true);
          setBlobUrl(null);
        }
      }
    })();
    return () => {
      cancelled = true;
      controller.abort();
    };
  }, [blobUrl, encryption, expectedSha256, headers, isNearViewport, loading, requiresAuth, src]);

  // Holds cache ownership while the tile is mounted so trim cannot revoke the active object URL.
  useLayoutEffect(() => {
    if (!blobUrl) return;
    retainPreloadedObjectUrl(blobUrl.src);
    return () => releasePreloadedObjectUrl(blobUrl.src);
  }, [blobUrl?.src]);

  // Keeps the fallback URL alive during source transitions so crossfades do not revoke the old image.
  useLayoutEffect(() => {
    if (!fallbackBlobUrl) return;
    retainPreloadedObjectUrl(fallbackBlobUrl.src);
    return () => releasePreloadedObjectUrl(fallbackBlobUrl.src);
  }, [fallbackBlobUrl?.src]);

  // Uses image.decode to flip readiness only after this concrete element is paint-ready.
  useEffect(() => {
    if (!blobUrl || blobUrl.src !== src || blobUrl.ready) return;
    const image = imageRef.current;
    if (!image) return;
    let cancelled = false;
    image.decode()
      .then(() => {
        if (cancelled) return;
        setBlobUrl((current) => (
          current?.src === src ? { ...current, ready: true } : current
        ));
        setFallbackBlobUrl(null);
      })
      .catch(() => {
        if (cancelled) return;
        setFailed(true);
        setBlobUrl(null);
      });
    return () => {
      cancelled = true;
    };
  }, [blobUrl, src]);

  if (requiresAuth) {
    if (!headers) return <span ref={anchorRef} className="media-placeholder">Locked media</span>;
    if (failed) return <span className="media-placeholder">Media unavailable</span>;
    if (blobUrl?.src !== src) {
      const fallback = fallbackBlobUrl ?? blobUrl;
      if (!fallback) return <span ref={anchorRef} className="media-placeholder">Loading...</span>;
      return (
        <img
          ref={imageRef}
          src={fallback.url}
          alt={alt}
          className={className}
          loading={loading}
          decoding={decoding}
          style={style}
          onError={() => {
            setFailed(true);
            setBlobUrl(null);
            setFallbackBlobUrl(null);
          }}
        />
      );
    }
    return (
      <>
        {!blobUrl.ready && !fallbackBlobUrl ? <span ref={anchorRef} className="media-placeholder">Loading...</span> : null}
        {!blobUrl.ready && fallbackBlobUrl ? (
          <img
            src={fallbackBlobUrl.url}
            alt={alt}
            className={className}
            loading={loading}
            decoding={decoding}
            style={style}
          />
        ) : null}
        <img
          ref={imageRef}
          src={blobUrl.url}
          alt={alt}
          className={className}
          loading={loading}
          decoding={decoding}
          style={!blobUrl.ready ? { ...style, inset: 0, opacity: 0, position: "absolute" } : style}
          onError={() => {
            setFailed(true);
            setBlobUrl(null);
          }}
        />
      </>
    );
  }
  return <img src={src} alt={alt} className={className} loading={loading} decoding={decoding} style={style} />;
};
