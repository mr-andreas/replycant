import * as React from "react";
import { fireEvent, render, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MonthEntry, TimelineItem } from "../lib/timeline";
import { Timeline } from "./Timeline";

const {
  authImageMountCounts,
  authImageLoadings,
  authImageRenderCounts,
  preloadCalls,
} = vi.hoisted(() => ({
  authImageMountCounts: new Map<string, number>(),
  authImageLoadings: [] as Array<"eager" | "lazy" | undefined>,
  authImageRenderCounts: new Map<string, number>(),
  preloadCalls: [] as string[],
}));

vi.mock("./AuthImage", () => ({
  AuthImage: ({ src, alt, loading }: { src: string; alt: string; loading?: "eager" | "lazy" }) => {
    authImageRenderCounts.set(src, (authImageRenderCounts.get(src) ?? 0) + 1);
    authImageLoadings.push(loading);
    // Tracks mount churn so small timeline scrolls can assert image tiles stay mounted.
    React.useEffect(() => {
      authImageMountCounts.set(src, (authImageMountCounts.get(src) ?? 0) + 1);
    }, [src]);
    return <img src={src} alt={alt} />;
  },
}));

vi.mock("../lib/preloadMedia", () => ({
  fetchAndCacheAuthenticatedMedia: vi.fn(async ({ src, signal }: { src: string; signal?: AbortSignal }) => {
    if (signal?.aborted) throw new DOMException("aborted", "AbortError");
    await Promise.resolve();
    if (signal?.aborted) throw new DOMException("aborted", "AbortError");
    preloadCalls.push(src);
    return new Blob(["x"]);
  }),
}));

vi.mock("../lib/mediaFetchLimiter", async () => {
  const actual = await vi.importActual<typeof import("../lib/mediaFetchLimiter")>("../lib/mediaFetchLimiter");
  return {
    ...actual,
    getPreloadedBlob: vi.fn(() => undefined),
  };
});

type ResizeTarget = Element | null;

class MockResizeObserver {
  static observers: Array<{ callback: ResizeObserverCallback; target: ResizeTarget }> = [];
  private readonly callback: ResizeObserverCallback;

  constructor(callback: ResizeObserverCallback) {
    this.callback = callback;
    MockResizeObserver.observers.push({ callback, target: null });
  }

  observe(target: Element) {
    const observer = MockResizeObserver.observers.find((entry) => entry.callback === this.callback);
    if (observer) observer.target = target;
  }

  disconnect() {}
  unobserve() {}
}

const emitResize = (width: number) => {
  for (const observer of MockResizeObserver.observers) {
    if (!observer.target) continue;
    observer.callback(
      [
        {
          target: observer.target,
          contentRect: { width, height: 600 } as DOMRectReadOnly,
        } as ResizeObserverEntry,
      ],
      {} as ResizeObserver,
    );
  }
};

const buildItems = (): TimelineItem[] => {
  const items: TimelineItem[] = [];
  for (let i = 0; i < 24; i++) {
    const day = String(i + 1).padStart(2, "0");
    const monthKey = i < 15 ? "2026-01" : "2026-02";
    const dayKey = i < 15 ? `2026-01-${day}` : `2026-02-${String(i - 14).padStart(2, "0")}`;
    items.push({
      key: `item-${i}`,
      dayKey,
      monthKey,
      yearKey: "2026",
      timestamp: `${dayKey}T12:00:00Z`,
      mediaType: "photo",
      sha256: `item-${i}`,
      filesize: 1000,
      width: 100,
      height: 100,
      isHeic: false,
      heicOriginalUrl: null,
      mimeType: "image/jpeg",
      thumbnailUrl: `/thumb-item-${i}.jpg`,
      intermediateViewerUrl: null,
      viewerUrl: `/full-item-${i}.jpg`,
      downloadUrl: `/api/lfs/objects/item-${i}`,
      originalFileName: `item-${i}.jpg`,
    });
  }
  return items;
};

