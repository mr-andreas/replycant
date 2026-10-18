import { describe, expect, it } from "vitest";
import {
  WORLD_SIZE,
  cellMapSize,
  clusters,
  project,
  targetCellSize,
  unproject,
  type GeoBounds,
  type MapCluster,
  type MapMediaPoint,
  type ViewSize,
  type WorldRect,
} from "./mapClusters";

const viewSize: ViewSize = { width: 400, height: 800 };

const point = (
  id: string,
  latitude: number,
  longitude: number,
  takenAt: number,
): MapMediaPoint => ({ id, latitude, longitude, takenAt });

const mapRect = (
  center: { latitude: number; longitude: number },
  latitudeDelta: number,
  size: ViewSize,
): WorldRect => {
  const aspect = size.width / size.height;
  const latitudeRadians = (center.latitude * Math.PI) / 180;
  const longitudeDelta = (latitudeDelta * aspect) / Math.cos(latitudeRadians);
  const northWest = project(center.latitude + latitudeDelta / 2, center.longitude - longitudeDelta / 2);
  const southEast = project(center.latitude - latitudeDelta / 2, center.longitude + longitudeDelta / 2);
  return {
    x: Math.min(northWest.x, southEast.x),
    y: Math.min(northWest.y, southEast.y),
    width: Math.abs(southEast.x - northWest.x),
    height: Math.abs(southEast.y - northWest.y),
  };
};

const cellOrigin = (
  center: { latitude: number; longitude: number },
  cell: number,
): { x: number; y: number } => {
  const anchor = project(center.latitude, center.longitude);
  return {
    x: Math.floor(anchor.x / cell) * cell,
    y: Math.floor(anchor.y / cell) * cell,
  };
};

const pointAt = (
  origin: { x: number; y: number },
  dx: number,
  dy: number,
  cell: number,
  id: string,
  takenAt: number,
): MapMediaPoint => {
  const coordinate = unproject(origin.x + dx * cell, origin.y + dy * cell);
  return point(id, coordinate.latitude, coordinate.longitude, takenAt);
};

const centeredOnCell = (rect: WorldRect, center: { latitude: number; longitude: number }): WorldRect => {
  const cell = cellMapSize(rect, viewSize);
  const origin = cellOrigin(center, cell);
  const focus = { x: origin.x + cell / 2, y: origin.y + cell / 2 };
  return {
    x: focus.x - rect.width / 2,
    y: focus.y - rect.height / 2,
    width: rect.width,
    height: rect.height,
  };
};

const rectCuttingCell = (
  origin: { x: number; y: number },
  cell: number,
  size: { width: number; height: number },
  fraction: number,
): WorldRect => ({
  x: origin.x + cell * fraction - size.width,
  y: origin.y + cell * 0.5 - size.height / 2,
  width: size.width,
  height: size.height,
});

// A rectangle whose width in zoom-0 units is the view width divided by
// 2^zoom, which is what Leaflet shows at a whole zoom level.
const integerZoomRect = (
  center: { latitude: number; longitude: number },
  zoom: number,
  size: ViewSize,
): WorldRect => {
  const pointsPerMapPoint = 2 ** zoom;
  const width = size.width / pointsPerMapPoint;
  const height = size.height / pointsPerMapPoint;
  const anchor = project(center.latitude, center.longitude);
  return {
    x: anchor.x - width / 2,
    y: anchor.y - height / 2,
    width,
    height,
  };
};

const scaled = (rect: WorldRect, factor: number): WorldRect => {
  const width = rect.width * factor;
  const height = rect.height * factor;
  return {
    x: rect.x + rect.width / 2 - width / 2,
    y: rect.y + rect.height / 2 - height / 2,
    width,
    height,
  };
};

const contains = (outer: GeoBounds, inner: GeoBounds): boolean =>
  inner.minLatitude >= outer.minLatitude
  && inner.maxLatitude <= outer.maxLatitude
  && inner.minLongitude >= outer.minLongitude
  && inner.maxLongitude <= outer.maxLongitude;

