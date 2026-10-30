---
sidebar_position: 2
---

# Map

The map shows geotagged photos as place tiles on an OpenStreetMap base map. Choosing a tile opens the timeline for just that place.

## Places

Each original manifest may store a `location` with a latitude and longitude. The sync cache keeps a `map_points` row per original that has both a location and a capture time, so the map can load every coordinate without reading the manifests.

Tiles are not one marker per photo. Photos are grouped into cells of a fixed world grid. The cell size is a power-of-two slice of the world, about three tiles wide on screen, whatever the window size. Panning shows or hides whole groups. A pinch or scroll scales the map already on screen, and sharper tiles load after the gesture. A group splits only after that scale crosses a power-of-two step, into the four smaller cells it contains. Each tile shows the newest photo in its cell, the count of photos, and a pointer sitting on that photo's coordinate.

## A place

The box on a tile is the tight latitude and longitude range of its photos. The place screen is the same timeline grid, month sidebar, and full-screen viewer as the library, limited to photos inside that box. The title is **Places**. Naming the place would send the coordinate to a geocoder, and the public OpenStreetMap geocoder is not available to a distributed app. Press Escape to leave the place and return to the map. While a photo is open, Escape closes the photo first.

## Tiles

The base map is the OpenStreetMap standard style. The app requests tiles for the area on screen and shows the OpenStreetMap attribution on the map. It does not download a region for offline use.

See [Timeline](./timeline.md) for how the grid pages and how the month sidebar jumps.