// Builds larger LFS-backed fixtures so timeline preload windows can be asserted deterministically.
const buildLfsItems = (count: number): TimelineItem[] => Array.from({ length: count }, (_, i) => {
  const day = String((i % 28) + 1).padStart(2, "0");
  const month = String(((Math.floor(i / 28) % 12) + 1)).padStart(2, "0");
  const dayKey = `2026-${month}-${day}`;
  const encryption = {
    encryptedOid: `lfs-item-${i}`,
    wrappedDek: "wrapped",
    kekEpoch: 1,
    dekBase64: "ZGVr",
  };
  return {
    key: `lfs-item-${i}`,
    dayKey,
    monthKey: `2026-${month}`,
    yearKey: "2026",
    timestamp: `${dayKey}T12:00:00Z`,
    mediaType: "photo",
    sha256: `lfs-item-${i}`,
    filesize: 1000,
    width: 100,
    height: 100,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "image/jpeg",
    thumbnailUrl: `/api/lfs/thumb-${i}.jpg`,
    intermediateViewerUrl: null,
    viewerUrl: `/api/lfs/full-${i}.jpg`,
    downloadUrl: `/api/lfs/objects/lfs-item-${i}`,
    originalFileName: `lfs-item-${i}.jpg`,
    encryption,
    thumbnailEncryption: { ...encryption, encryptedOid: `thumb-${i}` },
  };
});

const buildMonthIndex = (): MonthEntry[] => [
  { yearKey: "2026", monthKey: "2026-01", count: 15, firstTakenAt: "2026-01-01T12:00:00Z", globalOffset: 0 },
  { yearKey: "2026", monthKey: "2026-02", count: 9, firstTakenAt: "2026-02-01T12:00:00Z", globalOffset: 15 },
];

// Builds a large index so month jumps can target regions outside the loaded sparse window.
const buildLargeMonthIndex = (): MonthEntry[] => [
  { yearKey: "2026", monthKey: "2026-01", count: 2500, firstTakenAt: "2026-01-01T12:00:00Z", globalOffset: 0 },
  { yearKey: "2026", monthKey: "2026-02", count: 2500, firstTakenAt: "2026-02-01T12:00:00Z", globalOffset: 2500 },
];

// Builds two adjacent month buckets where the second month starts mid-row,
// which reproduces sidebar flicker when month selection follows top-left index.
const buildBoundaryMonthIndex = (): MonthEntry[] => [
  { yearKey: "2026", monthKey: "2026-06", count: 57, firstTakenAt: "2026-06-01T12:00:00Z", globalOffset: 0 },
  { yearKey: "2026", monthKey: "2026-07", count: 9, firstTakenAt: "2026-07-01T12:00:00Z", globalOffset: 57 },
];

// Provides timeline items aligned to buildBoundaryMonthIndex so tests can
// assert month-selection behavior around a month boundary inside one row.
const buildBoundaryItems = (): TimelineItem[] => Array.from({ length: 66 }, (_, i) => {
  const month = i < 57 ? "06" : "07";
  const day = String((i % 28) + 1).padStart(2, "0");
  const dayKey = `2026-${month}-${day}`;
  return {
    key: `boundary-item-${i}`,
    dayKey,
    monthKey: `2026-${month}`,
    yearKey: "2026",
    timestamp: `${dayKey}T12:00:00Z`,
    mediaType: "photo",
    sha256: `boundary-item-${i}`,
    filesize: 1000,
    width: 100,
    height: 100,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "image/jpeg",
    thumbnailUrl: `/thumb-boundary-item-${i}.jpg`,
    intermediateViewerUrl: null,
    viewerUrl: `/full-boundary-item-${i}.jpg`,
    downloadUrl: `/api/lfs/objects/boundary-item-${i}`,
    originalFileName: `boundary-item-${i}.jpg`,
  };
});

