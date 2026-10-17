import { ReactNode, useCallback, useRef, useState } from "react";
import { FullscreenViewer } from "../../components/FullscreenViewer";
import { Timeline, TimelineHandle } from "../../components/Timeline";
import type { MapPointRow } from "../gitdb";
import type { TimelineItem } from "../../lib/timeline";
import type { GeoBounds } from "./mapClusters";
import { usePlaceTimeline } from "./usePlaceTimeline";

interface PlaceTimelineViewProps {
  bounds: GeoBounds;
  points: MapPointRow[];
  revision: number;
  loadItemsByKeys: (keys: string[]) => Promise<TimelineItem[]>;
  mtlsHeaders: Record<string, string> | null;
  onBack: () => void;
  commitPane: ReactNode;
}

// Shows the timeline for one map tile. The title stays "Places" because
// naming it would send the coordinate to a geocoder, which a distributed
// app cannot do against the public Nominatim service.
export const PlaceTimelineView = ({
  bounds,
  points,
  revision,
  loadItemsByKeys,
  mtlsHeaders,
  onBack,
  commitPane,
}: PlaceTimelineViewProps) => {
  const place = usePlaceTimeline({ points, bounds, revision, loadItemsByKeys });
  const timelineRef = useRef<TimelineHandle | null>(null);
  const [viewerIndex, setViewerIndex] = useState<number | null>(null);

  const handleOpenViewer = useCallback((nextIndex: number) => {
    setViewerIndex(nextIndex);
  }, []);

  const handleViewerChange = useCallback((nextIndex: number) => {
    setViewerIndex(nextIndex);
    const loadedEnd = place.loadedOffset + place.loadedItems.length;
    if (nextIndex < place.loadedOffset) {
      place.loadOlderPage();
    } else if (nextIndex >= loadedEnd) {
      place.loadNewerPage();
    }
  }, [place.loadedItems.length, place.loadedOffset, place.loadNewerPage, place.loadOlderPage]);

  const handleCloseViewer = useCallback(() => {
    const lastViewedIndex = viewerIndex;
    setViewerIndex(null);
    if (lastViewedIndex === null) return;
    timelineRef.current?.scrollToIndex(lastViewedIndex);
  }, [viewerIndex]);

  return (
    <>
      <div className="place-bar">
        <button type="button" className="top-icon-button" onClick={onBack} aria-label="Back">
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M15 5l-7 7 7 7" />
          </svg>
        </button>
        <div>
          <h1>Places</h1>
          <p>{place.itemCount} Items</p>
        </div>
      </div>
      {place.itemCount === 0 ? (
        <div className="timeline-container">
          <div className="placeholder-content">
            <p className="empty-state">No photos here</p>
            <p className="empty-state">None of the photos from this place are available.</p>
          </div>
          {commitPane}
        </div>
      ) : (
        <Timeline
          ref={timelineRef}
          itemCount={place.itemCount}
          loadedOffset={place.loadedOffset}
          loadedItems={place.loadedItems}
          dataSource={place.dataSource}
          monthIndex={place.monthIndex}
          onOpen={handleOpenViewer}
          onLoadOlder={place.loadOlderPage}
          onLoadNewer={place.loadNewerPage}
          onSeekToIndex={place.seekToIndex}
          mtlsHeaders={mtlsHeaders}
          showMonthSidebar
          persistAnchorInHash={false}
          suspendHashSync={viewerIndex !== null}
          rightPane={commitPane}
        />
      )}
      {viewerIndex !== null ? (
        <FullscreenViewer
          itemCount={place.itemCount}
          loadedOffset={place.loadedOffset}
          loadedItems={place.loadedItems}
          index={viewerIndex}
          onClose={handleCloseViewer}
          onChange={handleViewerChange}
          mtlsHeaders={mtlsHeaders}
        />
      ) : null}
    </>
  );
};