const overlaps = (lhs: GeoBounds, rhs: GeoBounds): boolean =>
  lhs.minLatitude <= rhs.maxLatitude
  && rhs.minLatitude <= lhs.maxLatitude
  && lhs.minLongitude <= rhs.maxLongitude
  && rhs.minLongitude <= lhs.maxLongitude;

const sameClusters = (left: MapCluster[], right: MapCluster[]): boolean =>
  left.length === right.length
  && left.every((cluster, index) => {
    const other = right[index];
    return cluster.count === other.count
      && cluster.representativeId === other.representativeId
      && cluster.latitude === other.latitude
      && cluster.longitude === other.longitude;
  });

describe("map clusters", () => {
  it("merges a neighborhood when zoomed out and splits it when zoomed in", () => {
    const older = point("older", 59.33, 18.06, 10);
    const newer = point("newer", 59.34, 18.07, 20);
    const center = { latitude: 59.335, longitude: 18.065 };

    const zoomedOut = clusters( [older, newer], mapRect(center, 20, viewSize), viewSize);
    expect(zoomedOut).toHaveLength(1);
    expect(zoomedOut[0].count).toBe(2);

    const zoomedIn = clusters([older, newer], mapRect(center, 0.014, viewSize), viewSize);
    expect(zoomedIn).toHaveLength(2);
    expect(zoomedIn.map((cluster) => cluster.representativeId).sort()).toEqual(["newer", "older"]);
  });

  it("pins the tile to the newest photo's own coordinate", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const probe = mapRect(center, 1, viewSize);
    const rect = centeredOnCell(probe, center);
    const cell = cellMapSize(rect, viewSize);
    const origin = cellOrigin(center, cell);
    const older = pointAt(origin, 0.4, 0.4, cell, "older", 10);
    const middle = pointAt(origin, 0.6, 0.4, cell, "middle", 20);
    const newer = pointAt(origin, 0.4, 0.6, cell, "newer", 30);
    const grouped = clusters([older, middle, newer], rect, viewSize);
    expect(grouped).toHaveLength(1);
    expect(grouped[0].representativeId).toBe("newer");
    expect(grouped[0].latitude).toBeCloseTo(newer.latitude, 9);
    expect(grouped[0].longitude).toBeCloseTo(newer.longitude, 9);
  });

  it("uses the tight bounds of the members so the place grid counts the same photos", () => {
    const first = point("first", 59.33, 18.06, 10);
    const second = point("second", 59.35, 18.09, 20);
    const grouped = clusters(
      [first, second],
      mapRect({ latitude: 59.34, longitude: 18.075 }, 20, viewSize),
      viewSize,
    );
    expect(grouped).toHaveLength(1);
    expect(grouped[0].bounds).toEqual({
      minLatitude: 59.33,
      maxLatitude: 59.35,
      minLongitude: 18.06,
      maxLongitude: 18.09,
    });
  });

  it("keeps off-screen members of a cell that only partly meets the view", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const probe = mapRect(center, 0.5, viewSize);
    const cell = cellMapSize(probe, viewSize);
    const origin = cellOrigin(center, cell);
    const rect = rectCuttingCell(origin, cell, probe, 0.5);
    const onScreen = pointAt(origin, 0.3, 0.5, cell, "on-screen", 10);
    const offScreen = pointAt(origin, 0.7, 0.5, cell, "off-screen", 30);
    const grouped = clusters([onScreen, offScreen], rect, viewSize);
    expect(grouped).toHaveLength(1);
    expect(grouped[0].count).toBe(2);
    expect(grouped[0].representativeId).toBe("off-screen");
  });

  it("does not rebuild a group when the view slides further across the same cell", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const probe = mapRect(center, 0.5, viewSize);
    const cell = cellMapSize(probe, viewSize);
    const origin = cellOrigin(center, cell);
    const rect = rectCuttingCell(origin, cell, probe, 0.5);
    const shifted = { ...rect, x: rect.x + cell * 0.3 };
    const onScreen = pointAt(origin, 0.3, 0.5, cell, "on-screen", 10);
    const offScreen = pointAt(origin, 0.7, 0.5, cell, "off-screen", 30);
    const before = clusters([onScreen, offScreen], rect, viewSize);
    const after = clusters([onScreen, offScreen], shifted, viewSize);
    expect(sameClusters(before, after)).toBe(true);
    expect(before[0]?.count).toBe(2);
  });

  it("drops groups whose cell lies entirely off screen", () => {
    const visible = point("visible", 59.33, 18.06, 10);
    const hidden = point("hidden", 40.71, -74, 20);
    const grouped = clusters(
      [visible, hidden],
      mapRect({ latitude: 59.33, longitude: 18.06 }, 1, viewSize),
      viewSize,
    );
    expect(grouped.map((cluster) => cluster.representativeId)).toEqual(["visible"]);
  });

  it("keeps groups when the view pans without crossing a cell boundary", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const rect = centeredOnCell(mapRect(center, 0.5, viewSize), center);
    const cell = cellMapSize(rect, viewSize);
    const origin = cellOrigin(center, cell);
    const points = [
      pointAt(origin, 0.45, 0.5, cell, "left", 10),
      pointAt(origin, 0.55, 0.5, cell, "right", 20),
    ];
    const shifted = {
      x: rect.x + cell * 0.15,
      y: rect.y + cell * 0.15,
      width: rect.width,
      height: rect.height,
    };
    expect(sameClusters(clusters(points, rect, viewSize), clusters(points, shifted, viewSize))).toBe(true);
  });

  it("keeps groups when zoom changes without crossing a power-of-two step", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const rect = centeredOnCell(mapRect(center, 0.5, viewSize), center);
    const cell = cellMapSize(rect, viewSize);
    const onScreen = (cell * viewSize.width) / rect.width;
    const target = targetCellSize();
    const slack = onScreen / target;
    const zoomIn = 1 + (2 / slack - 1) * 0.5;
    const closer = scaled(rect, 1 / zoomIn);
    const origin = cellOrigin(center, cell);
    const points = [
      pointAt(origin, 0.48, 0.5, cell, "a", 1),
      pointAt(origin, 0.52, 0.52, cell, "b", 2),
    ];
    expect(cellMapSize(closer, viewSize)).toBe(cell);
    expect(sameClusters(clusters(points, rect, viewSize), clusters(points, closer, viewSize))).toBe(true);
  });

  it("splits each group into its child cells at the next zoom step", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const coarseRect = centeredOnCell(mapRect(center, 0.5, viewSize), center);
    const fineRect = scaled(coarseRect, 0.5);
    const cell = cellMapSize(coarseRect, viewSize);
    const origin = cellOrigin(center, cell);
    const points = [
      pointAt(origin, 0.25, 0.5, cell, "a", 1),
      pointAt(origin, 0.75, 0.5, cell, "b", 2),
    ];
    const coarse = clusters(points, coarseRect, viewSize);
    const fine = clusters(points, fineRect, viewSize);
    const fineCell = cellMapSize(fineRect, viewSize);
    expect(Math.abs(cell / fineCell - 2)).toBeLessThan(0.001);
    expect(coarse.reduce((sum, cluster) => sum + cluster.count, 0)).toBe(points.length);
    expect(fine.reduce((sum, cluster) => sum + cluster.count, 0)).toBe(points.length);
    for (const child of fine) {
      expect(coarse.some((group) => contains(group.bounds, child.bounds))).toBe(true);
    }
  });

  it("uses the same cell at one zoom whether the window is small or large", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const small: ViewSize = { width: 400, height: 800 };
    const large: ViewSize = { width: 1920, height: 1080 };
    const zoom = 8;
    expect(cellMapSize(integerZoomRect(center, zoom, small), small)).toBe(
      cellMapSize(integerZoomRect(center, zoom, large), large),
    );
  });

  it("keeps a desktop cell 256 px wide at a whole zoom level", () => {
    const size: ViewSize = { width: 1250, height: 930 };
    const rect = integerZoomRect({ latitude: 59.33, longitude: 18.06 }, 8, size);
    const cell = cellMapSize(rect, size);
    const onScreen = (cell * size.width) / rect.width;
    expect(onScreen).toBe(256);
  });

  it("keeps the cell a power-of-two slice that stays between the target size and twice that", () => {
    const rect = mapRect({ latitude: 59.33, longitude: 18.06 }, 0.5, viewSize);
    const cell = cellMapSize(rect, viewSize);
    const onScreen = (cell * viewSize.width) / rect.width;
    const target = targetCellSize();
    expect(onScreen).toBeGreaterThanOrEqual(target);
    expect(onScreen).toBeLessThan(target * 2);
    const ratio = WORLD_SIZE / cell;
    expect(Math.abs(ratio - Math.round(ratio)) / ratio).toBeLessThan(1e-8);
    const exponent = Math.log2(Math.round(ratio));
    expect(Math.abs(exponent - Math.round(exponent))).toBeLessThan(1e-6);
  });

  it("leaves a photo on a cell edge at its own coordinate", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const rect = centeredOnCell(mapRect(center, 0.5, viewSize), center);
    const cell = cellMapSize(rect, viewSize);
    const origin = cellOrigin(center, cell);
    const edge = pointAt(origin, 0.99, 0.01, cell, "edge", 1);
    const grouped = clusters([edge], rect, viewSize);
    expect(grouped).toHaveLength(1);
    expect(grouped[0].latitude).toBeCloseTo(edge.latitude, 9);
    expect(grouped[0].longitude).toBeCloseTo(edge.longitude, 9);
  });

  it("keeps the newest photo pointing at the same spot when its group splits", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const coarseRect = centeredOnCell(mapRect(center, 0.5, viewSize), center);
    const fineRect = scaled(coarseRect, 0.5);
    const cell = cellMapSize(coarseRect, viewSize);
    const origin = cellOrigin(center, cell);
    const older = pointAt(origin, 0.25, 0.25, cell, "older", 1);
    const newer = pointAt(origin, 0.75, 0.75, cell, "newer", 2);
    const coarse = clusters([older, newer], coarseRect, viewSize);
    const fine = clusters([older, newer], fineRect, viewSize);
    const split = fine.find((cluster) => cluster.representativeId === "newer");
    expect(coarse).toHaveLength(1);
    expect(fine).toHaveLength(2);
    expect(coarse[0].representativeId).toBe("newer");
    expect(coarse[0].latitude).toBeCloseTo(newer.latitude, 9);
    expect(coarse[0].longitude).toBeCloseTo(newer.longitude, 9);
    expect(split?.latitude).toBeCloseTo(newer.latitude, 9);
    expect(split?.longitude).toBeCloseTo(newer.longitude, 9);
  });

  it("gives neighboring groups boxes that do not overlap", () => {
    const center = { latitude: 59.33, longitude: 18.06 };
    const probe = mapRect(center, 0.5, viewSize);
    const cell = cellMapSize(probe, viewSize);
    const anchor = project(center.latitude, center.longitude);
    const boundary = {
      x: (Math.floor(anchor.x / cell) + 1) * cell,
      y: (Math.floor(anchor.y / cell) + 0.5) * cell,
    };
    const rect = {
      x: boundary.x - probe.width / 2,
      y: boundary.y - probe.height / 2,
      width: probe.width,
      height: probe.height,
    };
    const left = pointAt(
      { x: boundary.x - cell, y: boundary.y - cell * 0.5 },
      0.99,
      0,
      cell,
      "left",
      1,
    );
    const right = pointAt(
      { x: boundary.x, y: boundary.y - cell * 0.5 },
      0.01,
      0,
      cell,
      "right",
      2,
    );
    const grouped = clusters([left, right], rect, viewSize);
    expect(grouped).toHaveLength(2);
    expect(overlaps(grouped[0].bounds, grouped[1].bounds)).toBe(false);
  });
});
