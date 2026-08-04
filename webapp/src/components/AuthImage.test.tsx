import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { cachePreloadedBlob, getPreloadedBlob, markPreloadedObjectUrlDecoded } from "../lib/mediaFetchLimiter";
import * as encryptionModule from "../lib/gitdb/encryption";
import { AuthImage } from "./AuthImage";

const testEncryption = {
  encryptedOid: "abc",
  wrappedDek: "wrapped",
  kekEpoch: 1,
  dekBase64: "ZGVr",
};

type IOCallback = IntersectionObserverCallback;

let observedCallback: IOCallback | null = null;

interface DeferredPromise {
  promise: Promise<void>;
  resolve: () => void;
  reject: (error?: unknown) => void;
}

// Creates a controllable promise so decode timing can be asserted deterministically.
const createDeferredPromise = (): DeferredPromise => {
  let resolve: () => void = () => {};
  let reject: (error?: unknown) => void = () => {};
  const promise = new Promise<void>((resolvePromise, rejectPromise) => {
    resolve = () => resolvePromise();
    reject = (error?: unknown) => rejectPromise(error);
  });
  return { promise, resolve, reject };
};

// Mocks IntersectionObserver so tests can control visibility transitions deterministically.
class MockIntersectionObserver {
  constructor(callback: IOCallback) {
    observedCallback = callback;
  }
  observe() {}
  disconnect() {}
  unobserve() {}
  takeRecords() { return []; }
  readonly root = null;
  readonly rootMargin = "300px";
  readonly thresholds = [0];
}

