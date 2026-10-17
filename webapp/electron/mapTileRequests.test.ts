import { describe, expect, it, vi } from "vitest";
import type { Session } from "electron";
import { mapTileUserAgent, OSM_TILE_URL_FILTER, registerMapTileRequests } from "./mapTileRequests";

describe("map tile requests", () => {
  it("sets an identifying user agent on OpenStreetMap tile requests only", () => {
    const onBeforeSendHeaders = vi.fn();
    const electronSession = { webRequest: { onBeforeSendHeaders } } as unknown as Session;
    registerMapTileRequests(electronSession, "1.2.3");

    expect(onBeforeSendHeaders).toHaveBeenCalledTimes(1);
    const [filter, handler] = onBeforeSendHeaders.mock.calls[0];
    expect(filter).toEqual({ urls: [OSM_TILE_URL_FILTER] });
    expect(OSM_TILE_URL_FILTER).toBe("https://tile.openstreetmap.org/*");

    const callback = vi.fn();
    handler(
      { requestHeaders: { "User-Agent": "Mozilla/5.0", Accept: "image/png" } },
      callback,
    );
    expect(callback).toHaveBeenCalledWith({
      requestHeaders: {
        "User-Agent": mapTileUserAgent("1.2.3"),
        Accept: "image/png",
      },
    });
    expect(mapTileUserAgent("1.2.3")).toBe("Replycant/1.2.3 (+https://github.com/mr-andreas/replycant)");
  });
});
