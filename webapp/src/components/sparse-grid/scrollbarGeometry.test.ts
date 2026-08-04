import { describe, expect, it } from "vitest";
import { scrollbarGeometry } from "./scrollbarGeometry";

describe("scrollbarGeometry", () => {
  it("returns hidden geometry when no scrolling range exists", () => {
    expect(scrollbarGeometry({
      scrollTop: 0,
      totalHeight: 500,
      viewportHeight: 500,
      trackHeight: 200,
    })).toEqual({
      visible: false,
      thumbHeight: 0,
      thumbTop: 0,
      maxThumbTop: 0,
      maxScrollTop: 0,
    });
  });

  it("maps scroll position to thumb position", () => {
    const geometry = scrollbarGeometry({
      scrollTop: 250,
      totalHeight: 1000,
      viewportHeight: 250,
      trackHeight: 200,
      minThumbHeight: 20,
    });

    expect(geometry.visible).toBe(true);
    expect(geometry.thumbHeight).toBe(50);
    expect(geometry.maxScrollTop).toBe(750);
    expect(geometry.maxThumbTop).toBe(150);
    expect(geometry.thumbTop).toBeCloseTo(50);
  });
});
