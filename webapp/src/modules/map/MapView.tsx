import { ReactNode, useEffect, useRef, useState, type MutableRefObject } from "react";
import { createPortal } from "react-dom";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { AuthImage } from "../../components/AuthImage";
import { LibraryHeader } from "../../components/LibraryHeader";
import { runtimeConfig } from "../../lib/config";
import type { TimelineItem } from "../../lib/timeline";
import type { LibraryRuntimeState } from "../library/useLibraryRuntime";
import type { LibraryView } from "../timeline/TimelineView";
import type { MapPointRow } from "../gitdb";
import {
  TILE_SIZE,
  clusters,
  type GeoBounds,
  type MapCluster,
} from "./mapClusters";
import { PlaceTimelineView } from "./PlaceTimelineView";

const POINTER_HEIGHT = 10;
const WORLD_LATITUDE = 85.0511287798;

interface MapCamera {
  latitude: number;
  longitude: number;
  zoom: number;
}

interface MapViewProps {
  runtime: LibraryRuntimeState;
  mtlsHeaders: Record<string, string> | null;
  activeView: LibraryView;
  onSelectView: (view: LibraryView) => void;
  commitPaneOpen: boolean;
  onToggleCommitPane: () => void;
  commitPane: ReactNode;
}

interface MarkerEntry {
  marker: L.Marker;
  element: HTMLElement;
}

// Frames every photo once. Later opens keep the center and zoom the
// person already chose, including after they return from a place.
const framePhotos = (map: L.Map, points: MapPointRow[]): MapCamera => {
  const bounds = L.latLngBounds(points.map((point) => L.latLng(point.latitude, point.longitude)));
  map.fitBounds(bounds, { padding: [48, 48], maxZoom: 14, animate: false });
  const center = map.getCenter();
  return { latitude: center.lat, longitude: center.lng, zoom: map.getZoom() };
};

// Draws one place tile into a Leaflet marker. The pointer tip is the
// anchor, so the photo stays on the spot it was taken as the map zooms.
const MapClusterTile = ({
  cluster,
  item,
  mtlsHeaders,
  onSelect,
}: {
  cluster: MapCluster;
  item: TimelineItem | undefined;
  mtlsHeaders: Record<string, string> | null;
  onSelect: (bounds: GeoBounds) => void;
}) => (
  <button
    type="button"
    className="map-cluster-tile"
    aria-label={`${cluster.count} photos`}
    onClick={() => onSelect(cluster.bounds)}
  >
    <span className="map-cluster-photo">
      {item ? (
        <AuthImage
          src={item.thumbnailUrl}
          alt=""
          loading="eager"
          headers={mtlsHeaders}
          encryption={item.thumbnailEncryption}
        />
      ) : null}
      <span className="map-cluster-count">{cluster.count}</span>
    </span>
    <span className="map-cluster-pointer" />
  </button>
);

