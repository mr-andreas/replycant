import { describe, expect, it } from "vitest";
import { buildMonthEntries, buildTimeline, findItemIndexByTakenAt, monthKeyForGlobalIndex, TimelineItem, totalCountFromMonthIndex } from "./timeline";

describe("buildTimeline", () => {
  it("builds month keys in chronological order", () => {
    const items = buildTimeline(
      [
        {
          key: "a/1",
          deviceSpace: "a",
          name: "1",
          id: "1",
          sha256: "h1",
          filesize: 1000,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 100,
          height: 100,
          duration: undefined,
          takenAt: "2026-01-02T00:00:00Z",
          files: { originalPath: "/a", lfsHash: "h1" },
        },
      ],
      new Map(),
      200,
      1,
    );

    expect(items[0]?.monthKey).toBe("2026-01");
    expect(items[0]?.mediaType).toBe("photo");
  });

  it("routes heic viewer URLs through lfs objects", () => {
    const items = buildTimeline(
      [
        {
          key: "a/2",
          deviceSpace: "a",
          name: "2",
          id: "2",
          sha256: "h2",
          filesize: 1000,
          mediaType: "photo",
          mimeType: "image/heic",
          width: 100,
          height: 100,
          duration: undefined,
          takenAt: "2026-01-04T00:00:00Z",
          files: { originalPath: "/b", lfsHash: "h2" },
        },
      ],
      new Map(),
      200,
      1,
    );

    expect(items[0]?.viewerUrl).toBe("/api/lfs/objects/h2");
    expect(items[0]?.isHeic).toBe(true);
    expect(items[0]?.heicOriginalUrl).toBe("/api/lfs/objects/h2");
  });

  it("routes video viewer URLs through transcoded hls endpoint", () => {
    const items = buildTimeline(
      [
        {
          key: "a/3",
          deviceSpace: "a",
          name: "3",
          id: "3",
          sha256: "h3",
          filesize: 1000,
          mediaType: "video",
          mimeType: "video/mp4",
          width: 100,
          height: 100,
          duration: 11,
          takenAt: "2026-01-05T00:00:00Z",
          files: { originalPath: "/videos/clip.mp4", lfsHash: "h3" },
        },
      ],
      new Map(),
      200,
      1,
    );

    expect(items[0]?.viewerUrl).toBe("/api/decryptd/objects/h3");
    expect(items[0]?.duration).toBe(11);
    expect(items[0]?.downloadUrl).toBe("/api/lfs/objects/h3");
    expect(items[0]?.mimeType).toBe("video/mp4");
    expect(items[0]?.originalFileName).toBe("clip.mp4");
  });

  it("populates download metadata for image entries", () => {
    const items = buildTimeline(
      [
        {
          key: "a/4",
          deviceSpace: "a",
          name: "4",
          id: "4",
          sha256: "h4",
          filesize: 1000,
          mediaType: "photo",
          mimeType: "image/jpeg",
          width: 100,
          height: 100,
          duration: undefined,
          takenAt: "2026-01-06T00:00:00Z",
          files: { originalPath: "camera/IMG_0004.JPG", lfsHash: "h4" },
        },
      ],
      new Map(),
      200,
      1,
    );

    expect(items[0]?.downloadUrl).toBe("/api/lfs/objects/h4");
    expect(items[0]?.mimeType).toBe("image/jpeg");
    expect(items[0]?.originalFileName).toBe("IMG_0004.JPG");
  });
});

const makeItem = (key: string, timestamp: string, monthKey: string): TimelineItem => ({
  key,
  dayKey: timestamp.slice(0, 10),
  monthKey,
  yearKey: timestamp.slice(0, 4),
  timestamp,
  mediaType: "photo",
  sha256: key,
  filesize: 1000,
  width: 100,
  height: 100,
  isHeic: false,
  heicOriginalUrl: null,
  mimeType: "image/jpeg",
  thumbnailUrl: `/thumb-${key}.jpg`,
  intermediateViewerUrl: null,
  viewerUrl: `/full-${key}.jpg`,
  downloadUrl: `/api/lfs/objects/${key}`,
  originalFileName: `${key}.jpg`,
});

