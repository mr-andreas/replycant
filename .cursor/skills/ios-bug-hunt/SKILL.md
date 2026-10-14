---
name: ios-bug-hunt
description: Hunts for user-facing bugs in the iOS app by driving a simulator like an ordinary user (fast gestures, permission changes, server outages, lifecycle interruptions) and appends confirmed bugs to Bugs.md. Use when asked to bug hunt, break the app, or exploratory-test the iOS app.
---

# iOS Bug Hunt

Drive the iOS app the way an ordinary user would and append each
confirmed bug to `Bugs.md`. Do not fix bugs during the hunt.
Recovery, bootstrap, device linking, the AXe binary (`$AXE`), and
screenshot embedding live in the `simulator-testing` skill. Follow
that skill. This skill only adds the hunt.

## Inputs

- How many bugs to find. Default is 3. An optional focus area.
- A recovered library from `RecoveryKeys.md` has real photos. Use it
  for browsing, viewing, and checking that screens agree.
- The bootstrapped library on `replycant-sim-bootstrap` starts empty.
  Use it for anything that writes or disrupts: uploads, stopping the
  server, killing the app mid-sync, and linking a second device.
- With no focus area, start on the recovered library and switch to
  the bootstrapped one for write tests.

## Setup

- Recover or bootstrap with `simulator-testing`. Do not repeat those
  steps here. If the app is already on the right library, rebuild and
  relaunch. Do not uninstall. Both setups need a fresh install to redo.
- Fill a bootstrapped library with synthetic images only:
  `xcrun simctl addmedia <udid> <files>`, then upload. Never add the
  user's real photos.
- Two booted simulators can share a name, and `build_run_sim` may
  launch on the wrong one. After launch, set the session default
  `simulatorId` to the UDID whose `xcrun simctl get_app_container
  <udid> app.ios.replycant.com` succeeds.
- Note the session start time so later crash reports can be told
  apart from older ones.

## Driving the simulator

- `$AXE describe-ui --udid` prints the accessibility tree as JSON.
  `$AXE screenshot --udid --output /tmp/<name>.png` saves a screenshot.
- Prefer `--id` selectors, as `simulator-testing` says. Timeline cells
  are the exception: each exposes two elements with the same
  `timelinePhoto_<id>`. `$AXE tap --id` then fails as ambiguous, and an
  MCP `tap` can report success without opening the photo. Read the cell
  frame from `describe-ui` and tap it with
  `$AXE tap -x <x> -y <y> --tap-style physical`.
- The top grid row starts above the screen (`y` is negative) because it
  sits under the navigation bar. Tap a cell from the second row or lower.
- Put rapid gestures in one `$AXE batch --file` with explicit `sleep`
  steps. A long batch can outlast a 30 second shell wait, so run it in
  the background and wait on it.
- To read on-screen text without a screenshot:

```bash
"$AXE" describe-ui --udid <udid> | python3 -c '
import json,sys
def walk(n):
    if isinstance(n, dict):
        label, ident = n.get("AXLabel") or "", n.get("AXUniqueId") or ""
        if label and "timelinePhoto" not in ident: print(label[:80])
        for v in n.values(): walk(v)
    elif isinstance(n, list):
        for i in n: walk(i)
walk(json.load(sys.stdin))'
```

## Where to look

These are starting points. Also try ideas of your own. Skip anything
already listed in `Bugs.md`.

- Gestures: flick through photos, swipe sideways while details are
  open, dismiss while a photo is loading, double-tap to zoom, and
  swipe away from a playing video.
- Photos permission: `xcrun simctl privacy <udid> revoke photos
  app.ios.replycant.com` kills the running app. Relaunch with
  `launch_app_sim`.
- Server, bootstrapped stack only: `docker compose -p
  replycant-sim-bootstrap stop gitd`, then `start gitd`. Never stop
  the default `replycant` project or a key's `Path:` stack.
  `simctl status_bar` only changes the icon. It does not cut the network.
- Lifecycle: background and foreground the app. Kill it during an
  upload or sync, then relaunch.
- Consistency: the grid, the month sidebar, and the details panel
  should agree. Copy: raw errors, internal identifiers, and
  developer-facing values shown to a user.
- Display: `xcrun simctl ui <udid> content_size` and `appearance`.
- Two devices: link a second simulator with "Linking a second device"
  in `simulator-testing`. Linking commits a device key, so never link
  against a recovered library without asking first. Keep the
  session-default simulator on device A. Drive B with `xcrun simctl`
  and `$AXE --udid <B>`. Try an upload on A appearing on B, changes on
  both at once, stopping gitd while B waits to be linked, and killing
  B partway through linking.
- Rotation needs Simulator.app. Skip it when that app is not open.
  A missing camera and skipped rotation are limits of the tooling,
  not bugs.

## Confirming a bug

Reproduce it at least twice. Check `ps aux | rg "replycant.app/replycant"`,
`~/Library/Logs/DiagnosticReports/replycant-*.ips` newer than the session
start, and the runtime log from `launch_app_sim`. Read the code for a
likely cause. Do not fix it.

## Reporting

Append to `Bugs.md` as soon as a bug is confirmed. Use the next number.
Do not add a `**Status:**` line. The developer adds that when the bug
is fixed.

```markdown
## N. Short title

**Area:** iOS app, <screen>
**Found:** YYYY-MM-DD, simulator, <recovered key heading | bootstrapped> library

**Steps**
1. ...
**Expected**
...
**Actual**
...
**Cause**
...
```

`Bugs.md` is gitignored. A report must not include photo
descriptions, GPS coordinates, device IDs, original filenames, recovery
links, passwords, join payloads, or device-link pairing payloads. Refer
to a recovered library by its key heading only.

Do not commit screenshots. Keep them in `/tmp` or the gitignored
`recordings/` directory. Never capture the device-link QR.

## Cleanup

Restore anything the hunt changed: `xcrun simctl privacy <udid> reset
photos app.ios.replycant.com`, `xcrun simctl ui <udid> content_size
large`, `appearance` back to the value it had at the start, any gitd
container that was stopped, and, when finished, the throwaway stack
using the reset command in `simulator-testing`.

Then report one line per bug, which library was used and whether a
second device was linked, anything that could not be tested, and key
screenshots inline using the image-path rules in `simulator-testing`.
