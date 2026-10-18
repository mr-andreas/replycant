// Groups geotagged photos into tiles that stay put while the map pans.
// The grid is locked to the world and only changes when zoom crosses a
// power-of-two step. One marker per photo does not scale to a full
// library, and those clusters are not a stable box the place grid can
// query. This is the desktop port of the iOS MapClusterer.

export const TILE_SIZE = 84;
export const TILE_GAP = 8;
// Leaflet's zoom-0 world, matching map.project(latlng, 0). The map
// shows one copy of the world, so a view never crosses the antimeridian
// and cells do not need to be split there.
export const WORLD_SIZE = 256;

export interface GeoBounds {
  minLatitude: number;
  maxLatitude: number;
  minLongitude: number;
  maxLongitude: number;
}

export interface MapMediaPoint {
  id: string;
  latitude: number;
  longitude: number;
  takenAt: number;
}

export interface WorldRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ViewSize {
  width: number;
  height: number;
}

// One map tile: the newest photo, how many photos it stands for, the
// spot that photo was taken, and the box the place grid queries.
export interface MapCluster {
  count: number;
  representativeId: string;
  latitude: number;
  longitude: number;
  bounds: GeoBounds;
}

const MAX_LATITUDE = 85.0511287798;

// Projects a coordinate into zoom-0 world pixels so cell math matches
// the map the tiles are drawn on.
export const project = (latitude: number, longitude: number): { x: number; y: number } => {
  const clamped = Math.max(Math.min(latitude, MAX_LATITUDE), -MAX_LATITUDE);
  const sin = Math.sin((clamped * Math.PI) / 180);
  const x = ((longitude + 180) / 360) * WORLD_SIZE;
  const y = (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * WORLD_SIZE;
  return { x, y };
};

// Inverse of project, so tests can place a photo at a known fraction of
// a cell and still speak in latitude and longitude.
export const unproject = (x: number, y: number): { latitude: number; longitude: number } => {
  const longitude = (x / WORLD_SIZE) * 360 - 180;
  const n = Math.PI - (2 * Math.PI * y) / WORLD_SIZE;
  const latitude = (180 / Math.PI) * Math.atan(Math.sinh(n));
  return { latitude, longitude };
};

// How wide a cell should be on screen. A desktop window is much larger
// than a phone, and Leaflet only stops at whole zoom levels, so sizing
// cells from the window area pushes them to the next power of two and
// leaves most of a cell empty. Two tile widths stay near three tiles
// across in any window.
export const targetCellSize = (tileSize = TILE_SIZE): number => 2 * (tileSize + TILE_GAP);

// The world-aligned cell for this zoom. It is a power-of-two slice of
// the world, and the largest one that is still at least targetCellSize
// wide on screen.
export const cellMapSize = (
  visibleWorldRect: WorldRect,
  viewSize: ViewSize,
  tileSize = TILE_SIZE,
): number => {
  if (viewSize.width <= 0 || visibleWorldRect.width <= 0) return WORLD_SIZE;
  const target = targetCellSize(tileSize);
  const pointsPerMapPoint = viewSize.width / visibleWorldRect.width;
  if (!(target > 0) || !Number.isFinite(pointsPerMapPoint) || pointsPerMapPoint <= 0) {
    return WORLD_SIZE;
  }
  // Halve while the smaller cell is still large enough on screen. The
  // floor is only there to stop the loop; a 256-unit world needs cells
  // smaller than one unit once the view is a neighborhood.
  let cell = WORLD_SIZE;
  while (cell > 1e-9) {
    const half = cell / 2;
    if (half * pointsPerMapPoint >= target) {
      cell = half;
    } else {
      break;
    }
  }
  return cell;
};

const intersects = (cell: WorldRect, visible: WorldRect): boolean =>
  cell.x < visible.x + visible.width
  && cell.x + cell.width > visible.x
  && cell.y < visible.y + visible.height
  && cell.y + cell.height > visible.y;

// Prefers the later capture, then the greater id, so a tie still picks
// the same tile photo every time the map reclusters.
const isNewer = (point: MapMediaPoint, other: MapMediaPoint): boolean => {
  if (point.takenAt !== other.takenAt) return point.takenAt > other.takenAt;
  return point.id > other.id;
};

// Clusters photos into world-aligned cells, then draws the cells that
// meet the screen. A cell's count and photo come from every member, so
// a pan can only show or hide a whole group. The tile is pinned to the
// photo it shows, which can overlap a neighbor.
export const clusters = (
  points: MapMediaPoint[],
  visibleWorldRect: WorldRect,
  viewSize: ViewSize,
  tileSize = TILE_SIZE,
): MapCluster[] => {
  if (viewSize.width <= 0 || visibleWorldRect.width <= 0) return [];
  const cell = cellMapSize(visibleWorldRect, viewSize, tileSize);
  if (!(cell > 0) || !Number.isFinite(cell)) return [];

  interface Bucket {
    count: number;
    representative: MapMediaPoint;
    minLatitude: number;
    maxLatitude: number;
    minLongitude: number;
    maxLongitude: number;
    originX: number;
    originY: number;
  }
  const buckets = new Map<string, Bucket>();

  for (const point of points) {
    const mapPoint = project(point.latitude, point.longitude);
    const indexX = Math.floor(mapPoint.x / cell);
    const indexY = Math.floor(mapPoint.y / cell);
    const key = `${indexX}x${indexY}`;
    const existing = buckets.get(key);
    if (existing) {
      existing.count += 1;
      existing.minLatitude = Math.min(existing.minLatitude, point.latitude);
      existing.maxLatitude = Math.max(existing.maxLatitude, point.latitude);
      existing.minLongitude = Math.min(existing.minLongitude, point.longitude);
      existing.maxLongitude = Math.max(existing.maxLongitude, point.longitude);
      if (isNewer(point, existing.representative)) existing.representative = point;
    } else {
      buckets.set(key, {
        count: 1,
        representative: point,
        minLatitude: point.latitude,
        maxLatitude: point.latitude,
        minLongitude: point.longitude,
        maxLongitude: point.longitude,
        originX: indexX * cell,
        originY: indexY * cell,
      });
    }
  }

  return [...buckets.values()]
    .filter((bucket) => intersects(
      { x: bucket.originX, y: bucket.originY, width: cell, height: cell },
      visibleWorldRect,
    ))
    .map((bucket) => ({
      count: bucket.count,
      representativeId: bucket.representative.id,
      latitude: bucket.representative.latitude,
      longitude: bucket.representative.longitude,
      bounds: {
        minLatitude: bucket.minLatitude,
        maxLatitude: bucket.maxLatitude,
        minLongitude: bucket.minLongitude,
        maxLongitude: bucket.maxLongitude,
      },
    }))
    .sort((a, b) => (a.representativeId < b.representativeId ? -1 : a.representativeId > b.representativeId ? 1 : 0));
};