describe("AuthImage", () => {
  beforeEach(() => {
    observedCallback = null;
    vi.restoreAllMocks();
    vi.stubGlobal("IntersectionObserver", MockIntersectionObserver);
    Object.defineProperty(HTMLImageElement.prototype, "decode", {
      configurable: true,
      value: vi.fn(async () => undefined),
    });
    vi.spyOn(encryptionModule, "decryptBinaryChunked").mockResolvedValue(new TextEncoder().encode("x").buffer);
    vi.stubGlobal("fetch", vi.fn(async () => ({
      ok: true,
      arrayBuffer: async () => new ArrayBuffer(8),
      blob: async () => new Blob(["x"]),
    })) as unknown as typeof fetch);
    vi.stubGlobal("URL", {
      createObjectURL: vi.fn(() => "blob:test"),
      revokeObjectURL: vi.fn(),
    });
  });

  it("does not eagerly fetch authenticated media before entering viewport", async () => {
    render(
      <AuthImage
        src="/api/lfs/objects/abc"
        alt="media"
        headers={{ authorization: "x" }}
        encryption={testEncryption}
        loading="lazy"
      />,
    );
    expect(global.fetch).not.toHaveBeenCalled();
  });

  it("fetches authenticated media once intersecting", async () => {
    render(
      <AuthImage
        src="/api/lfs/objects/abc"
        alt="media"
        headers={{ authorization: "x" }}
        encryption={testEncryption}
        loading="lazy"
      />,
    );
    expect(observedCallback).toBeTruthy();
    observedCallback?.(
      [{ isIntersecting: true } as IntersectionObserverEntry],
      {} as IntersectionObserver,
    );
    await waitFor(() => {
      expect(global.fetch).toHaveBeenCalledTimes(1);
    });
    expect(screen.getByRole("img", { name: "media" })).toHaveAttribute("src", "blob:test");
  });

  it("uses preloaded blobs without fetching again", async () => {
    cachePreloadedBlob("/api/lfs/objects/preloaded", new Blob(["cached"]));
    render(
      <AuthImage
        src="/api/lfs/objects/preloaded"
        alt="cached-media"
        headers={{ authorization: "x" }}
        loading="lazy"
      />,
    );
    observedCallback?.(
      [{ isIntersecting: true } as IntersectionObserverEntry],
      {} as IntersectionObserver,
    );
    await waitFor(() => {
      expect(screen.getByRole("img", { name: "cached-media" })).toHaveAttribute("src", "blob:test");
    });
    expect(global.fetch).not.toHaveBeenCalled();
  });

  it("delays ready until image.decode() resolves even when cache reports decoded", async () => {
    const src = "/api/lfs/objects/decoded-on-mount";
    cachePreloadedBlob(src, new Blob(["cached"]));
    markPreloadedObjectUrlDecoded(src);
    const deferred = createDeferredPromise();
    Object.defineProperty(HTMLImageElement.prototype, "decode", {
      configurable: true,
      value: vi.fn(() => deferred.promise),
    });

    render(
      <AuthImage
        src={src}
        alt="decoded-on-mount"
        headers={{ authorization: "x" }}
        loading="eager"
      />,
    );

    expect(screen.getByText("Loading...")).toBeInTheDocument();
    expect(screen.getByRole("img", { name: "decoded-on-mount" })).toHaveStyle({ opacity: "0" });
  });

  it("removes loading placeholder once image.decode() resolves", async () => {
    const src = "/api/lfs/objects/decoded-after-resolve";
    cachePreloadedBlob(src, new Blob(["cached"]));
    markPreloadedObjectUrlDecoded(src);
    const deferred = createDeferredPromise();
    Object.defineProperty(HTMLImageElement.prototype, "decode", {
      configurable: true,
      value: vi.fn(() => deferred.promise),
    });

    render(
      <AuthImage
        src={src}
        alt="decoded-after-resolve"
        headers={{ authorization: "x" }}
        loading="eager"
      />,
    );

    expect(screen.getByText("Loading...")).toBeInTheDocument();
    deferred.resolve();

    await waitFor(() => {
      expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
    });
    expect(screen.getByRole("img", { name: "decoded-after-resolve" })).not.toHaveStyle({ opacity: "0" });
  });

  it("keeps previous image visible while switching to a new src", async () => {
    cachePreloadedBlob("/api/lfs/objects/old-src", new Blob(["old"]));
    cachePreloadedBlob("/api/lfs/objects/new-src", new Blob(["new"]));
    markPreloadedObjectUrlDecoded("/api/lfs/objects/old-src");
    markPreloadedObjectUrlDecoded("/api/lfs/objects/new-src");

    const deferred = createDeferredPromise();
    let decodeCalls = 0;
    Object.defineProperty(HTMLImageElement.prototype, "decode", {
      configurable: true,
      value: vi.fn(() => {
        decodeCalls += 1;
        if (decodeCalls === 1) return Promise.resolve();
        return deferred.promise;
      }),
    });

    const { rerender } = render(
      <AuthImage
        src="/api/lfs/objects/old-src"
        alt="switching-media"
        headers={{ authorization: "x" }}
        loading="eager"
      />,
    );

    await waitFor(() => {
      expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
    });
    expect(screen.getByRole("img", { name: "switching-media" })).toBeInTheDocument();

    rerender(
      <AuthImage
        src="/api/lfs/objects/new-src"
        alt="switching-media"
        headers={{ authorization: "x" }}
        loading="eager"
      />,
    );

    expect(screen.getAllByRole("img", { name: "switching-media" }).length).toBeGreaterThan(0);
    expect(screen.queryByText("Loading...")).not.toBeInTheDocument();

    deferred.resolve();
    await waitFor(() => {
      expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
    });
  });

  it("reuses a stable object URL across cached authenticated remounts", () => {
    cachePreloadedBlob("/api/lfs/objects/remount-cached", new Blob(["cached"]));
    const { unmount } = render(
      <AuthImage
        src="/api/lfs/objects/remount-cached"
        alt="remounted-media"
        headers={{ authorization: "x" }}
        loading="lazy"
      />,
    );
    expect(screen.getByRole("img", { name: "remounted-media" })).toHaveAttribute("src", "blob:test");
    unmount();
    render(
      <AuthImage
        src="/api/lfs/objects/remount-cached"
        alt="remounted-media-again"
        headers={{ authorization: "x" }}
        loading="lazy"
      />,
    );
    expect(screen.getByRole("img", { name: "remounted-media-again" })).toHaveAttribute("src", "blob:test");
    expect(URL.createObjectURL).toHaveBeenCalledTimes(1);
    expect(global.fetch).not.toHaveBeenCalled();
  });

  it("does not revoke shared cached object URLs on unmount", () => {
    cachePreloadedBlob("/api/lfs/objects/revoke-cached", new Blob(["cached"]));
    const { unmount } = render(
      <AuthImage
        src="/api/lfs/objects/revoke-cached"
        alt="revoked-media"
        headers={{ authorization: "x" }}
        loading="lazy"
      />,
    );
    unmount();
    expect(URL.revokeObjectURL).not.toHaveBeenCalledWith("blob:test");
  });

  it("keeps rendered image after slight visibility change", async () => {
    render(
      <AuthImage
        src="/api/lfs/objects/visible"
        alt="steady-media"
        headers={{ authorization: "x" }}
        encryption={testEncryption}
        loading="lazy"
      />,
    );
    observedCallback?.(
      [{ isIntersecting: true } as IntersectionObserverEntry],
      {} as IntersectionObserver,
    );
    await waitFor(() => {
      expect(screen.getByRole("img", { name: "steady-media" })).toHaveAttribute("src", "blob:test");
    });
    observedCallback?.(
      [{ isIntersecting: false } as IntersectionObserverEntry],
      {} as IntersectionObserver,
    );
    expect(screen.getByRole("img", { name: "steady-media" })).toHaveAttribute("src", "blob:test");
    expect(global.fetch).toHaveBeenCalledTimes(1);
  });

  it("promotes cached preload blobs when rendered visibly", async () => {
    const src = "/api/lfs/objects/promoted-by-image";
    cachePreloadedBlob(src, new Blob(["cached"]), "preload");
    render(
      <AuthImage
        src={src}
        alt="promoted-media"
        headers={{ authorization: "x" }}
        loading="lazy"
      />,
    );
    observedCallback?.(
      [{ isIntersecting: true } as IntersectionObserverEntry],
      {} as IntersectionObserver,
    );
    await waitFor(() => {
      expect(screen.getByRole("img", { name: "promoted-media" })).toHaveAttribute("src", "blob:test");
    });

    for (let index = 0; index < 200; index += 1) {
      cachePreloadedBlob(`/api/lfs/objects/preload-churn-${index}`, new Blob([String(index)]), "preload");
    }
    expect(getPreloadedBlob(src, "preload")).toBeTruthy();
    expect(global.fetch).not.toHaveBeenCalled();
  });

  it("keeps mounted cached media in cache during visible-priority churn", async () => {
    const src = "/api/lfs/objects/refcount-mounted-cache";
    cachePreloadedBlob(src, new Blob(["cached"]), "visible");
    const { unmount } = render(
      <AuthImage
        src={src}
        alt="refcount-mounted-media"
        headers={{ authorization: "x" }}
        loading="eager"
      />,
    );

    await waitFor(() => {
      expect(screen.getByRole("img", { name: "refcount-mounted-media" })).toHaveAttribute("src", "blob:test");
    });
    expect(getPreloadedBlob(src, "visible")).toBeTruthy();

    for (let index = 0; index < 220; index += 1) {
      cachePreloadedBlob(`/api/lfs/objects/refcount-mounted-churn-${index}`, new Blob([String(index)]), "visible");
    }
    expect(getPreloadedBlob(src, "visible")).toBeTruthy();

    unmount();
    for (let index = 0; index < 220; index += 1) {
      cachePreloadedBlob(`/api/lfs/objects/refcount-mounted-post-unmount-${index}`, new Blob([String(index)]), "visible");
    }
    expect(getPreloadedBlob(src, "visible")).toBeUndefined();
  });

  it("marks media unavailable when image.decode() rejects", async () => {
    const src = "/api/lfs/objects/decode-reject";
    cachePreloadedBlob(src, new Blob(["cached"]));
    markPreloadedObjectUrlDecoded(src);
    Object.defineProperty(HTMLImageElement.prototype, "decode", {
      configurable: true,
      value: vi.fn(async () => Promise.reject(new Error("decode failed"))),
    });

    render(
      <AuthImage
        src={src}
        alt="decode-reject-media"
        headers={{ authorization: "x" }}
        loading="eager"
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("Media unavailable")).toBeInTheDocument();
    });
  });

  it("recovers after a decode rejection when retry succeeds", async () => {
    const src = "/api/lfs/objects/decode-recovery";
    let attempts = 0;
    Object.defineProperty(HTMLImageElement.prototype, "decode", {
      configurable: true,
      value: vi.fn(async () => {
        attempts += 1;
        if (attempts === 1) throw new Error("decode failed once");
      }),
    });
    cachePreloadedBlob(src, new Blob(["cached"]));
    markPreloadedObjectUrlDecoded(src);

    const { rerender } = render(
      <AuthImage
        src={src}
        alt="decode-recovery-media"
        headers={{ authorization: "x" }}
        loading="eager"
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("Media unavailable")).toBeInTheDocument();
    });

    rerender(
      <AuthImage
        src={src}
        alt="decode-recovery-media"
        headers={{ authorization: "x" }}
        loading="eager"
      />,
    );

    await waitFor(() => {
      expect(screen.getByRole("img", { name: "decode-recovery-media" })).toHaveAttribute("src", "blob:test");
    });
    expect(screen.queryByText("Media unavailable")).not.toBeInTheDocument();
  });
});
