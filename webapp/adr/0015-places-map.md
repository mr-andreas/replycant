# 0015 — Places map

**Status:** Accepted

## Context

The iOS app groups geotagged photos into place tiles (ADR-0031 and ADR-0032 in the iOS app). The desktop app had no map. Original manifests already store `spec.location`, but the timeline normalizes that away, and paging originals by capture time cannot load every coordinate at once.

Leaflet can draw the map. Its marker clustering, like MapKit's, needs one marker per photo, which does not scale to a full library and does not produce a stable box the timeline can query.

OpenStreetMap's public raster tiles need no API key. The tile usage policy allows interactive viewing of the current viewport, requires a visible attribution and an identifying User-Agent from an app, and forbids prefetching and offline packs. There is no availability guarantee, so the tile URL stays in one config field. The public Nominatim geocoder is not usable by a distributed app.

## Decision

A `map_points` derived store keeps `{ key, latitude, longitude, takenAt }` for originals that have numeric coordinates and a capture time. The IndexedDB schema version bumps so the new store is created; the local cache is wiped and rebuilt from git, which is how this database already treats schema changes.

The map is Leaflet on `https://tile.openstreetmap.org/{z}/{x}/{y}.png`. The Electron shell sets `User-Agent: Replycant/<version> (+https://github.com/mr-andreas/replycant)` on requests to that host. Tiles do not wrap, and the view cannot pan past one copy of the world, so a rectangle never crosses the antimeridian.

Clustering is a port of the iOS grid: power-of-two cells in zoom-0 world pixels, a tile anchored on the newest photo, and the place grid filtered to that tile's tight latitude/longitude box. The place screen reuses the timeline and the full-screen viewer. It does not read or write the library timeline's scroll anchor. The title is "Places".

## Consequences

- Opening the map reads the coordinate rows instead of every original manifest.
- The first launch after this change rebuilds the local index.
- Place counts match the grid, because both ignore photos that have no capture time and both use the members' bounds.
- A shipped app depends on the public tile servers staying available. Changing `mapTileUrl` retargets the imagery; the User-Agent filter stays on the OpenStreetMap host.
- Reverse geocoding is absent. The place screen does not send coordinates off the device.
