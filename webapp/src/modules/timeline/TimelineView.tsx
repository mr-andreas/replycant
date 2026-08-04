import { ReactNode, useCallback, useEffect, useRef, useState } from "react";
import { FullscreenViewer } from "../../components/FullscreenViewer";
import { LibraryHeader } from "../../components/LibraryHeader";
import { Timeline, TimelineHandle } from "../../components/Timeline";
import { readHashParams, writeHashParam } from "../../lib/hashState";
import { LibraryRuntimeState } from "../library/useLibraryRuntime";

// Describes top-level library views so timeline can render navigation that scales to future modules.
export type LibraryView = "timeline" | "albums" | "favorites";

interface TimelineViewProps {
  runtime: LibraryRuntimeState;
  mtlsHeaders: Record<string, string> | null;
  activeView: LibraryView;
  onSelectView: (view: LibraryView) => void;
  commitPaneOpen: boolean;
  onToggleCommitPane: () => void;
  commitPane: ReactNode;
}

interface TimelineViewerHashState {
  viewerKey: string | null;
}

interface TimelineMonthSidebarHashState {
  visible: boolean;
  scrollTop: number;
}

// Reads viewer deep-link state so reload/navigation can restore an open media item.
const parseViewerHashState = (): TimelineViewerHashState => {
  const params = readHashParams();
  return { viewerKey: params.get("v") };
};

// Restores month sidebar visibility/scroll so refresh keeps timeline navigation context.
const parseMonthSidebarHashState = (): TimelineMonthSidebarHashState => {
  const params = readHashParams();
  const visible = params.get("m") === "1";
  const parsedScrollTop = Number(params.get("ms"));
  const scrollTop = Number.isFinite(parsedScrollTop) ? Math.max(0, Math.floor(parsedScrollTop)) : 0;
  return { visible, scrollTop };
};

// Persists timeline+viewer hash state so refresh lands on the same media context.
const writeViewerHashState = (item: LibraryRuntimeState["timelineWindow"]["loadedItems"][number]): void => {
  const params = readHashParams();
  params.set("k", item.key);
  params.set("o", "0");
  params.set("t", item.timestamp);
  params.set("v", item.key);
  history.replaceState(null, "", `#${params.toString()}`);
};

// Removes viewer-only state from hash while preserving timeline position anchors.
const clearViewerHashState = (): void => {
  const params = readHashParams();
  params.delete("v");
  history.replaceState(null, "", params.size > 0 ? `#${params.toString()}` : "#");
};

