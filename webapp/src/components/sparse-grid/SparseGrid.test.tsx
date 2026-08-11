import { fireEvent, render, waitFor } from "@testing-library/react";
import { createRef } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SparseGridDataSource, SparseGridHandle } from "../../lib/sparseGrid";
import { SparseGrid } from "./SparseGrid";

interface MockItem {
  key: string;
  label: string;
}

type ResizeTarget = Element | null;

class MockResizeObserver {
  static observers: Array<{ callback: ResizeObserverCallback; target: ResizeTarget }> = [];
  private readonly callback: ResizeObserverCallback;

  // Stores callback references so tests can emit deterministic size changes.
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

// Pushes synthetic width changes so column math can be tested in jsdom.
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

// Builds predictable fixtures so index assertions stay readable.
const buildItems = (count = 120): MockItem[] => Array.from({ length: count }, (_, i) => ({
  key: `item-${i}`,
  label: `Item ${i}`,
}));

// Creates a default datasource so each test can override only relevant behavior.
const buildDataSource = (overrides: Partial<SparseGridDataSource<MockItem>> = {}): SparseGridDataSource<MockItem> => ({
  itemCount: 120,
  window: {
    loadedOffset: 0,
    loadedItems: buildItems(120),
  },
  onLoadOlder: vi.fn(),
  onLoadNewer: vi.fn(),
  onSeekToIndex: vi.fn(),
  ...overrides,
});

describe("SparseGrid", () => {
  const originalRequestAnimationFrame = globalThis.requestAnimationFrame;
  const originalResizeObserver = globalThis.ResizeObserver;

  beforeEach(() => {
    MockResizeObserver.observers = [];
    vi.stubGlobal("ResizeObserver", MockResizeObserver);
    vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
      callback(0);
      return 1;
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    if (originalResizeObserver) {
      vi.stubGlobal("ResizeObserver", originalResizeObserver);
    }
    vi.stubGlobal("requestAnimationFrame", originalRequestAnimationFrame);
  });

  // Locks the 6.75cm physical target so thumbnail size stays ~50% larger than the old 4.5cm grid.
  it("sizes square tiles for a 6.75cm physical target", async () => {
    const { container } = render(
      <SparseGrid
        dataSource={buildDataSource()}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
      />,
    );
    emitResize(1100);
    await waitFor(() => {
      const firstRow = container.querySelector(".image-row") as HTMLElement | null;
      expect(firstRow).toBeTruthy();
      expect(firstRow!.style.gridTemplateColumns).toBe("repeat(4, minmax(0, 1fr))");
      expect(firstRow!.style.height).toBe("273.5px");
    });
  });

  it("renders placeholders for sparse unloaded indices", async () => {
    const dataSource = buildDataSource({
      itemCount: 5000,
      window: {
        loadedOffset: 1000,
        loadedItems: buildItems(100),
      },
    });
    const { container } = render(
      <SparseGrid
        dataSource={dataSource}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    expect(timeline).toBeTruthy();
    timeline.scrollTop = 0;
    fireEvent.scroll(timeline);
    await waitFor(() => {
      expect(container.querySelectorAll(".image-tile.skeleton").length).toBeGreaterThan(0);
    });
  });

  it("seeks when viewport is far outside loaded window", async () => {
    const onSeekToIndex = vi.fn();
    const onLoadOlder = vi.fn();
    const onLoadNewer = vi.fn();
    const dataSource = buildDataSource({
      itemCount: 5000,
      window: {
        loadedOffset: 1000,
        loadedItems: buildItems(100),
      },
      onSeekToIndex,
      onLoadOlder,
      onLoadNewer,
    });
    const { container } = render(
      <SparseGrid
        dataSource={dataSource}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    onSeekToIndex.mockClear();
    timeline.scrollTop = 0;
    fireEvent.scroll(timeline);
    await waitFor(() => expect(onSeekToIndex).toHaveBeenCalled());
    expect(onLoadOlder).not.toHaveBeenCalled();
    expect(onLoadNewer).not.toHaveBeenCalled();
  });

  it("continues requesting seeks while window is empty during long drag", async () => {
    const onSeekToIndex = vi.fn();
    const dataSource = buildDataSource({
      itemCount: 5000,
      window: {
        loadedOffset: 0,
        loadedItems: [],
      },
      onSeekToIndex,
    });
    const { container } = render(
      <SparseGrid
        dataSource={dataSource}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    await waitFor(() => expect(onSeekToIndex.mock.calls.length).toBeGreaterThan(0));
    const baselineCalls = onSeekToIndex.mock.calls.length;
    timeline.scrollTop = 0;
    fireEvent.scroll(timeline);
    await waitFor(() => expect(onSeekToIndex.mock.calls.length).toBeGreaterThan(baselineCalls));
    timeline.scrollTop = 70000;
    fireEvent.scroll(timeline);
    await waitFor(() => expect(onSeekToIndex.mock.calls.length).toBeGreaterThan(baselineCalls + 1));
  });

  it("requests edge loading after seek results arrive at stale drag position", async () => {
    const onSeekToIndex = vi.fn();
    const onLoadOlder = vi.fn();
    const onLoadNewer = vi.fn();
    const { container, rerender } = render(
      <SparseGrid
        dataSource={buildDataSource({
          itemCount: 5000,
          window: { loadedOffset: 0, loadedItems: [] },
          onSeekToIndex,
          onLoadOlder,
          onLoadNewer,
        })}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    Object.defineProperty(timeline, "clientHeight", { configurable: true, value: 600 });
    const firstRow = container.querySelector(".image-row") as HTMLElement;
    const rowHeight = Number.parseFloat(firstRow.style.height || "0") + 2;
    const colMatch = /repeat\((\d+),/.exec(firstRow.style.gridTemplateColumns);
    const columnCount = colMatch ? Number.parseInt(colMatch[1], 10) : 1;
    const scrollTopForIndex = (index: number) => Math.floor(index / Math.max(1, columnCount)) * rowHeight;

    onSeekToIndex.mockClear();
    onLoadOlder.mockClear();
    onLoadNewer.mockClear();

    const firstSeekIndex = 300;
    const finalIndex = firstSeekIndex + 200;
    timeline.scrollTop = scrollTopForIndex(firstSeekIndex);
    fireEvent.scroll(timeline);
    await waitFor(() => expect(onSeekToIndex.mock.calls.length).toBeGreaterThan(0));
    timeline.scrollTop = scrollTopForIndex(finalIndex);
    fireEvent.scroll(timeline);

    rerender(
      <SparseGrid
        dataSource={buildDataSource({
          itemCount: 5000,
          window: {
            loadedOffset: firstSeekIndex,
            loadedItems: buildItems(100),
          },
          onSeekToIndex,
          onLoadOlder,
          onLoadNewer,
        })}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
      />,
    );
    await waitFor(() => {
      expect(onLoadOlder.mock.calls.length + onLoadNewer.mock.calls.length).toBeGreaterThan(0);
    });
  });

  it("calls onItemClick with global index", async () => {
    const onItemClick = vi.fn();
    const dataSource = buildDataSource({
      window: {
        loadedOffset: 10,
        loadedItems: buildItems(20),
      },
    });
    const { container, getByText } = render(
      <SparseGrid
        dataSource={dataSource}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
        onItemClick={onItemClick}
        initialAnchor={{ itemKey: "item-0", offsetPx: 0 }}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    timeline.scrollTop = 0;
    fireEvent.scroll(timeline);
    fireEvent.click(getByText("Item 0"));
    expect(onItemClick).toHaveBeenCalledWith(expect.objectContaining({ key: "item-0" }), 10);
  });

  it("scrollToIndex skips seek when target is already loaded", async () => {
    const onSeekToIndex = vi.fn();
    const gridRef = createRef<SparseGridHandle>();
    const dataSource = buildDataSource({
      itemCount: 500,
      window: {
        loadedOffset: 100,
        loadedItems: buildItems(120),
      },
      onSeekToIndex,
    });
    render(
      <SparseGrid
        ref={gridRef}
        dataSource={dataSource}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
      />,
    );
    emitResize(620);
    onSeekToIndex.mockClear();

    gridRef.current?.scrollToIndex(150);

    await waitFor(() => {
      expect(onSeekToIndex).not.toHaveBeenCalled();
    });
  });

  it("emits viewport anchor with stable item key", async () => {
    const onViewportAnchorChange = vi.fn();
    const dataSource = buildDataSource();
    const { container } = render(
      <SparseGrid
        dataSource={dataSource}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
        onViewportAnchorChange={onViewportAnchorChange}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    timeline.scrollTop = 320;
    fireEvent.scroll(timeline);
    await waitFor(() => {
      expect(onViewportAnchorChange).toHaveBeenCalledWith(expect.objectContaining({
        itemKey: expect.stringContaining("item-"),
      }));
    });
  });

  it("keeps approximately the same anchor after width change", async () => {
    const dataSource = buildDataSource({
      itemCount: 300,
      window: { loadedOffset: 0, loadedItems: buildItems(300) },
    });
    const onViewportAnchorChange = vi.fn();
    const { container } = render(
      <SparseGrid
        dataSource={dataSource}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
        onViewportAnchorChange={onViewportAnchorChange}
      />,
    );
    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    timeline.scrollTop = 320;
    fireEvent.scroll(timeline);
    await waitFor(() => expect(onViewportAnchorChange).toHaveBeenCalled());
    const first = onViewportAnchorChange.mock.lastCall?.[0] as { itemKey: string } | undefined;
    expect(first?.itemKey).toBeTruthy();

    emitResize(360);
    fireEvent.scroll(timeline);
    await waitFor(() => {
      const next = onViewportAnchorChange.mock.lastCall?.[0] as { itemKey: string } | undefined;
      expect(next?.itemKey).toBeTruthy();
      const beforeIndex = Number((first?.itemKey ?? "item-0").split("-")[1]);
      const afterIndex = Number((next?.itemKey ?? "item-0").split("-")[1]);
      expect(Math.abs(beforeIndex - afterIndex)).toBeLessThanOrEqual(3);
    });
  });

  // After a commit switch the previous anchor key is often absent from the new
  // window while the browser advances scrollTop without firing scroll; the grid
  // must still paint rows for the real scroll position and re-check edges.
  it("reconciles viewport from DOM scrollTop when anchor cannot be restored", async () => {
    const onLoadNewer = vi.fn();
    const onSeekToIndex = vi.fn();
    const readGeometry = (root: HTMLElement) => {
      const row = root.querySelector(".image-row") as HTMLElement | null;
      expect(row).toBeTruthy();
      const rowHeight = Number.parseFloat(row!.style.height || "0") + 2;
      const colMatch = /repeat\((\d+),/.exec(row!.style.gridTemplateColumns);
      const columnCount = colMatch ? Number.parseInt(colMatch[1], 10) : 1;
      return {
        rowHeight,
        columnCount,
        scrollTopForIndex: (index: number) => Math.floor(index / Math.max(1, columnCount)) * rowHeight,
      };
    };
    const rowTops = (root: HTMLElement): number[] =>
      Array.from(root.querySelectorAll(".image-row"))
        .map((row) => {
          const match = /translateY\(([-\d.]+)px\)/.exec((row as HTMLElement).style.transform);
          return match ? Number.parseFloat(match[1]) : NaN;
        })
        .filter((value) => Number.isFinite(value));

    const oldItems = Array.from({ length: 100 }, (_, i) => ({
      key: `old-${i}`,
      label: `Old ${i}`,
    }));
    const { container, rerender } = render(
      <SparseGrid
        dataSource={buildDataSource({
          itemCount: 200,
          window: { loadedOffset: 100, loadedItems: oldItems },
          onLoadNewer,
          onSeekToIndex,
        })}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
      />,
    );

    emitResize(620);
    const timeline = container.querySelector("main.timeline") as HTMLElement;
    Object.defineProperty(timeline, "clientHeight", { configurable: true, value: 600 });
    const initialGeometry = readGeometry(container);
    // Scroll near the end of the old window so the pending anchor captures an old-* key.
    timeline.scrollTop = initialGeometry.scrollTopForIndex(180);
    fireEvent.scroll(timeline);
    await waitFor(() => {
      expect(container.textContent).toMatch(/Old \d+/);
    });

    const newItems = Array.from({ length: 100 }, (_, i) => ({
      key: `new-${i}`,
      label: `New ${i}`,
    }));
    const renderNewWindow = (items: MockItem[]) => (
      <SparseGrid
        dataSource={buildDataSource({
          // Leave room past the loaded window so reconcileViewport re-checks edges.
          itemCount: 600,
          window: { loadedOffset: 400, loadedItems: items },
          onLoadNewer,
          onSeekToIndex,
        })}
        getItemKey={(item) => item.key}
        renderItem={({ item }) => <span>{item.label}</span>}
      />
    );
    // Grow the spacer first so jsdom will accept the anchored scrollTop, then
    // advance scrollTop without a scroll event and re-render so layout reconcile runs.
    rerender(renderNewWindow(newItems));
    const geometry = readGeometry(container);
    const newScrollTop = geometry.scrollTopForIndex(480);
    onLoadNewer.mockClear();
    onSeekToIndex.mockClear();
    timeline.scrollTop = newScrollTop;
    expect(timeline.scrollTop).toBe(newScrollTop);
    rerender(renderNewWindow([...newItems]));

    await waitFor(() => {
      expect(container.textContent).toMatch(/New \d+/);
      expect(container.querySelectorAll(".image-tile.skeleton")).toHaveLength(0);
      const tops = rowTops(container);
      expect(tops.length).toBeGreaterThan(0);
      expect(Math.min(...tops)).toBeLessThanOrEqual(newScrollTop);
      expect(Math.max(...tops) + geometry.rowHeight).toBeGreaterThanOrEqual(newScrollTop);
      expect(onLoadNewer).toHaveBeenCalled();
    });
  });
});
