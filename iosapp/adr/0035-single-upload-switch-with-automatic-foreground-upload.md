# ADR-0035: One upload switch, started from the timeline

## Status

Accepted. Supersedes the Upload-tab parts of ADR-0034. Charging runs,
smallest-first ordering, the 7-day reminder, and refusing mobile data
for a background run still follow ADR-0034.

## Context

Upload lived on its own tab. A person had to open that tab and tap
Start Upload, and the background switch was easy to miss. Scanning the
photo library at launch would also delay the first screen.

## Decision

One switch, off by default, stored as the existing background-upload
flag. Turning it on requests photo access, asks whether to be notified
if uploads stall, then uploads. Yes requests notification permission
only when iOS has not asked before. No never shows that prompt.

The switch is offered on a dismissible banner at the top of a
non-empty timeline, on the empty timeline, and in Settings. Dismissing
the banner tells the user that upload can be turned on in Settings.

While the switch is on, a foreground launch starts an upload after the
timeline's first load, newest first, and only on an unmetered network.
Becoming active again, or returning to Wi-Fi, starts another run when
one is not already going. The screen stays awake during that run.

A progress control on the timeline opens the run's details. The Upload
page in Settings holds the switch, the stall notification, and the
charging-run list. The Upload tab is gone. Tapping the stall
notification opens the timeline.

A UI-test launch does not auto-start an upload.

## Consequences

### Positive

- Upload is available where the photos are, and it starts on its own
  after the user opts in.
- The first screen is not delayed by a library scan.
- Photo access and the notification question happen while the app is
  open, which a charging run cannot do.

### Negative

- There is no separate upload-once action. Turning the switch off is
  how a run is stopped.
- A large upload still keeps the screen awake while the app is open.
- Automatic runs wait for Wi-Fi. They do not ask to use mobile data.
