# ADR-0036: Charging wake pulls, then warms the top cache while uploading

## Status

Accepted. Supersedes the charging-run sequence in ADR-0034, which
uploaded and then pushed. ADR-0035's switch, foreground upload, and
reminder are unchanged. Smallest-first ordering, the unmetered-network
gate, and the 7-day reminder still follow ADR-0034 and ADR-0035.

## Context

A charging run uploads photos and videos, then pushes. It does not
fetch what other devices have added. The newest thumbnails are warmed
only while the timeline is on screen, so opening the app after a night
on the charger still waits on the network for the first screen.

The processing window is a few minutes. Fetching, warming, and
uploading one after another would spend that window on the first step.

## Decision

After the existing gates and tailnet join, the charging wake fetches
and rebases onto upstream and refreshes the SQL manifest cache. When
that attempt has finished, it warms the top thumbnail cache and uploads
at the same time. It pushes as soon as the upload returns, and it keeps
the task open until warming finishes so iOS does not suspend those
downloads.

A failed fetch still uploads the library already on the phone. An
incompatible database or a format-transition refusal does not warm or
upload. Expiration during the fetch starts neither. If the app is
active and already uploading, the wake still leaves that run alone.

The top cache is the newest thumbnails, the same set the open timeline
warms. The wake does not warm the larger main cache.

## Consequences

### Positive

- The phone has other devices' new photos before the next time the app
  is opened.
- The first screen can render those thumbnails from disk.
- Upload still uses the charging window, sharing it with the thumbnail
  downloads instead of waiting for them.

### Negative

- A large fetch or a long thumbnail warm leaves less of the window for
  uploads.
- A fetch that fails leaves the top cache on the library the phone
  already had.
- Warming and uploading share the network, so each is slower than if it
  ran by itself.
