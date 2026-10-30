import { afterEach, describe, expect, it, vi } from "vitest";
import { attachMapWheelZoom } from "./mapWheelZoom";

// A slight scroll must scale the tiles already on screen. Resetting the
// view deletes every tile and flashes the map.
describe("attachMapWheelZoom", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("scales the current tiles instead of resetting the view", () => {
    vi.useFakeTimers();
    const element = document.createElement("div");
    let zoom = 6;
    const move = vi.fn((
      _center: unknown,
      next: number,
      _data?: { pinch?: boolean; round?: boolean },
    ) => {
      zoom = next;
    });
    const moveStart = vi.fn();
    const moveEnd = vi.fn();
    const setView = vi.fn();
    const resetView = vi.fn();
    const map = {
      options: { wheelPxPerZoomLevel: 60 },
      getZoom: () => zoom,
      getSize: () => ({ x: 800, y: 600 }),
      getZoomScale: (next: number) => 2 ** (next - zoom),
      mouseEventToContainerPoint: () => ({ x: 100, y: 80 }),
      containerPointToLatLng: (point: { x: number; y: number }) => ({ lat: point.y, lng: point.x }),
      _limitZoom: (next: number) => next,
      _limitCenter: <T>(center: T) => center,
      _moveStart: moveStart,
      _move: move,
      _moveEnd: moveEnd,
      setView,
      _resetView: resetView,
    };
    const detach = attachMapWheelZoom(map, element);

    element.dispatchEvent(new WheelEvent("wheel", {
      deltaY: -48,
      deltaMode: 0,
      clientX: 100,
      clientY: 80,
      bubbles: true,
      cancelable: true,
    }));
    vi.advanceTimersByTime(16);

    expect(move).toHaveBeenCalledTimes(1);
    const [, nextZoom, data] = move.mock.calls[0]!;
    expect(data).toEqual({ pinch: true, round: false });
    expect(nextZoom).not.toBe(6);
    expect(Math.abs(nextZoom - 6)).toBeLessThan(1);
    expect(nextZoom).not.toBe(Math.round(nextZoom));
    expect(setView).not.toHaveBeenCalled();
    expect(resetView).not.toHaveBeenCalled();
    expect(moveStart).toHaveBeenCalledTimes(1);
    expect(moveEnd).not.toHaveBeenCalled();

    vi.advanceTimersByTime(80);
    expect(moveEnd).toHaveBeenCalledTimes(1);
    expect(setView).not.toHaveBeenCalled();
    expect(resetView).not.toHaveBeenCalled();
    detach();
  });
});
