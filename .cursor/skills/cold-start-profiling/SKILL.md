---
name: cold-start-profiling
description: >-
  Profiles the iOS app cold start through the first painted timeline grid.
  Covers a Release install, turning simulator accessibility off, the
  uninstrumented FrontBoard clock, os_signpost traces, and when a Time
  Profiler trace is worth taking. Use when asked to profile cold start,
  launch time, time to first frame, time to first screen, or how long
  the timeline takes to appear.
---

# Cold Start Profiling

Measure a cold start of the iOS app: the process is not running, a
library is already on disk, and the first screen is the timeline grid
with its visible thumbnails painted.

Quote two clocks, and never add them together. They do not share an
origin.

- The headline time to first scene comes from an uninstrumented
  `simctl launch` and the FrontBoard log.
- The in-app breakdown comes from an `os_signpost` trace, measured from
  `AppInit`.

A Time Profiler trace explains a gap. Its durations are not the launch
time. Instruments loads a dyld monitor that makes pre-main and library
loading look much slower than an ordinary launch.

## What counts as a cold start

A steady launch of a Release build that opens the timeline. The first
launch after install is a warmup: run it, terminate, then measure.
Onboarding, "Local data was reset", or a missing
`TimelineVisibleViewportHydrated` signpost means the run is not a
timeline cold start.

Take three launches for each clock. Report every run. When one run is
far slower than the other two, say so and treat the other two as the
typical time.

## Before launching

1. The simulator needs a library that opens on the timeline. Follow
   `simulator-testing` to recover one. If the screen is onboarding or
   "Local data was reset", recover again. The iOS unit suite deletes
   `Documents/replycant-git-db` on the simulator it runs against, so
   do not run it on this simulator during a profile.
2. Use the booted simulator. If more than one is booted, use the UDID
   whose `xcrun simctl get_app_container <udid> app.ios.replycant.com`
   succeeds.
3. Read the XcodeBuildMCP session defaults and remember the
   configuration. Build and install scheme `iosapp` from
   `iosapp/iosapp.xcodeproj` as Release. Restore the previous
   configuration before finishing, including when a later step fails.
4. Launch with `simctl` or `xctrace --launch`. Leave the Xcode
   debugger detached.
5. Put traces under `/tmp`. Do not write them into the repo.

## Turn accessibility off

UI automation turns on `com.apple.Accessibility` in the simulator.
While it is on, launch loads on the order of a hundred accessibility
bundles and the time to first scene is hundreds of milliseconds
slower. Read both keys, turn them off, and read them back. Measure
only after both read back as false.

```bash
UDID=<booted-udid>
xcrun simctl spawn "$UDID" defaults read com.apple.Accessibility ApplicationAccessibilityEnabled
xcrun simctl spawn "$UDID" defaults read com.apple.Accessibility AccessibilityEnabled
xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool false
xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility AccessibilityEnabled -bool false
```

This writes the simulator's accessibility domain, which is what
UI automation reads. Restore the saved values before finishing, even
if the profile fails or is interrupted. A later `defaultsAreEnabled`
test failure is a different leak: that one is an app-domain
`defaults write`, not this domain.

After any trace that has a dyld table, export it and run the checker
below. Discard the run when the checker reports accessibility bundles.

## Uninstrumented clock

Terminate, wait two seconds, and launch. One warmup launch after the
install, then three measured launches. Wait two seconds after each
launch before reading the log. Record the host time before `simctl
launch`, then read the simulator log. `log show` on the host does not
see the simulator.

```bash
BUNDLE=app.ios.replycant.com
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 2
START=$(python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))')
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
sleep 2
xcrun simctl spawn "$UDID" log show --start "$START" --style compact \
  --predicate 'subsystem == "com.apple.FrontBoard" AND eventMessage CONTAINS[c] "replycant"'
```

From the first "Creating process" line, report:

| Log line | Meaning |
|---|---|
| Bootstrap success | Process is up |
| content state changed: ready | First scene. This is the headline |
| Dropping launch assertion | Launch assertion released, after the first scene |

`simctl launch --stdout` and `--stderr` paths are inside the simulator
data directory, so they do not capture the log you want.
`DYLD_PRINT_STATISTICS` produces nothing useful here.

## Signpost breakdown

App signposts use subsystem `com.replycant.app`, category
`PointsOfInterest`, from `AppSignposts` in
`iosapp/iosapp/Managers/Logger.swift`. GitDB uses
`com.replycant.gitdb` and libgit2 uses `com.replycant.libgit2`. The
same trace also contains Apple's `ApplicationFirstFramePresentation`,
`AppLaunch`, and main-thread `Commit` intervals.

