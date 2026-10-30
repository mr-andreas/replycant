import L from "leaflet";

const WHEEL_SETTLE_MS = 80;

interface MapPoint {
  x: number;
  y: number;
}

interface MapLatLng {
  lat: number;
  lng: number;
}

// Leaflet's public zoom resets the view and deletes every tile. The
// pinch helpers scale the tiles already on screen instead.
export interface MapWheelZoom {
  options: {
    wheelPxPerZoomLevel?: number;
    maxBounds?: L.LatLngBounds | null;
  };
  getZoom(): number;
  getSize(): MapPoint;
  getZoomScale(zoom: number, fromZoom?: number): number;
  mouseEventToContainerPoint(event: MouseEvent): MapPoint;
  containerPointToLatLng(point: MapPoint): MapLatLng;
  _limitZoom(zoom: number): number;
  _limitCenter(center: MapLatLng, zoom: number, bounds?: L.LatLngBounds | null): MapLatLng;
  _moveStart(zoomChanged: boolean, noMoveStart: boolean): void;
  _move(center: MapLatLng, zoom: number, data?: { pinch?: boolean; round?: boolean }): void;
  _moveEnd(zoomChanged: boolean): void;
}

// Keeps the point under the cursor fixed, so a scroll grows the map
// around the fingers rather than around the center of the window.
const centerAtZoom = (map: MapWheelZoom, point: MapPoint, zoom: number): MapLatLng => {
  const scale = map.getZoomScale(zoom);
  const size = map.getSize();
  const halfX = size.x / 2;
  const halfY = size.y / 2;
  const factor = 1 - 1 / scale;
  return map.containerPointToLatLng({
    x: halfX + (point.x - halfX) * factor,
    y: halfY + (point.y - halfY) * factor,
  });
};

// Scales the tiles already on screen for a trackpad scroll. The stock
// wheel handler resets the view on every sample, which flashes the map.
export const attachMapWheelZoom = (map: MapWheelZoom, element: HTMLElement): (() => void) => {
  let pending = 0;
  let anchor: MapPoint | null = null;
  let frame: number | null = null;
  let quiet: number | null = null;
  let settled = true;
  const pixelsPerLevel = map.options.wheelPxPerZoomLevel ?? 60;

  const apply = () => {
    frame = null;
    if (!anchor || pending === 0 || pixelsPerLevel === 0) return;
    const zoom = map._limitZoom(map.getZoom() + pending / pixelsPerLevel);
    const center = map._limitCenter(centerAtZoom(map, anchor, zoom), zoom, map.options.maxBounds);
    pending = 0;
    if (settled) {
      map._moveStart(true, false);
      settled = false;
    }
    map._move(center, zoom, { pinch: true, round: false });
  };

  // Groups and the saved camera update once the fingers stop. Doing
  // that on every sample rebuilds the place tiles mid-gesture.
  const finish = () => {
    quiet = null;
    if (frame !== null) {
      cancelAnimationFrame(frame);
      apply();
    }
    if (!settled) {
      map._moveEnd(true);
      settled = true;
    }
  };

  const onWheel = (event: WheelEvent) => {
    event.preventDefault();
    pending += L.DomEvent.getWheelDelta(event);
    anchor = map.mouseEventToContainerPoint(event);
    if (frame === null) frame = requestAnimationFrame(apply);
    if (quiet !== null) window.clearTimeout(quiet);
    quiet = window.setTimeout(finish, WHEEL_SETTLE_MS);
  };

  element.addEventListener("wheel", onWheel, { passive: false });
  return () => {
    element.removeEventListener("wheel", onWheel);
    if (frame !== null) cancelAnimationFrame(frame);
    if (quiet !== null) window.clearTimeout(quiet);
  };
};
