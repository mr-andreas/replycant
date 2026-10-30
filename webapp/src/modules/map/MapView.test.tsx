import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { TimelineItem } from "../../lib/timeline";
import type { LibraryRuntimeState } from "../library/useLibraryRuntime";
import type { MapPointRow } from "../gitdb";
import { MapView } from "./MapView";

const mapResize = vi.hoisted(() => ({
  invalidateSize: vi.fn(),
}));

vi.mock("leaflet", async () => {
  const { project } = await import("./mapClusters");
  const map = (element: HTMLElement) => {
    const handlers = new Map<string, () => void>();
    const instance = {
      element,
      setView() {
        return instance;
      },
      fitBounds() {
        handlers.get("moveend")?.();
        return instance;
      },
      on(event: string, handler: () => void) {
        handlers.set(event, handler);
        return instance;
      },
      getSize() {
        return { x: 800, y: 600 };
      },
      getBounds() {
        return {
          getNorthWest: () => ({ lat: 70, lng: -20 }),
          getSouthEast: () => ({ lat: 40, lng: 40 }),
        };
      },
      getCenter() {
        return { lat: 59.33, lng: 18.06 };
      },
      getZoom() {
        return 6;
      },
      project(latlng: { lat: number; lng: number }) {
        return project(latlng.lat, latlng.lng);
      },
      invalidateSize() {
        mapResize.invalidateSize();
        return instance;
      },
      remove() {},
    };
    return instance;
  };
  return {
    default: {
      map,
      tileLayer: () => ({ addTo() {} }),
      divIcon: (options: { html: HTMLElement }) => ({ options }),
      marker: (_latlng: unknown, options: { icon: { options: { html: HTMLElement } } }) => {
        const root = document.createElement("div");
        root.appendChild(options.icon.options.html);
        document.body.appendChild(root);
        return {
          addTo() {
            return this;
          },
          setLatLng() {
            return this;
          },
          remove() {
            root.remove();
          },
        };
      },
      latLng: (lat: number, lng: number) => ({ lat, lng }),
      latLngBounds: () => ({}),
    },
  };
});

const snapshot = {
  syncing: false,
  error: null,
  unrecoverableError: null,
  lastSyncAt: null,
  syncedCommitHash: null,
  periodicSyncPaused: false,
  periodicSyncUserEnabled: true,
  syncIntervalMs: 2000,
  isOffHead: false,
  requiresHardResetPermission: false,
  cloneProgress: null,
};

const itemFor = (key: string): TimelineItem => ({
  key,
  dayKey: "2024-01-01",
  monthKey: "2024-01",
  yearKey: "2024",
  timestamp: "2024-01-01T00:00:00.000Z",
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

const renderMap = (points: MapPointRow[]) => {
  const runtime = {
    snapshot,
    manifestRevision: 1,
    loadMapPoints: vi.fn(async () => points),
    loadItemsByKeys: vi.fn(async (keys: string[]) => keys.map(itemFor)),
  } as unknown as LibraryRuntimeState;
  render(
    <MapView
      runtime={runtime}
      mtlsHeaders={null}
      activeView="map"
      onSelectView={vi.fn()}
      commitPaneOpen={false}
      onToggleCommitPane={vi.fn()}
      commitPane={null}
    />,
  );
};

describe("MapView", () => {
  let onMapResize: (() => void) | null = null;

  beforeEach(() => {
    onMapResize = null;
    mapResize.invalidateSize.mockClear();
    vi.stubGlobal("ResizeObserver", class {
      constructor(callback: () => void) {
        onMapResize = callback;
      }

      observe() {}
      unobserve() {}
      disconnect() {}
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("shows an empty state when no photo has a location", async () => {
    renderMap([]);
    expect(await screen.findByText("No photos with location")).toBeInTheDocument();
    expect(screen.getByText("Photos with a location will show up here.")).toBeInTheDocument();
  });

  it("draws one tile per group and opens that group's photos", async () => {
    const points: MapPointRow[] = [
      { key: "older", latitude: 59.33, longitude: 18.06, takenAt: "2024-01-01T00:00:00.000Z" },
      { key: "newer", latitude: 59.331, longitude: 18.061, takenAt: "2024-06-01T00:00:00.000Z" },
    ];
    renderMap(points);

    const tile = await screen.findByRole("button", { name: "2 photos" });
    fireEvent.click(tile);

    expect(await screen.findByRole("heading", { name: "Places" })).toBeInTheDocument();
    expect(screen.getByText("2 Items")).toBeInTheDocument();
  });

  it("returns to the map when Escape is pressed on a place timeline", async () => {
    const points: MapPointRow[] = [
      { key: "older", latitude: 59.33, longitude: 18.06, takenAt: "2024-01-01T00:00:00.000Z" },
      { key: "newer", latitude: 59.331, longitude: 18.061, takenAt: "2024-06-01T00:00:00.000Z" },
    ];
    renderMap(points);

    fireEvent.click(await screen.findByRole("button", { name: "2 photos" }));
    expect(await screen.findByRole("heading", { name: "Places" })).toBeInTheDocument();

    fireEvent.keyDown(window, { key: "Escape" });

    expect(screen.queryByRole("heading", { name: "Places" })).not.toBeInTheDocument();
    expect(await screen.findByRole("button", { name: "2 photos" })).toBeInTheDocument();
  });

  // Hiding the map reports a zero size. Resizing then would move the camera.
  it("does not resize the map when its container has no size", async () => {
    const points: MapPointRow[] = [
      { key: "older", latitude: 59.33, longitude: 18.06, takenAt: "2024-01-01T00:00:00.000Z" },
      { key: "newer", latitude: 59.331, longitude: 18.061, takenAt: "2024-06-01T00:00:00.000Z" },
    ];
    renderMap(points);
    await screen.findByRole("button", { name: "2 photos" });

    const canvas = document.querySelector(".map-canvas");
    expect(canvas).toBeInstanceOf(HTMLElement);
    Object.defineProperty(canvas, "clientWidth", { configurable: true, value: 0 });
    Object.defineProperty(canvas, "clientHeight", { configurable: true, value: 0 });
    mapResize.invalidateSize.mockClear();
    onMapResize?.();

    expect(mapResize.invalidateSize).not.toHaveBeenCalled();
  });
});
