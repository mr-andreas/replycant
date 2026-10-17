import { renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { TimelineItem } from "../../lib/timeline";
import type { MapPointRow } from "../gitdb";
import { usePlaceTimeline } from "./usePlaceTimeline";

const bounds = {
  minLatitude: 59,
  maxLatitude: 60,
  minLongitude: 18,
  maxLongitude: 19,
};

const point = (
  key: string,
  takenAt: string,
  latitude = 59.3,
  longitude = 18.1,
): MapPointRow => ({ key, takenAt, latitude, longitude });

const itemFor = (key: string, takenAt: string): TimelineItem => ({
  key,
  dayKey: takenAt.slice(0, 10),
  monthKey: takenAt.slice(0, 7),
  yearKey: takenAt.slice(0, 4),
  timestamp: takenAt,
  mediaType: "image",
  sha256: "abc",
  filesize: 1,
  width: 10,
  height: 10,
  isHeic: false,
  heicOriginalUrl: null,
  mimeType: "image/jpeg",
  thumbnailUrl: "https://example.com/thumb.jpg",
  intermediateViewerUrl: null,
  viewerUrl: "https://example.com/view.jpg",
  downloadUrl: "https://example.com/file.jpg",
  originalFileName: `${key}.jpg`,
});

describe("usePlaceTimeline", () => {
  it("keeps photos inside the tile bounds, oldest first, and counts months from the start", async () => {
    const loadItemsByKeys = vi.fn(async (keys: string[]) =>
      keys.map((key) => itemFor(key, key === "a" ? "2024-01-02T00:00:00.000Z" : "2024-01-01T00:00:00.000Z")),
    );
    const points = [
      point("b", "2024-01-02T00:00:00.000Z"),
      point("outside", "2024-02-01T00:00:00.000Z", 10, 10),
      point("a", "2024-01-02T00:00:00.000Z"),
      point("earlier", "2024-01-01T00:00:00.000Z"),
    ];
    const { result } = renderHook(() => usePlaceTimeline({
      points,
      bounds,
      revision: 1,
      loadItemsByKeys,
    }));

    expect(result.current.itemCount).toBe(3);
    expect(result.current.monthIndex.map((month) => [month.monthKey, month.globalOffset, month.count])).toEqual([
      ["2024-01", 0, 3],
    ]);
    await waitFor(() => {
      expect(loadItemsByKeys).toHaveBeenCalledWith(["earlier", "a", "b"]);
    });
  });

  it("pages the newest rows first and loads older rows on demand", async () => {
    const points = Array.from({ length: 150 }, (_, index) => point(
      `p-${String(index).padStart(3, "0")}`,
      new Date(Date.UTC(2024, 0, 1) + index * 86_400_000).toISOString(),
    ));
    const loadItemsByKeys = vi.fn(async (keys: string[]) =>
      keys.map((key) => itemFor(key, points.find((row) => row.key === key)?.takenAt ?? "")),
    );
    const { result } = renderHook(() => usePlaceTimeline({
      points,
      bounds,
      revision: 1,
      loadItemsByKeys,
    }));

    const newest = points.slice(50).map((row) => row.key);
    await waitFor(() => {
      expect(loadItemsByKeys).toHaveBeenCalledWith(newest);
      expect(result.current.loadedOffset).toBe(50);
    });

    result.current.loadOlderPage();
    await waitFor(() => {
      expect(loadItemsByKeys).toHaveBeenCalledWith(points.slice(0, 50).map((row) => row.key));
      expect(result.current.loadedOffset).toBe(0);
      expect(result.current.loadedItems).toHaveLength(150);
    });
  });

  it("reloads when the library revision changes", async () => {
    const loadItemsByKeys = vi.fn(async (keys: string[]) =>
      keys.map((key) => itemFor(key, "2024-03-01T00:00:00.000Z")),
    );
    const { result, rerender } = renderHook(
      (props: { points: MapPointRow[]; revision: number }) => usePlaceTimeline({
        points: props.points,
        bounds,
        revision: props.revision,
        loadItemsByKeys,
      }),
      { initialProps: { points: [point("only", "2024-03-01T00:00:00.000Z")], revision: 1 } },
    );

    expect(result.current.itemCount).toBe(1);
    await waitFor(() => expect(loadItemsByKeys).toHaveBeenCalledTimes(1));

    rerender({
      points: [
        point("only", "2024-03-01T00:00:00.000Z"),
        point("added", "2024-04-01T00:00:00.000Z"),
      ],
      revision: 2,
    });
    expect(result.current.itemCount).toBe(2);
    expect(result.current.monthIndex.map((month) => month.monthKey)).toEqual(["2024-03", "2024-04"]);
    expect(result.current.monthIndex[1].globalOffset).toBe(1);
    await waitFor(() => expect(loadItemsByKeys).toHaveBeenCalledTimes(2));
  });
});
