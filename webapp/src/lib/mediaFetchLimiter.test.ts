import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  cachePreloadedBlob,
  getPreloadedBlob,
  getPreloadedObjectUrl,
  releasePreloadedObjectUrl,
  retainPreloadedObjectUrl,
  runWithMediaFetchLimit,
} from "./mediaFetchLimiter";

// Creates deferred controls so queue ordering can be asserted without timer races.
const createDeferred = () => {
  let resolve!: () => void;
  const promise = new Promise<void>((res) => {
    resolve = res;
  });
  return { promise, resolve };
};

// Verifies queue backpressure so parallel media fetch storms stay bounded.
describe("mediaFetchLimiter", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.stubGlobal("URL", {
      createObjectURL: vi.fn((blob: Blob) => `blob:${blob.size}:${crypto.randomUUID()}`),
      revokeObjectURL: vi.fn(),
    });
  });

  it("caps concurrent executions", async () => {
    let running = 0;
    let maxRunning = 0;
    const tasks = Array.from({ length: 20 }, (_, index) =>
      runWithMediaFetchLimit(async () => {
        running += 1;
        maxRunning = Math.max(maxRunning, running);
        await new Promise((resolve) => setTimeout(resolve, 5));
        running -= 1;
        return index;
      }),
    );
    const values = await Promise.all(tasks);
    expect(values).toHaveLength(20);
    expect(maxRunning).toBeLessThanOrEqual(8);
  });

  it("starts visible work before queued preload work", async () => {
    const started: string[] = [];
    const visibleGate = createDeferred();
    const visibleTask = runWithMediaFetchLimit(async () => {
      started.push("visible");
      await visibleGate.promise;
      return "visible";
    }, "visible");
    const preloadTask = runWithMediaFetchLimit(async () => {
      started.push("preload");
      return "preload";
    }, "preload");
    await Promise.resolve();
    expect(started[0]).toBe("visible");
    visibleGate.resolve();
    await Promise.all([preloadTask, visibleTask]);
  });

  it("does not start preload while visible work is queued or running", async () => {
    const started: string[] = [];
    const visibleGates = Array.from({ length: 8 }, () => createDeferred());
    const visibleTasks = visibleGates.map((gate, index) =>
      runWithMediaFetchLimit(async () => {
        started.push(`visible-${index}`);
        await gate.promise;
        return index;
      }, "visible"),
    );
    await Promise.resolve();
    const preloadTask = runWithMediaFetchLimit(async () => {
      started.push("preload");
      return "preload";
    }, "preload");
    const queuedVisibleGate = createDeferred();
    const queuedVisibleTask = runWithMediaFetchLimit(async () => {
      started.push("visible-queued");
      await queuedVisibleGate.promise;
      return "visible-queued";
    }, "visible");
    await Promise.resolve();
    expect(started).toHaveLength(8);
    expect(started.some((entry) => entry === "preload")).toBe(false);

    visibleGates[0]?.resolve();
    await visibleTasks[0];
    await Promise.resolve();
    expect(started.some((entry) => entry === "preload")).toBe(false);

    queuedVisibleGate.resolve();
    await queuedVisibleTask;
    visibleGates.slice(1).forEach((gate) => gate.resolve());
    await Promise.all(visibleTasks);
    await preloadTask;
    expect(started.indexOf("visible-queued")).toBeLessThan(started.indexOf("preload"));
    expect(started.at(-1)).toBe("preload");
  });

  it("evicts preload blobs before visible blobs", () => {
    const visibleSrc = "/api/lfs/cache-visible";
    cachePreloadedBlob(visibleSrc, new Blob(["visible"]), "visible");
    for (let index = 0; index < 200; index += 1) {
      cachePreloadedBlob(`/api/lfs/cache-preload-${index}`, new Blob([String(index)]), "preload");
    }
    expect(getPreloadedBlob(visibleSrc, "preload")).toBeTruthy();
    expect(getPreloadedBlob("/api/lfs/cache-preload-0", "preload")).toBeUndefined();
  });

  it("protects preloaded blobs after visible access promotes them", () => {
    const promotedSrc = "/api/lfs/cache-promoted";
    cachePreloadedBlob(promotedSrc, new Blob(["promoted"]), "preload");
    expect(getPreloadedBlob(promotedSrc)).toBeTruthy();
    for (let index = 0; index < 200; index += 1) {
      cachePreloadedBlob(`/api/lfs/cache-promoted-preload-${index}`, new Blob([String(index)]), "preload");
    }
    expect(getPreloadedBlob(promotedSrc, "preload")).toBeTruthy();
    expect(getPreloadedBlob("/api/lfs/cache-promoted-preload-0", "preload")).toBeUndefined();
  });

  it("reuses one stable object URL for repeated cache lookups", () => {
    const src = "/api/lfs/cache-stable-url";
    cachePreloadedBlob(src, new Blob(["stable"]), "preload");
    const firstUrl = getPreloadedObjectUrl(src);
    const secondUrl = getPreloadedObjectUrl(src);
    expect(firstUrl).toBeTruthy();
    expect(secondUrl).toBe(firstUrl);
    expect(URL.createObjectURL).toHaveBeenCalledTimes(1);
  });

  // Protects currently rendered thumbnails from blob URL invalidation during duplicate cache writes.
  it("keeps existing object URL stable when same src is cached again", () => {
    const src = "/api/lfs/cache-rewrite-same-src";
    cachePreloadedBlob(src, new Blob(["first"]), "visible");
    const firstUrl = getPreloadedObjectUrl(src, "visible");
    expect(firstUrl).toBeTruthy();

    cachePreloadedBlob(src, new Blob(["second"]), "preload");
    const secondUrl = getPreloadedObjectUrl(src, "visible");
    expect(secondUrl).toBe(firstUrl);
    expect(URL.revokeObjectURL).not.toHaveBeenCalledWith(firstUrl);
  });

  it("revokes cached object URLs when their entries are evicted", () => {
    const evictedSrc = "/api/lfs/cache-url-evicted";
    cachePreloadedBlob(evictedSrc, new Blob(["evicted"]), "preload");
    const evictedUrl = getPreloadedObjectUrl(evictedSrc, "preload");
    for (let index = 0; index < 200; index += 1) {
      cachePreloadedBlob(`/api/lfs/cache-url-churn-${index}`, new Blob([String(index)]), "preload");
    }
    expect(getPreloadedBlob(evictedSrc, "preload")).toBeUndefined();
    expect(URL.revokeObjectURL).toHaveBeenCalledWith(evictedUrl);
  });

  it("does not revoke object URL while retained and revokes after release", () => {
    const retainedSrc = "/api/lfs/cache-retained-url";
    cachePreloadedBlob(retainedSrc, new Blob(["retained"]), "preload");
    const retainedUrl = getPreloadedObjectUrl(retainedSrc, "preload");
    expect(retainedUrl).toBeTruthy();

    retainPreloadedObjectUrl(retainedSrc);
    for (let index = 0; index < 220; index += 1) {
      cachePreloadedBlob(`/api/lfs/cache-retained-churn-${index}`, new Blob([String(index)]), "preload");
    }
    expect(getPreloadedBlob(retainedSrc, "preload")).toBeTruthy();
    expect(URL.revokeObjectURL).not.toHaveBeenCalledWith(retainedUrl);

    releasePreloadedObjectUrl(retainedSrc);
    for (let index = 0; index < 220; index += 1) {
      cachePreloadedBlob(`/api/lfs/cache-retained-post-release-${index}`, new Blob([String(index)]), "preload");
    }
    expect(getPreloadedBlob(retainedSrc, "preload")).toBeUndefined();
    expect(URL.revokeObjectURL).toHaveBeenCalledWith(retainedUrl);
  });

  it("evicts only after all retain calls are released", () => {
    const retainedSrc = "/api/lfs/cache-retained-multi-holder";
    cachePreloadedBlob(retainedSrc, new Blob(["retained"]), "preload");
    const retainedUrl = getPreloadedObjectUrl(retainedSrc, "preload");
    expect(retainedUrl).toBeTruthy();

    retainPreloadedObjectUrl(retainedSrc);
    retainPreloadedObjectUrl(retainedSrc);
    for (let index = 0; index < 220; index += 1) {
      cachePreloadedBlob(`/api/lfs/cache-retained-multi-churn-${index}`, new Blob([String(index)]), "preload");
    }
    expect(getPreloadedBlob(retainedSrc, "preload")).toBeTruthy();
    expect(URL.revokeObjectURL).not.toHaveBeenCalledWith(retainedUrl);

    releasePreloadedObjectUrl(retainedSrc);
    cachePreloadedBlob("/api/lfs/cache-retained-multi-one-release", new Blob(["one-release"]), "preload");
    expect(getPreloadedBlob(retainedSrc, "preload")).toBeTruthy();
    expect(URL.revokeObjectURL).not.toHaveBeenCalledWith(retainedUrl);

    releasePreloadedObjectUrl(retainedSrc);
    for (let index = 0; index < 220; index += 1) {
      cachePreloadedBlob(`/api/lfs/cache-retained-multi-two-release-${index}`, new Blob([String(index)]), "preload");
    }
    expect(getPreloadedBlob(retainedSrc, "preload")).toBeUndefined();
    expect(URL.revokeObjectURL).toHaveBeenCalledWith(retainedUrl);
  });
});