describe("findItemIndexByTakenAt", () => {
  const items: TimelineItem[] = [
    makeItem("a", "2026-01-02T00:00:00Z", "2026-01"),
    makeItem("b", "2026-01-15T00:00:00Z", "2026-01"),
    makeItem("c", "2026-02-03T00:00:00Z", "2026-02"),
    makeItem("d", "2026-03-10T00:00:00Z", "2026-03"),
  ];

  it("finds exact match", () => {
    expect(findItemIndexByTakenAt(items, "2026-02-03T00:00:00Z")).toBe(2);
  });

  it("finds first item on or after target when no exact match", () => {
    expect(findItemIndexByTakenAt(items, "2026-01-10T00:00:00Z")).toBe(1);
  });

  it("returns first item when target is before all items", () => {
    expect(findItemIndexByTakenAt(items, "2020-01-01T00:00:00Z")).toBe(0);
  });

  it("returns last item when target is after all items", () => {
    expect(findItemIndexByTakenAt(items, "2030-01-01T00:00:00Z")).toBe(3);
  });

  it("works with a single item", () => {
    expect(findItemIndexByTakenAt([items[0]], "2026-01-02T00:00:00Z")).toBe(0);
  });
});

describe("buildMonthEntries", () => {
  it("computes cumulative globalOffset", () => {
    const entries = buildMonthEntries([
      { monthKey: "2026-01", count: 10, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 5, firstTakenAt: "2026-02-01T00:00:00Z" },
      { monthKey: "2026-03", count: 8, firstTakenAt: "2026-03-01T00:00:00Z" },
    ]);
    expect(entries.map((e) => e.globalOffset)).toEqual([0, 10, 15]);
    expect(entries.map((e) => e.yearKey)).toEqual(["2026", "2026", "2026"]);
  });

  it("returns empty for empty input", () => {
    expect(buildMonthEntries([])).toEqual([]);
  });
});

describe("totalCountFromMonthIndex", () => {
  it("sums all counts", () => {
    const entries = buildMonthEntries([
      { monthKey: "2026-01", count: 10, firstTakenAt: "2026-01-01T00:00:00Z" },
      { monthKey: "2026-02", count: 5, firstTakenAt: "2026-02-01T00:00:00Z" },
    ]);
    expect(totalCountFromMonthIndex(entries)).toBe(15);
  });

  it("returns 0 for empty index", () => {
    expect(totalCountFromMonthIndex([])).toBe(0);
  });
});

describe("monthKeyForGlobalIndex", () => {
  const entries = buildMonthEntries([
    { monthKey: "2026-01", count: 10, firstTakenAt: "2026-01-01T00:00:00Z" },
    { monthKey: "2026-02", count: 5, firstTakenAt: "2026-02-01T00:00:00Z" },
    { monthKey: "2026-03", count: 8, firstTakenAt: "2026-03-01T00:00:00Z" },
  ]);

  it("resolves first month", () => {
    expect(monthKeyForGlobalIndex(entries, 0)).toBe("2026-01");
    expect(monthKeyForGlobalIndex(entries, 9)).toBe("2026-01");
  });

  it("resolves middle month", () => {
    expect(monthKeyForGlobalIndex(entries, 10)).toBe("2026-02");
    expect(monthKeyForGlobalIndex(entries, 14)).toBe("2026-02");
  });

  it("resolves last month", () => {
    expect(monthKeyForGlobalIndex(entries, 15)).toBe("2026-03");
    expect(monthKeyForGlobalIndex(entries, 22)).toBe("2026-03");
  });

  it("returns null for empty index", () => {
    expect(monthKeyForGlobalIndex([], 0)).toBeNull();
  });
});
