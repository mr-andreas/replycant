# ADR-0031: Places Map

## Status

Accepted

## Context

Geotagged media already stores `spec.location` on each Original, but the coordinate lives only inside the manifest JSON. The timeline can show a library of this size because it pages one contiguous range. A map needs every coordinate at once, and a tapped place needs the same grid limited to that place.

MapKit can cluster annotations, but that requires one annotation per photo. That does not scale to a library of tens of thousands of photos, and the clusters it produces are not a stable box the timeline can query.

Naming a place uses Apple's reverse geocoder, which sends the cluster's coordinate off the device.

## Decision

Original manifests project nullable `latitude` and `longitude` columns. The schema version from ADR-0030 bumps with them, so an existing cache is erased and rebuilt from git.

The map loads those columns, without decoding manifests, and clusters on device. Cells are power-of-two slices of the world, chosen from the zoom so each one is large enough that a phone shows only a handful, and a tile is drawn inside its cell so neighbors cannot overlap. Each group is built from every photo in its cell, and the view only chooses which cells to draw, so panning shows or hides whole groups. Zooming across a step splits each group into the four smaller cells it contains. Each tile shows the newest photo and the count of members.

A tile is the members' tight lat/lon box, not a list of ids. The place screen is the timeline grid with that box added to the existing SQL predicate, so paging, the month sidebar, and the full-screen viewer stay inside the place. The title is the reverse-geocoded locality of the cluster center, or "Places" when geocoding is unavailable.

## Consequences

### Positive

- The place grid reuses the timeline, including live updates from sync.
- Clustering stays cheap because it never decodes a manifest.
- The count on a tile matches the grid, because both use the members' bounds.

### Negative

- Reverse geocoding sends one coordinate to Apple each time a place is opened.
- A box that crossed the 180th meridian would not be a tight SQL range. Cells are in map points, which split at that edge, so a tile does not span it.
- The first launch after this change rebuilds the local index.