// Owns the Leaflet map. Remounting it (opening a place) restores the
// camera from the ref the parent keeps.
const MapCanvas = ({
  points,
  revision,
  cameraRef,
  mtlsHeaders,
  loadItemsByKeys,
  onSelect,
}: {
  points: MapPointRow[];
  revision: number;
  cameraRef: MutableRefObject<MapCamera | null>;
  mtlsHeaders: Record<string, string> | null;
  loadItemsByKeys: (keys: string[]) => Promise<TimelineItem[]>;
  onSelect: (bounds: GeoBounds) => void;
}) => {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const mapRef = useRef<L.Map | null>(null);
  const pointsRef = useRef(points);
  const markersRef = useRef(new Map<string, MarkerEntry>());
  const requestedRef = useRef(new Set<string>());
  const revisionRef = useRef(revision);
  const reclusterRef = useRef<() => void>(() => {});
  const [clusterList, setClusterList] = useState<MapCluster[]>([]);
  const [tiles, setTiles] = useState<{ cluster: MapCluster; element: HTMLElement }[]>([]);
  const [itemsByKey, setItemsByKey] = useState<Map<string, TimelineItem>>(new Map());
  pointsRef.current = points;
  revisionRef.current = revision;

  reclusterRef.current = () => {
    const map = mapRef.current;
    if (!map) return;
    const size = map.getSize();
    if (size.x <= 0 || size.y <= 0) return;
    let northWest;
    let southEast;
    try {
      const bounds = map.getBounds();
      northWest = map.project(bounds.getNorthWest(), 0);
      southEast = map.project(bounds.getSouthEast(), 0);
    } catch {
      return;
    }
    const media = pointsRef.current.map((row) => ({
      id: row.key,
      latitude: row.latitude,
      longitude: row.longitude,
      takenAt: Date.parse(row.takenAt) || 0,
    }));
    setClusterList(clusters(
      media,
      {
        x: northWest.x,
        y: northWest.y,
        width: southEast.x - northWest.x,
        height: southEast.y - northWest.y,
      },
      { width: size.x, height: size.y },
    ));
  };

  useEffect(() => {
    const element = containerRef.current;
    if (!element || mapRef.current) return;
    const map = L.map(element, {
      maxBounds: L.latLngBounds(
        L.latLng(-WORLD_LATITUDE, -180),
        L.latLng(WORLD_LATITUDE, 180),
      ),
      maxBoundsViscosity: 1,
      worldCopyJump: false,
    });
    L.tileLayer(runtimeConfig.mapTileUrl, {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap</a> contributors',
      noWrap: true,
    }).addTo(map);
    const saved = cameraRef.current;
    if (saved) {
      map.setView([saved.latitude, saved.longitude], saved.zoom, { animate: false });
    } else if (pointsRef.current.length > 0) {
      cameraRef.current = framePhotos(map, pointsRef.current);
    }
    const onMove = () => {
      const center = map.getCenter();
      cameraRef.current = { latitude: center.lat, longitude: center.lng, zoom: map.getZoom() };
      reclusterRef.current();
    };
    map.on("moveend", onMove);
    map.on("zoomend", onMove);
    mapRef.current = map;
    reclusterRef.current();
    const observer = typeof ResizeObserver === "undefined"
      ? null
      : new ResizeObserver(() => {
        map.invalidateSize();
        reclusterRef.current();
      });
    observer?.observe(element);
    return () => {
      observer?.disconnect();
      try {
        const center = map.getCenter();
        cameraRef.current = { latitude: center.lat, longitude: center.lng, zoom: map.getZoom() };
      } catch {
        // The map never received a view, so there is nothing to restore.
      }
      map.remove();
      mapRef.current = null;
      markersRef.current.clear();
    };
  }, [cameraRef]);

  useEffect(() => {
    reclusterRef.current();
  }, [points]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const live = new Set(clusterList.map((cluster) => cluster.representativeId));
    for (const [id, entry] of markersRef.current) {
      if (!live.has(id)) {
        entry.marker.remove();
        markersRef.current.delete(id);
      }
    }
    const nextTiles: { cluster: MapCluster; element: HTMLElement }[] = [];
    for (const cluster of clusterList) {
      let entry = markersRef.current.get(cluster.representativeId);
      if (!entry) {
        const element = document.createElement("div");
        element.className = "map-cluster-anchor";
        const marker = L.marker([cluster.latitude, cluster.longitude], {
          icon: L.divIcon({
            className: "map-cluster-icon",
            html: element,
            iconSize: [TILE_SIZE, TILE_SIZE + POINTER_HEIGHT],
            iconAnchor: [TILE_SIZE / 2, TILE_SIZE + POINTER_HEIGHT],
          }),
          keyboard: false,
        }).addTo(map);
        entry = { marker, element };
        markersRef.current.set(cluster.representativeId, entry);
      } else {
        entry.marker.setLatLng([cluster.latitude, cluster.longitude]);
      }
      nextTiles.push({ cluster, element: entry.element });
    }
    setTiles(nextTiles);
  }, [clusterList]);

  useEffect(() => {
    requestedRef.current = new Set();
    setItemsByKey(new Map());
  }, [revision]);

  useEffect(() => {
    const missing = clusterList
      .map((cluster) => cluster.representativeId)
      .filter((id) => !requestedRef.current.has(id));
    if (missing.length === 0) return;
    for (const id of missing) requestedRef.current.add(id);
    const started = revisionRef.current;
    void loadItemsByKeys(missing).then((items) => {
      if (revisionRef.current !== started) return;
      setItemsByKey((current) => {
        const next = new Map(current);
        for (const item of items) next.set(item.key, item);
        return next;
      });
    });
  }, [clusterList, loadItemsByKeys, revision]);

  return (
    <div className="map-pane">
      <div ref={containerRef} className="map-canvas" />
      {tiles.map(({ cluster, element }) => createPortal(
        <MapClusterTile
          cluster={cluster}
          item={itemsByKey.get(cluster.representativeId)}
          mtlsHeaders={mtlsHeaders}
          onSelect={onSelect}
        />,
        element,
        cluster.representativeId,
      ))}
    </div>
  );
};