Record three launches with the signpost instrument alone. A non-zero
`xctrace` exit is fine when the `.trace` exists and export succeeds.
`--time-limit 8s` covers a timeline launch.

```bash
APP=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" app)
OUT=/tmp/replycant-coldstart
mkdir -p "$OUT"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
sleep 2
rm -rf "$OUT/sign1.trace"
xcrun xctrace record \
  --instrument "os_signpost" \
  --device "$UDID" \
  --time-limit 8s \
  --output "$OUT/sign1.trace" \
  --launch -- "$APP"
xcrun xctrace export \
  --input "$OUT/sign1.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
  --output "$OUT/sign1-events.xml"
python3 .cursor/skills/cold-start-profiling/scripts/summarize_trace.py \
  signposts "$OUT/sign1-events.xml"
```

Run the script. Do not parse the XML by hand. Times it prints are
milliseconds from `AppInit` begin. A milestone printed as one number
is an instant, or an interval whose begin fell outside the trace.
`ApplicationFirstFramePresentation` is usually the second kind: that
number is when the first frame was presented.

The script warns when onboarding showed or the grid never finished
painting. Those runs are not timeline cold starts.

## Time Profiler, only to explain a gap

Take one Time Profiler trace when the signposts leave a gap you
cannot name. Window samples by the signposts in the same trace.

```bash
xcrun xctrace record \
  --template "Time Profiler" \
  --instrument "os_signpost" \
  --device "$UDID" \
  --time-limit 8s \
  --output "$OUT/profile.trace" \
  --launch -- "$APP"
xcrun xctrace export --input "$OUT/profile.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output "$OUT/profile-tp.xml"
xcrun xctrace export --input "$OUT/profile.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="dyld-activity-interval"]' \
  --output "$OUT/profile-dyld.xml"
python3 .cursor/skills/cold-start-profiling/scripts/summarize_trace.py \
  dyld "$OUT/profile-dyld.xml"
```

Discard the trace when the dyld checker finds `AccessibilityBundles`.

When you parse `time-profile` yourself:

- Shared nodes are `ref` attributes. Follow `ref` to the element with
  that `id` before reading it.
- An ElementTree element is falsy when it has no children, including
  when its text is the value. Test `is None`.
- Backtraces are `tagged-backtrace`. A frame's name is an attribute.
  The binary is a child element with a `name` attribute.
- Sample weights are the sample period. A sum of weights inside a
  window is time sampled under Instruments, not the launch time.

## How to read the numbers

The long main-thread `Commit` that ends at
`ApplicationFirstFramePresentation` is the first frame. Most of it is
SwiftUI and the Swift runtime resolving types. Attribute it to app
code only for samples whose deepest app frame is app code.

`TimelineThumbnailDecode` wraps `UIImage(data:)`, which does not
decode pixels. A short decode interval can sit next to a later
main-thread `Commit` spent in AppleJPEG and ImageIO. That commit is
the decode.

`ContentInitializeRepositoryState` starts from a `.task`, so it starts
after the first frame. Time before `TimelineLoadMetadata` is further
main-thread `.task` work. Check `refreshRecoveryWarning` and the first
libgit2 call, which pays `git_fs_path_iconv_init_precompose` on that
thread.

State in the report that the numbers are from the simulator. A
simulator launch time is not a device launch time.

## Report

```markdown
## Cold start

Release, simulator, accessibility off, debugger detached.
Headline times are the uninstrumented FrontBoard log, from
"Creating process". Signpost times are from AppInit and use a
different origin.

### Time to first scene

| Run | Bootstrap | Scene ready | Assertion dropped |
| --- | --- | --- | --- |
| 1 | | | |
| 2 | | | |
| 3 | | | |

Typical scene ready: <the steady runs>. <Name any run excluded as warmup or an outlier, and why.>

### In-app steps, from AppInit

| Step | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| AppInit | | | |
| MainTabsVisible | | | |
| First frame commit | | | |
| Repository init | | | |
| Timeline metadata ready | | | |
| Grid first layout | | | |
| First thumbnail | | | |
| Viewport painted | | | |

### Gaps

<Only when a Time Profiler trace was taken. Label every duration as sampled under Instruments.>
```

## Restore

Before you report:

- Write back both accessibility keys to the values you read.
- Restore the XcodeBuildMCP configuration you found at the start.
- Terminate the app.
