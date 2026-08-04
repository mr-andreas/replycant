import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { type ForwardedRef, forwardRef, useImperativeHandle } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { TimelineItem } from "../../lib/timeline";
import { TimelineView } from "./TimelineView";

const timelinePropsState: { latest: Record<string, unknown> | null } = { latest: null };
const timelineScrollToIndexSpy = vi.fn();

vi.mock("../../components/Timeline", () => ({
  Timeline: forwardRef((props: Record<string, unknown>, ref: ForwardedRef<{ scrollToIndex: (index: number) => void }>) => {
    timelinePropsState.latest = props;
    useImperativeHandle(ref, () => ({ scrollToIndex: timelineScrollToIndexSpy }), []);
    const onOpen = props.onOpen as (index: number) => void;
    return (
      <button type="button" onClick={() => onOpen(1)}>
        Open viewer
      </button>
    );
  }),
}));

vi.mock("../../components/FullscreenViewer", () => ({
  FullscreenViewer: ({
    index,
    loadedOffset,
    loadedItems,
    onClose,
    onChange,
  }: {
    index: number;
    loadedOffset: number;
    loadedItems: TimelineItem[];
    onClose: () => void;
    onChange: (nextIndex: number) => void;
  }) => {
    const item = loadedItems[index - loadedOffset];
    return (
      <div>
        <div data-testid="viewer-index">{String(index)}</div>
        <div data-testid="viewer-item-key">{item?.key ?? "missing"}</div>
        <button type="button" onClick={() => onChange(index + 1)}>
          Next
        </button>
        <button type="button" onClick={onClose}>
          Close
        </button>
      </div>
    );
  },
}));

const buildItems = (): TimelineItem[] => [
  {
    key: "item-0",
    dayKey: "2026-01-01",
    monthKey: "2026-01",
    yearKey: "2026",
    timestamp: "2026-01-01T12:00:00Z",
    mediaType: "photo",
    sha256: "hash-0",
    filesize: 1000,
    width: 100,
    height: 100,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "image/jpeg",
    thumbnailUrl: "/thumb-0.jpg",
    intermediateViewerUrl: null,
    viewerUrl: "/full-0.jpg",
    downloadUrl: "/api/lfs/objects/hash-0",
    originalFileName: "item-0.jpg",
  },
  {
    key: "item-1",
    dayKey: "2026-01-02",
    monthKey: "2026-01",
    yearKey: "2026",
    timestamp: "2026-01-02T12:00:00Z",
    mediaType: "photo",
    sha256: "hash-1",
    filesize: 1000,
    width: 100,
    height: 100,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "image/jpeg",
    thumbnailUrl: "/thumb-1.jpg",
    intermediateViewerUrl: null,
    viewerUrl: "/full-1.jpg",
    downloadUrl: "/api/lfs/objects/hash-1",
    originalFileName: "item-1.jpg",
  },
  {
    key: "item-2",
    dayKey: "2026-01-03",
    monthKey: "2026-01",
    yearKey: "2026",
    timestamp: "2026-01-03T12:00:00Z",
    mediaType: "photo",
    sha256: "hash-2",
    filesize: 1000,
    width: 100,
    height: 100,
    isHeic: false,
    heicOriginalUrl: null,
    mimeType: "image/jpeg",
    thumbnailUrl: "/thumb-2.jpg",
    intermediateViewerUrl: null,
    viewerUrl: "/full-2.jpg",
    downloadUrl: "/api/lfs/objects/hash-2",
    originalFileName: "item-2.jpg",
  },
];