// Shows the library as place tiles. Zooming changes how large a place
// is, and choosing a tile opens just the photos that tile counted.
export const MapView = ({
  runtime,
  mtlsHeaders,
  activeView,
  onSelectView,
  commitPaneOpen,
  onToggleCommitPane,
  commitPane,
}: MapViewProps) => {
  const cameraRef = useRef<MapCamera | null>(null);
  const [points, setPoints] = useState<MapPointRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selection, setSelection] = useState<GeoBounds | null>(null);

  useEffect(() => {
    let cancelled = false;
    setError(null);
    void runtime.loadMapPoints()
      .then((rows) => {
        if (!cancelled) setPoints(rows);
      })
      .catch((reason: unknown) => {
        if (cancelled) return;
        setError(reason instanceof Error && reason.message ? reason.message : "Couldn't load the map");
        setPoints((current) => current ?? []);
      });
    return () => {
      cancelled = true;
    };
  }, [runtime.loadMapPoints, runtime.manifestRevision]);

  let body: ReactNode;
  if (selection && points) {
    body = (
      <PlaceTimelineView
        bounds={selection}
        points={points}
        revision={runtime.manifestRevision}
        loadItemsByKeys={runtime.loadItemsByKeys}
        mtlsHeaders={mtlsHeaders}
        onBack={() => setSelection(null)}
        commitPane={commitPane}
      />
    );
  } else if (points === null) {
    body = (
      <div className="timeline-container">
        <div className="placeholder-content">
          <p className="empty-state">Loading the map…</p>
        </div>
        {commitPane}
      </div>
    );
  } else if (error && points.length === 0) {
    body = (
      <div className="timeline-container">
        <div className="placeholder-content">
          <p className="empty-state">Couldn&apos;t load the map</p>
          <p className="empty-state">{error}</p>
        </div>
        {commitPane}
      </div>
    );
  } else if (points.length === 0) {
    body = (
      <div className="timeline-container">
        <div className="placeholder-content">
          <p className="empty-state">No photos with location</p>
          <p className="empty-state">Photos with a location will show up here.</p>
        </div>
        {commitPane}
      </div>
    );
  } else {
    body = (
      <div className="timeline-container">
        <MapCanvas
          points={points}
          revision={runtime.manifestRevision}
          cameraRef={cameraRef}
          mtlsHeaders={mtlsHeaders}
          loadItemsByKeys={runtime.loadItemsByKeys}
          onSelect={setSelection}
        />
        {commitPane}
      </div>
    );
  }

  return (
    <div className="app-shell">
      <div className="app-main">
        <LibraryHeader
          activeView={activeView}
          onSelectView={onSelectView}
          commitPaneOpen={commitPaneOpen}
          onToggleCommitPane={onToggleCommitPane}
          syncSnapshot={runtime.snapshot}
        />
        {body}
      </div>
    </div>
  );
};
