# ADR-0034: Background upload while charging

## Status

Superseded by ADR-0035.

The charging task, smallest-first ordering, and the 7-day reminder below
still apply. ADR-0035 replaces the Upload tab, the manual Start Upload
action, and where the reminder opens.

## Context

Photo upload runs only while the app is open and the user taps Start Upload.
A full library can take longer than a person wants to leave the app open, and
a processing task is limited to several minutes. A large video can miss that
window and would otherwise retry from the start every night.

The upload must not use mobile data. iOS cannot be told to wait for Wi-Fi,
and a background run cannot show the existing mobile-data confirmation.

## Decision

An Upload-tab toggle, off by default, schedules a `BGProcessingTask` that
requires external power and network connectivity. When the task runs, it
uploads only if photo access is already granted and the path is satisfied,
not expensive, and not constrained. It uploads the smallest known files
first, through the existing sync, then pushes.

The manual Start Upload stays newest-first.

Turning the toggle on schedules one reminder 7 days out. Every upload that
finishes everything, whether it ran in the background or from Start Upload,
moves that reminder 7 days out again. The background task never schedules
it, so the reminder still arrives when iOS never runs the task. Turning
the toggle off removes it. Before iOS asks for notification permission,
the app explains the reminder. Not Now never shows the system prompt and
never schedules the notification. The Upload tab still shows the warning
after 7 days. Tapping the notification opens that tab.

## Consequences

### Positive

- Photos and videos upload while the phone is charging, without the app
  being left open.
- A short run finishes small files instead of spending the whole window on
  one video.
- A library that is still unfinished after a week tells the user to finish
  it in the foreground.

### Negative

- iOS chooses when the task runs, and it does not run after a force quit,
  with Background App Refresh off, or in Low Power Mode.
- A file that does not finish in one run is abandoned and starts over next
  time. A video larger than the window never completes in the background.
- The file size used for ordering is Photos metadata read through the
  resource's `fileSize` value, because Photos has no public size API. A
  missing size sorts last.
