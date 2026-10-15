# ADR-0032: Exact Map Tile Anchor

## Status

Accepted. Supersedes the tile-placement rule in ADR-0031.

## Context

ADR-0031 draws each place tile inside its grid cell, at the average of its photos and pushed away from the cell edge, so neighboring tiles cannot overlap. The grid is rebuilt at every power-of-two zoom step, so that push changes and the tile jumps. Neither the average nor the pushed position is a place where a photo was taken.

Apple Photos pins a group to one exact coordinate and draws a pointer from the tile down to that spot. The spot does not move as the map zooms.

## Decision

A tile is anchored at the coordinate of the photo it shows, which is the newest photo in the cell. The annotation's bottom edge, a pointer under the tile, sits on that coordinate.

Tiles near a cell edge may overlap. Keeping the pin exact matters more than keeping a gap, and merging overlapping neighbors would make groups change in less predictable ways when the zoom crosses a step.

## Consequences

### Positive

- A tile stays on the spot its photo was taken, including when its group splits or merges.
- The pointer shows which spot the tile belongs to.

### Negative

- Two tiles on either side of a cell edge can draw on top of each other, so a dense area can be harder to pinch.