describe("Timeline", () => {
  const originalRequestAnimationFrame = globalThis.requestAnimationFrame;
  const originalResizeObserver = globalThis.ResizeObserver;

  beforeEach(() => {
    MockResizeObserver.observers = [];
    authImageMountCounts.clear();
    authImageLoadings.splice(0);
    authImageRenderCounts.clear();
    preloadCalls.splice(0);
    vi.stubGlobal("ResizeObserver", MockResizeObserver);
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
      callback(0);
      return 1;
    });
    window.history.replaceState(null, "", "#");
  });

  afterEach(() => {
    vi.restoreAllMocks();
    if (originalResizeObserver) {
      vi.stubGlobal("ResizeObserver", originalResizeObserver);
    }
    vi.stubGlobal("requestAnimationFrame", originalRequestAnimationFrame);
    window.history.replaceState(null, "", "#");
  });

  it("writes a key-based anchor with timestamp to the URL hash on scroll", async () => {
    const items = buildItems();
    const { container } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar={false}
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    expect(timeline).toBeTruthy();

    timeline.scrollTop = 320;
    fireEvent.scroll(timeline);
    await waitFor(() => {
      expect(window.location.hash).toContain("k=");
      expect(window.location.hash).toContain("t=");
    });
  });

  it("skips scroll hash writes while viewer state owns hash updates", async () => {
    const items = buildItems();
    window.history.replaceState(null, "", "#k=item-4&o=8&t=2026-01-05T12:00:00Z&v=item-7");
    const { container } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar={false}
        suspendHashSync
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    expect(timeline).toBeTruthy();

    const originalHash = window.location.hash;
    timeline.scrollTop = 320;
    fireEvent.scroll(timeline);

    await waitFor(() => {
      expect(window.location.hash).toBe(originalHash);
    });
  });

  it("defers first-mount hash restore until loaded items arrive", async () => {
    const items = buildItems();
    window.history.replaceState(null, "", "#k=item-5&o=12&t=2026-01-06T12:00:00Z");

    const { container, rerender } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={[]}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar={false}
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    expect(timeline).toBeTruthy();
    expect(timeline.scrollTop).toBe(0);

    rerender(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar={false}
      />,
    );

    const firstRow = container.querySelector(".image-row") as HTMLElement;
    expect(firstRow).toBeTruthy();
    const rowHeight = Number.parseFloat(firstRow.style.height || "0") + 2;
    const colMatch = /repeat\((\d+),/.exec(firstRow.style.gridTemplateColumns);
    const colCount = colMatch ? Number.parseInt(colMatch[1], 10) : 1;
    const expectedScroll = Math.floor(5 / colCount) * rowHeight + 12;
    const totalHeight = Math.ceil(items.length / colCount) * rowHeight - 2;

    await waitFor(() => {
      expect(Math.abs(timeline.scrollTop - expectedScroll)).toBeLessThan(1);
    });
    expect(Math.abs(timeline.scrollTop - totalHeight)).toBeGreaterThan(1);
  });

  it("updates month sidebar highlight immediately when month jump target is outside loaded window", async () => {
    const items = buildItems();
    const { getByRole } = render(
      <Timeline
        itemCount={5000}
        loadedOffset={1000}
        loadedItems={items}
        monthIndex={buildLargeMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar
      />,
    );

    emitResize(620);
    const febButton = getByRole("button", { name: /Feb/i });
    fireEvent.click(febButton);

    await waitFor(() => {
      expect(febButton.className).toContain("active");
    });
  });

  it("keeps the clicked month active while that month is still visible in the grid", async () => {
    const items = buildBoundaryItems();
    const { container, getByRole } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildBoundaryMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar
      />,
    );

    emitResize(620);
    const julButton = getByRole("button", { name: /Jul/i });
    fireEvent.click(julButton);

    const timeline = container.querySelector("main.timeline") as HTMLElement;
    timeline.scrollTop = Math.max(0, timeline.scrollTop - 1);
    fireEvent.scroll(timeline);

    await waitFor(() => {
      expect(julButton.className).toContain("active");
    });
  });

  it("releases clicked month pin after scrolling fully away from that month", async () => {
    const items = buildBoundaryItems();
    const { container, getByRole } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildBoundaryMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar
      />,
    );

    emitResize(620);
    const junButton = getByRole("button", { name: /Jun/i });
    const julButton = getByRole("button", { name: /Jul/i });
    fireEvent.click(julButton);
    await waitFor(() => {
      expect(julButton.className).toContain("active");
    });

    const timeline = container.querySelector("main.timeline") as HTMLElement;
    timeline.scrollTop = 0;
    fireEvent.scroll(timeline);

    await waitFor(() => {
      expect(junButton.className).toContain("active");
      expect(julButton.className).not.toContain("active");
    });
  });

  it("uses random seek when viewport is far outside loaded window", async () => {
    const items = buildItems();
    const onSeekToIndex = vi.fn();
    const onLoadOlder = vi.fn();
    const onLoadNewer = vi.fn();
    const { container } = render(
      <Timeline
        itemCount={5000}
        loadedOffset={1000}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={onLoadOlder}
        onLoadNewer={onLoadNewer}
        onSeekToIndex={onSeekToIndex}
        mtlsHeaders={null}
        showMonthSidebar={false}
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    expect(timeline).toBeTruthy();

    onSeekToIndex.mockClear();
    onLoadOlder.mockClear();
    onLoadNewer.mockClear();

    timeline.scrollTop = 0;
    fireEvent.scroll(timeline);

    await waitFor(() => expect(onSeekToIndex).toHaveBeenCalled());
    expect(onLoadOlder).not.toHaveBeenCalled();
    expect(onLoadNewer).not.toHaveBeenCalled();
  });

  it("continues requesting seeks while loaded window is empty during long drag", async () => {
    const onSeekToIndex = vi.fn();
    const onLoadOlder = vi.fn();
    const onLoadNewer = vi.fn();
    const { container } = render(
      <Timeline
        itemCount={5000}
        loadedOffset={0}
        loadedItems={[]}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={onLoadOlder}
        onLoadNewer={onLoadNewer}
        onSeekToIndex={onSeekToIndex}
        mtlsHeaders={null}
        showMonthSidebar={false}
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    expect(timeline).toBeTruthy();

    await waitFor(() => expect(onSeekToIndex.mock.calls.length).toBeGreaterThan(0));
    const baselineCalls = onSeekToIndex.mock.calls.length;
    timeline.scrollTop = 0;
    fireEvent.scroll(timeline);
    await waitFor(() => expect(onSeekToIndex.mock.calls.length).toBeGreaterThan(baselineCalls));

    timeline.scrollTop = 70000;
    fireEvent.scroll(timeline);
    await waitFor(() => expect(onSeekToIndex.mock.calls.length).toBeGreaterThan(baselineCalls + 1));

    const callsAfterBaseline = onSeekToIndex.mock.calls.slice(baselineCalls);
    const [firstIndex] = callsAfterBaseline[0] ?? [0];
    const [secondIndex] = callsAfterBaseline[1] ?? [0];
    expect(typeof firstIndex).toBe("number");
    expect(typeof secondIndex).toBe("number");
    expect(secondIndex).toBeGreaterThan(firstIndex);
    expect(onLoadOlder).not.toHaveBeenCalled();
    expect(onLoadNewer).not.toHaveBeenCalled();
  });

  it("requests edge loading after seek results arrive at a stale drag position", async () => {
    const onSeekToIndex = vi.fn();
    const onLoadOlder = vi.fn();
    const onLoadNewer = vi.fn();
    const baseItems = buildItems();
    const { container, rerender } = render(
      <Timeline
        itemCount={5000}
        loadedOffset={0}
        loadedItems={[]}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={onLoadOlder}
        onLoadNewer={onLoadNewer}
        onSeekToIndex={onSeekToIndex}
        mtlsHeaders={null}
        showMonthSidebar={false}
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    expect(timeline).toBeTruthy();
    Object.defineProperty(timeline, "clientHeight", { configurable: true, value: 600 });
    const firstRow = container.querySelector(".image-row") as HTMLElement;
    expect(firstRow).toBeTruthy();
    const rowHeight = Number.parseFloat(firstRow.style.height || "0") + 2;
    const colMatch = /repeat\((\d+),/.exec(firstRow.style.gridTemplateColumns);
    const columnCount = colMatch ? Number.parseInt(colMatch[1], 10) : 1;
    const scrollTopForIndex = (index: number) => Math.floor(index / Math.max(1, columnCount)) * rowHeight;

    onSeekToIndex.mockClear();
    onLoadOlder.mockClear();
    onLoadNewer.mockClear();

    const firstSeekIndex = 300;
    const finalIndex = firstSeekIndex + 200;
    const baselineSeekCalls = onSeekToIndex.mock.calls.length;
    timeline.scrollTop = scrollTopForIndex(firstSeekIndex);
    fireEvent.scroll(timeline);
    await waitFor(() => expect(onSeekToIndex.mock.calls.length).toBeGreaterThan(baselineSeekCalls));

    timeline.scrollTop = scrollTopForIndex(finalIndex);
    fireEvent.scroll(timeline);

    const loadedItems = Array.from({ length: 100 }, (_, i) => ({
      ...baseItems[i % baseItems.length],
      key: `loaded-${i}`,
      timestamp: `2027-01-${String(i + 1).padStart(2, "0")}T12:00:00Z`,
      dayKey: `2027-01-${String(i + 1).padStart(2, "0")}`,
      monthKey: "2027-01",
      yearKey: "2027",
    }));
    rerender(
      <Timeline
        itemCount={5000}
        loadedOffset={firstSeekIndex}
        loadedItems={loadedItems}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={onLoadOlder}
        onLoadNewer={onLoadNewer}
        onSeekToIndex={onSeekToIndex}
        mtlsHeaders={null}
        showMonthSidebar={false}
      />,
    );

    await waitFor(() => {
      expect(onLoadOlder.mock.calls.length + onLoadNewer.mock.calls.length).toBeGreaterThan(0);
    });
  });

  it("preloads 25 thumbnails before and after the viewport by default", async () => {
    window.history.replaceState(null, "", "#k=lfs-item-150&o=0&t=2026-06-11T12:00:00Z");
    const items = buildLfsItems(300);
    const { container } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={{ authorization: "x" }}
        showMonthSidebar={false}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    preloadCalls.splice(0);
    timeline.scrollTop += 10;
    fireEvent.scroll(timeline);
    await waitFor(() => {
      expect(new Set(preloadCalls).size).toBe(50);
    });
  });

  it("keeps already-mounted tile images stable across slight scroll", async () => {
    const items = buildLfsItems(300);
    const { container } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={{ authorization: "x" }}
        showMonthSidebar={false}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    timeline.scrollTop = 10_000;
    fireEvent.scroll(timeline);
    await waitFor(() => {
      expect(authImageMountCounts.size).toBeGreaterThan(0);
    });
    const initialMountCounts = new Map(authImageMountCounts);

    timeline.scrollTop += 10;
    fireEvent.scroll(timeline);

    await waitFor(() => {
      for (const [src, count] of initialMountCounts.entries()) {
        expect(authImageMountCounts.get(src)).toBe(count);
      }
    });
  });

  it("keeps loaded thumbnails rendered after resize reflows rows", async () => {
    const items = buildLfsItems(120);
    const { container } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={{ authorization: "x" }}
        showMonthSidebar={false}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    timeline.scrollTop = 4_000;
    fireEvent.scroll(timeline);
    await waitFor(() => {
      expect(container.querySelectorAll(".image-tile img").length).toBeGreaterThan(0);
    });

    emitResize(360);
    fireEvent.scroll(timeline);

    await waitFor(() => {
      expect(container.querySelectorAll(".image-tile.skeleton")).toHaveLength(0);
      expect(container.querySelectorAll(".image-tile img").length).toBeGreaterThan(0);
    });
  });

  it("always marks rendered timeline tiles as eager across viewport, overscan, and resize", async () => {
    const items = buildLfsItems(300);
    const { container } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={{ authorization: "x" }}
        showMonthSidebar={false}
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    timeline.scrollTop = 10_000;
    fireEvent.scroll(timeline);

    // Floors track column counts under 6.75cm tiles (2 cols at 620px, 1 at 360px).
    await waitFor(() => {
      expect(authImageLoadings.length).toBeGreaterThan(10);
    });
    expect(new Set(authImageLoadings)).toEqual(new Set(["eager"]));

    authImageLoadings.splice(0);
    emitResize(360);
    fireEvent.scroll(timeline);

    await waitFor(() => {
      expect(authImageLoadings.length).toBeGreaterThan(4);
    });
    expect(new Set(authImageLoadings)).toEqual(new Set(["eager"]));
  });

  it("shows the first and last visible dates and updates them while scrolling", async () => {
    const dateFormatSpy = vi
      .spyOn(Date.prototype, "toLocaleDateString")
      .mockImplementation(function mockTimelineDateFormat(this: Date) {
        return this.toISOString().slice(0, 10);
      });
    void dateFormatSpy;

    const items = buildItems();
    const { container } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar={false}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    expect(timeline).toBeTruthy();

    await waitFor(() => {
      const label = container.querySelector(".timeline-viewport-range");
      // 6.75cm tiles yield 2 columns at 620px, so the bottom row is items 22-23.
      expect(label?.textContent).toBe("2026-02-08 - 2026-02-09");
    });

    timeline.scrollTop = 320;
    fireEvent.scroll(timeline);
    await waitFor(() => {
      const label = container.querySelector(".timeline-viewport-range");
      expect(label?.textContent).toContain("2026-01");
      expect(label?.textContent).not.toBe("2026-02-08 - 2026-02-09");
    });
  });

  it("keeps showing a month label from the index when the visible range has no loaded items", async () => {
    const dateFormatSpy = vi
      .spyOn(Date.prototype, "toLocaleDateString")
      .mockImplementation(function mockTimelineDateFormat(this: Date) {
        return this.toISOString().slice(0, 10);
      });
    void dateFormatSpy;

    const { container } = render(
      <Timeline
        itemCount={5000}
        loadedOffset={0}
        loadedItems={[]}
        monthIndex={buildLargeMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar={false}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    expect(timeline).toBeTruthy();

    // With no loaded items the grid mounts scrolled to the newest (bottom) row,
    // which lands in the second month of the index.
    await waitFor(() => {
      const label = container.querySelector(".timeline-viewport-range");
      expect(label?.textContent).toBe("2026-02-01");
    });

    timeline.scrollTop = 0;
    fireEvent.scroll(timeline);

    await waitFor(() => {
      const label = container.querySelector(".timeline-viewport-range");
      expect(label?.textContent).toBe("2026-01-01");
    });
  });

  it("renders the viewport date range inside the grid pane when month sidebar is visible", async () => {
    const dateFormatSpy = vi
      .spyOn(Date.prototype, "toLocaleDateString")
      .mockImplementation(function mockTimelineDateFormat(this: Date) {
        return this.toISOString().slice(0, 10);
      });
    void dateFormatSpy;

    const items = buildItems();
    const { container } = render(
      <Timeline
        itemCount={items.length}
        loadedOffset={0}
        loadedItems={items}
        monthIndex={buildMonthIndex()}
        onOpen={vi.fn()}
        onLoadOlder={vi.fn()}
        onLoadNewer={vi.fn()}
        onSeekToIndex={vi.fn()}
        mtlsHeaders={null}
        showMonthSidebar
      />,
    );

    emitResize(620);
    await waitFor(() => {
      const label = container.querySelector(".timeline-viewport-range");
      expect(label).toBeTruthy();
      expect(label?.parentElement?.classList.contains("timeline-grid-pane")).toBe(true);
    });
  });
});