const makeRuntime = (
  loadedItems: TimelineItem[],
  overrides?: Partial<{
    timelineItemCount: number;
    loadedOffset: number;
    loadOlderPage: () => void;
    loadNewerPage: () => void;
    seekToIndex: (index: number) => void;
  }>,
) => ({
  snapshot: { syncing: false },
  timelineItemCount: overrides?.timelineItemCount ?? 3,
  timelineMonthIndex: [],
  timelineWindow: {
    loadedOffset: overrides?.loadedOffset ?? 0,
    loadedItems,
  },
  timelineDataSource: null,
  rewindCommits: [],
  rewindActionBusy: null,
  initializeEngine: vi.fn(),
  handleSyncNow: vi.fn(),
  handleResetToRemote: vi.fn(),
  handleJumpToCommit: vi.fn(),
  wipeReplycantState: vi.fn(),
  loadOlderPage: overrides?.loadOlderPage ?? vi.fn(),
  loadNewerPage: overrides?.loadNewerPage ?? vi.fn(),
  seekToIndex: overrides?.seekToIndex ?? vi.fn(),
});

describe("TimelineView hash-backed viewer state", () => {
  beforeEach(() => {
    timelinePropsState.latest = null;
    timelineScrollToIndexSpy.mockReset();
    window.history.replaceState(null, "", "#");
  });

  it("restores viewer from the hash once the target item is loaded", async () => {
    const allItems = buildItems();
    window.history.replaceState(null, "", "#k=item-0&o=4&t=2026-01-01T12:00:00Z&v=item-1");
    const { rerender } = render(
      <TimelineView
        runtime={makeRuntime([]) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    expect(screen.queryByTestId("viewer-index")).toBeNull();

    rerender(
      <TimelineView
        runtime={makeRuntime(allItems) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    await waitFor(() => {
      expect(screen.getByTestId("viewer-index")).toHaveTextContent("1");
    });
  });

  it("writes and clears the viewer key in hash as viewer state changes", async () => {
    const allItems = buildItems();
    render(
      <TimelineView
        runtime={makeRuntime(allItems) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Open viewer" }));
    await waitFor(() => {
      expect(window.location.hash).toContain("v=item-1");
      expect(window.location.hash).toContain("k=item-1");
      expect(window.location.hash).toContain("t=2026-01-02T12%3A00%3A00Z");
    });

    fireEvent.click(screen.getByRole("button", { name: "Next" }));
    await waitFor(() => {
      expect(window.location.hash).toContain("v=item-2");
      expect(window.location.hash).toContain("k=item-2");
      expect(window.location.hash).toContain("t=2026-01-03T12%3A00%3A00Z");
    });

    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    await waitFor(() => {
      expect(window.location.hash).not.toContain("v=");
      expect(window.location.hash).toContain("k=item-2");
      expect(window.location.hash).toContain("t=2026-01-03T12%3A00%3A00Z");
    });
  });

  it("loads newer page when viewer navigation reaches end of current loaded window", async () => {
    const allItems = buildItems();
    const loadNewerPage = vi.fn();
    render(
      <TimelineView
        runtime={makeRuntime(allItems.slice(0, 2), {
          timelineItemCount: 4,
          loadNewerPage,
        }) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Open viewer" }));
    fireEvent.click(screen.getByRole("button", { name: "Next" }));

    await waitFor(() => {
      expect(loadNewerPage).toHaveBeenCalledTimes(1);
    });
  });

  it("keeps the same viewed item when sync inserts newer items ahead of it", async () => {
    const allItems = buildItems();
    const { rerender } = render(
      <TimelineView
        runtime={makeRuntime(allItems) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Open viewer" }));
    await waitFor(() => {
      expect(screen.getByTestId("viewer-index")).toHaveTextContent("1");
    });

    const shiftedItems: TimelineItem[] = [
      {
        key: "new-item",
        dayKey: "2026-01-04",
        monthKey: "2026-01",
        yearKey: "2026",
        timestamp: "2026-01-04T12:00:00Z",
        mediaType: "photo",
        sha256: "hash-new",
        filesize: 1000,
        width: 100,
        height: 100,
        isHeic: false,
        heicOriginalUrl: null,
        mimeType: "image/jpeg",
        thumbnailUrl: "/thumb-new.jpg",
        intermediateViewerUrl: null,
        viewerUrl: "/full-new.jpg",
        downloadUrl: "/api/lfs/objects/hash-new",
        originalFileName: "new-item.jpg",
      },
      ...allItems,
    ];

    rerender(
      <TimelineView
        runtime={makeRuntime(shiftedItems, { timelineItemCount: 4 }) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    await waitFor(() => {
      expect(screen.getByTestId("viewer-index")).toHaveTextContent("2");
      expect(window.location.hash).toContain("v=item-1");
    });
  });

  it("does not pass a stale viewer index during offset-only sync updates", async () => {
    const allItems = buildItems();
    const { rerender } = render(
      <TimelineView
        runtime={makeRuntime(allItems) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Open viewer" }));
    await waitFor(() => {
      expect(screen.getByTestId("viewer-index")).toHaveTextContent("1");
      expect(screen.getByTestId("viewer-item-key")).toHaveTextContent("item-1");
    });

    // Simulates the offset-only incremental sync path: same loadedItems identity,
    // but loadedOffset shifts by one while viewer should stay pinned by item key.
    rerender(
      <TimelineView
        runtime={makeRuntime(allItems, { loadedOffset: 1 }) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    // The first render after rerender must already map to the same item key.
    expect(screen.getByTestId("viewer-index")).toHaveTextContent("2");
    expect(screen.getByTestId("viewer-item-key")).toHaveTextContent("item-1");
  });

  it("scrolls timeline to the last viewed index when closing viewer", async () => {
    const allItems = buildItems();
    render(
      <TimelineView
        runtime={makeRuntime(allItems) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Open viewer" }));
    fireEvent.click(screen.getByRole("button", { name: "Next" }));
    fireEvent.click(screen.getByRole("button", { name: "Close" }));

    await waitFor(() => {
      expect(timelineScrollToIndexSpy).toHaveBeenCalledWith(2);
    });
  });

  it("seeks to viewer index when it drifts more than one item outside loaded window", async () => {
    const allItems = buildItems();
    const seekToIndex = vi.fn();
    render(
      <TimelineView
        runtime={makeRuntime(allItems.slice(0, 2), {
          timelineItemCount: 10,
          seekToIndex,
        }) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Open viewer" }));
    fireEvent.click(screen.getByRole("button", { name: "Next" }));
    fireEvent.click(screen.getByRole("button", { name: "Next" }));

    await waitFor(() => {
      expect(seekToIndex).toHaveBeenCalledWith(3);
    });
  });

  it("restores month sidebar visibility and scroll position from hash", () => {
    const allItems = buildItems();
    window.history.replaceState(null, "", "#m=1&ms=72");

    render(
      <TimelineView
        runtime={makeRuntime(allItems) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    expect(timelinePropsState.latest?.showMonthSidebar).toBe(true);
    expect(timelinePropsState.latest?.monthSidebarInitialScrollTop).toBe(72);
  });

  it("writes month sidebar visibility and scroll position into hash", async () => {
    const allItems = buildItems();
    render(
      <TimelineView
        runtime={makeRuntime(allItems) as never}
        mtlsHeaders={null}
        activeView="timeline"
        onSelectView={vi.fn()}
        commitPaneOpen={false}
        onToggleCommitPane={vi.fn()}
        commitPane={null}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Show months" }));
    await waitFor(() => {
      expect(window.location.hash).toContain("m=1");
    });

    const onMonthSidebarScroll = timelinePropsState.latest?.onMonthSidebarScroll as ((value: number) => void) | undefined;
    expect(onMonthSidebarScroll).toBeTypeOf("function");
    onMonthSidebarScroll?.(44);
    await waitFor(() => {
      expect(window.location.hash).toContain("ms=44");
    });

    onMonthSidebarScroll?.(0);
    await waitFor(() => {
      expect(window.location.hash).not.toContain("ms=");
    });

    fireEvent.click(screen.getByRole("button", { name: "Hide months" }));
    await waitFor(() => {
      expect(window.location.hash).not.toContain("m=");
      expect(window.location.hash).not.toContain("ms=");
    });
  });
});