// Renders the timeline-centered library shell while keeping viewer state local to the timeline feature.
export const TimelineView = ({
  runtime,
  mtlsHeaders,
  activeView,
  onSelectView,
  commitPaneOpen,
  onToggleCommitPane,
  commitPane,
}: TimelineViewProps) => {
  const monthSidebarHashState = parseMonthSidebarHashState();
  const timelineRef = useRef<TimelineHandle | null>(null);
  const [viewerIndex, setViewerIndex] = useState<number | null>(null);
  const [viewerKey, setViewerKey] = useState<string | null>(null);
  const [, setSelectedIndex] = useState<number | null>(null);
  const [showMonthSidebar, setShowMonthSidebar] = useState(monthSidebarHashState.visible);
  const resolvedViewerIndex = (() => {
    if (viewerIndex === null || !viewerKey) return viewerIndex;
    const localIndex = runtime.timelineWindow.loadedItems.findIndex((item) => item.key === viewerKey);
    if (localIndex < 0) return viewerIndex;
    return runtime.timelineWindow.loadedOffset + localIndex;
  })();

  // Restores fullscreen media when URL hash includes a viewer item key.
  useEffect(() => {
    if (viewerIndex !== null) return;
    const { viewerKey } = parseViewerHashState();
    if (!viewerKey) return;
    const localIndex = runtime.timelineWindow.loadedItems.findIndex((item) => item.key === viewerKey);
    if (localIndex < 0) return;
    const globalIndex = runtime.timelineWindow.loadedOffset + localIndex;
    setSelectedIndex(globalIndex);
    setViewerKey(viewerKey);
    setViewerIndex(globalIndex);
  }, [runtime.timelineWindow.loadedItems, runtime.timelineWindow.loadedOffset, viewerIndex]);

  // Opens fullscreen media and persists its key so refresh restores the same item.
  const handleOpenViewer = useCallback((nextIndex: number) => {
    setSelectedIndex(nextIndex);
    setViewerIndex(nextIndex);
    const item = runtime.timelineWindow.loadedItems[nextIndex - runtime.timelineWindow.loadedOffset];
    setViewerKey(item?.key ?? null);
    if (!item) return;
    writeViewerHashState(item);
  }, [runtime.timelineWindow.loadedItems, runtime.timelineWindow.loadedOffset]);

  // Keeps hash in sync while stepping media so deep links remain stable.
  const handleViewerChange = useCallback((nextIndex: number) => {
    const item = runtime.timelineWindow.loadedItems[nextIndex - runtime.timelineWindow.loadedOffset];
    setViewerKey(item?.key ?? null);
    setSelectedIndex(nextIndex);
    setViewerIndex(nextIndex);
    const loadedEnd = runtime.timelineWindow.loadedOffset + runtime.timelineWindow.loadedItems.length;
    if (nextIndex < runtime.timelineWindow.loadedOffset) {
      runtime.loadOlderPage();
    } else if (nextIndex >= loadedEnd) {
      runtime.loadNewerPage();
    }
    if (!item) return;
    writeViewerHashState(item);
  }, [
    runtime.loadNewerPage,
    runtime.loadOlderPage,
    runtime.timelineWindow.loadedItems,
    runtime.timelineWindow.loadedOffset,
  ]);

  // Clears viewer deep-link state on close while retaining timeline anchor parameters.
  const handleCloseViewer = useCallback(() => {
    const lastViewedIndex = viewerIndex;
    setViewerKey(null);
    setViewerIndex(null);
    clearViewerHashState();
    if (lastViewedIndex === null) return;
    timelineRef.current?.scrollToIndex(lastViewedIndex);
  }, [viewerIndex]);

  // Keeps the fullscreen selection pinned to a stable item key when sync inserts or removes nearby rows.
  useEffect(() => {
    if (viewerIndex === null || !viewerKey) return;
    const localIndex = runtime.timelineWindow.loadedItems.findIndex((item) => item.key === viewerKey);
    if (localIndex < 0) return;
    const globalIndex = runtime.timelineWindow.loadedOffset + localIndex;
    if (globalIndex === viewerIndex) return;
    setSelectedIndex(globalIndex);
    setViewerIndex(globalIndex);
  }, [
    viewerIndex,
    viewerKey,
    runtime.timelineWindow.loadedItems,
    runtime.timelineWindow.loadedOffset,
  ]);

  // Writes viewer hash once sparse paging catches up to the currently selected index.
  useEffect(() => {
    if (resolvedViewerIndex === null) return;
    const item = runtime.timelineWindow.loadedItems[resolvedViewerIndex - runtime.timelineWindow.loadedOffset];
    if (!item) return;
    if (viewerKey && item.key !== viewerKey) return;
    writeViewerHashState(item);
  }, [resolvedViewerIndex, viewerKey, runtime.timelineWindow.loadedItems, runtime.timelineWindow.loadedOffset]);

  // Recovers viewer rendering when index drifts beyond incremental paging reach.
  // This can happen after hash restore or event bursts where sparse edge loading
  // has not yet expanded to the selected item.
  useEffect(() => {
    if (resolvedViewerIndex === null) return;
    const loadedCount = runtime.timelineWindow.loadedItems.length;
    if (loadedCount === 0) return;
    const { loadedOffset } = runtime.timelineWindow;
    const loadedEnd = loadedOffset + loadedCount;
    const distance = resolvedViewerIndex < loadedOffset
      ? loadedOffset - resolvedViewerIndex
      : resolvedViewerIndex >= loadedEnd
        ? resolvedViewerIndex - loadedEnd + 1
        : 0;
    if (distance <= 1) return;
    runtime.seekToIndex(resolvedViewerIndex);
  }, [
    resolvedViewerIndex,
    runtime.seekToIndex,
    runtime.timelineWindow.loadedItems.length,
    runtime.timelineWindow.loadedOffset,
  ]);

  // Keeps hash month-sidebar visibility in sync with header toggles.
  const handleToggleMonthSidebar = useCallback(() => {
    setShowMonthSidebar((value) => {
      const next = !value;
      writeHashParam("m", next ? "1" : null);
      if (!next) {
        writeHashParam("ms", null);
      }
      return next;
    });
  }, []);

  // Persists month rail scroll position so reload reopens at the same month context.
  const handleMonthSidebarScroll = useCallback((scrollTop: number) => {
    if (!showMonthSidebar) return;
    const value = Math.max(0, Math.floor(scrollTop));
    writeHashParam("ms", value > 0 ? String(value) : null);
  }, [showMonthSidebar]);

  return (
    <div className="app-shell">
      <div className="app-main">
        <LibraryHeader
          activeView={activeView}
          onSelectView={onSelectView}
          commitPaneOpen={commitPaneOpen}
          onToggleCommitPane={onToggleCommitPane}
          showMonthToggle
          showMonthSidebar={showMonthSidebar}
          onToggleMonthSidebar={handleToggleMonthSidebar}
        />

        {runtime.timelineItemCount === 0 && !runtime.snapshot.syncing ? (
          <div className="timeline-container">
            <div className="placeholder-content">
              <p className="empty-state">No media yet. Try syncing once the backend has manifests.</p>
            </div>
            {commitPane}
          </div>
        ) : (
          <Timeline
            ref={timelineRef}
            itemCount={runtime.timelineItemCount}
            loadedOffset={runtime.timelineWindow.loadedOffset}
            loadedItems={runtime.timelineWindow.loadedItems}
            dataSource={runtime.timelineDataSource}
            monthIndex={runtime.timelineMonthIndex}
            onOpen={handleOpenViewer}
            onLoadOlder={runtime.loadOlderPage}
            onLoadNewer={runtime.loadNewerPage}
            onSeekToIndex={runtime.seekToIndex}
            mtlsHeaders={mtlsHeaders}
            showMonthSidebar={showMonthSidebar}
            monthSidebarInitialScrollTop={monthSidebarHashState.scrollTop}
            onMonthSidebarScroll={handleMonthSidebarScroll}
            suspendHashSync={viewerIndex !== null}
            rightPane={commitPane}
          />
        )}
      </div>

      {resolvedViewerIndex !== null ? (
        <FullscreenViewer
          itemCount={runtime.timelineItemCount}
          loadedOffset={runtime.timelineWindow.loadedOffset}
          loadedItems={runtime.timelineWindow.loadedItems}
          index={resolvedViewerIndex}
          onClose={handleCloseViewer}
          onChange={handleViewerChange}
          mtlsHeaders={mtlsHeaders}
        />
      ) : null}
    </div>
  );
};
