---
name: simulator-recovery-testing
description: Test the iOS app in a simulator by recovering from a key in RecoveryKeys.md; covers the fresh-install requirement, the recovery deep link flow, and recording a video walkthrough of a feature under test.
---

# Simulator Recovery Testing

Use this skill to recover the iOS app in a simulator from a key in the
gitignored `RecoveryKeys.md` at the repo root. Recovery is the way to load
real data into a simulator for development.

Read this skill before building or launching the iOS app against real data.
A request like "run the app in the simulator" still needs this flow when
the goal is a recovered library rather than the empty onboarding path.

## Inputs

- Which key from `RecoveryKeys.md` to use. Pick the one whose description
  matches the scenario under test. Ask the user when more than one key
  could apply.
- File format is documented in
  `.cursor/skills/simulator-recovery-testing/RecoveryKeys.example.md`.
  One `## heading` per key, then `Description`, `Server`, `Path`,
  `Password`, and `Link`.

If `RecoveryKeys.md` is missing, point at `RecoveryKeys.example.md` and
stop. Do not invent keys.

## Secrecy

`RecoveryKeys.md` holds live recovery bundles and passwords. Never echo a
link, payload, or password into chat, commit messages, `CHANGELOG.md`, or
`MISTAKES.md`. Refer to keys by their heading and description only.

## Preconditions

Stop if any check fails, and say what to fix.

1. Bundled simulator credentials must not be present. If either
   `iosapp/Resources/SimulatorCredentials/` or
   `iosapp/iosapp/Resources/SimulatorCredentials/` exists, move it aside.
   `SimulatorAutoConnectManager` imports those credentials at launch and
   recovery is then rejected as already configured.
2. Confirm the key's `Server:` is reachable, for example
   `curl -sf <server>/ca`. If it is down and the key has a local `Path:`,
   bring that stack up as described below. If the key is remote, report
   that the server is unreachable and stop.
3. Use the already booted simulator. If none is booted, boot
   `iPhone 17 Pro Max` to match `IOS_TEST_DESTINATION` in the Makefile.

## Recovery workflow

Recovery only runs on a fresh install.
`RecoveryKeyManager.shouldRejectRecovery` rejects the flow when a server
is already configured or a local repo exists, and the app lands on
"Recovery Blocked". Every run therefore starts with uninstall.

1. Read `RecoveryKeys.md` and select the key.
2. Confirm the preconditions above.
3. Uninstall for a fresh install:
   - `xcrun simctl uninstall <udid> app.ios.replycant.com`
4. Build, install, and launch scheme `iosapp` from
   `iosapp/iosapp.xcodeproj` via XcodeBuildMCP. Session defaults should
   already match that project, scheme, and simulator.
5. With the app running, open the recovery deep link:
   - `xcrun simctl openurl <udid> '<link>'`
   The app presents `RecoveryView` as a sheet on the password step.
6. Drive the password step with XcodeBuildMCP UI automation:
   - `snapshot_ui`
   - tap the `Recovery password` secure field
   - `type-text` the password from the selected key
   - tap `Recover`
7. Verify the outcome by screenshot against
   `RecoveryView.RecoveryStep.title`:
   - `Recovery Complete` is success.
   - `Recovery Key Rejected` means the key was deleted server-side
     (the 401 path). That is the expected result for a revoked-key
     fixture, not a workflow failure.
   - `Recovery Blocked` means the install was not fresh. Return to
     step 3.
   - `Error` means recovery failed. Report the on-screen message and
     stop.
8. On the completion screen choose `Continue`. Never choose
   `Revoke used key`. Revoking deletes the key from the server and
   makes that entry in `RecoveryKeys.md` dead.

QR images are not supported. The simulator has no camera, and the share
text always includes the deep link.

## Recording a feature walkthrough

Record after recovery reaches the timeline, when the run exists to try
out a new or changed feature. Plain recovery runs with no feature to
show do not need a recording.

Write files to `recordings/<YYYYMMDD-HHMMSS>-<feature-slug>.mp4` at the
repo root. Create the directory if it is missing. It is gitignored.

Agent inference between UI tool calls is several seconds. Driving a
walkthrough one tap at a time therefore fills the clip with dead air.
Script the interactions into one AXe batch so pauses are explicit
`sleep` steps, not round-trip latency.

The MCP `batch` tool is tap-only and same-screen. Use the bundled AXe
binary instead, at
`~/.npm/_npx/*/node_modules/xcodebuildmcp/bundled/axe`. Resolve the
path once per session. Do not commit a wrapper.

### 1. Rehearse off camera

Walk the feature with `snapshot_ui` / `wait_for_ui` and collect a
stable selector for every step. Prefer `--id`, then `--label` narrowed
by `--element-type` (`Button`, `TextField`, `Switch`). That
disambiguation is what avoids "Multiple accessibility elements
matched" and the brittle `-x -y` fallback.

Return the app to the walkthrough's starting state. All exploration
and failed selector attempts stay off camera.

### 2. Record one batch

Write the rehearsed steps to a temp file. Do not commit it.

```
tap --label "Recovery Key" --element-type Button
sleep 1
tap --label "Delete" --element-type Button
sleep 1.5
```

`sleep 0.8`–`1.5` is enough to read a screen. Use `sleep 2` after a
transition that animates. Those are the only pauses the clip should
contain.

Start the recorder, run the batch, and stop the recorder in one
shell so agent round trips never land in the clip. Use an absolute
output path; a relative `recordings/` path can resolve to `$HOME`.
Do not call `screenshot`, `wait_for_ui`, or `snapshot_ui` while
the recorder is running.

```bash
OUT="$(pwd)/recordings/<YYYYMMDD-HHMMSS>-<feature-slug>.mp4"
"$AXE" record-video --udid <udid> --fps 30 --output "$OUT" &
REC=$!
sleep 0.3
"$AXE" batch --udid <udid> --file /tmp/walkthrough.steps \
  --ax-cache perStep --wait-timeout 5
kill -INT "$REC"
wait "$REC"
```

`--ax-cache perStep` refreshes the accessibility tree between steps.
`--wait-timeout 5` lets a later step poll across a screen transition.

If AXe `record-video` is unavailable, `record_sim_video` start/stop
works but each MCP hop adds a few seconds of lead-in or tail.

Confirm the MP4 exists and is non-empty before reporting it. Stop as
soon as the walkthrough ends rather than leaving it running through a
long sync.

### 3. Extract stills from the MP4

Do not take screenshots during the recording. Pull key frames after
it stops:

```bash
ffmpeg -i recordings/<name>.mp4 -vf "select='gt(scene,0.08)'" \
  -vsync vfr recordings/<name>-%02d.png
```

If scene detection misses a subtle change, extract that frame by
timestamp instead (`ffmpeg -ss <t> -i ... -frames:v 1`).

### Branching walkthroughs

A walkthrough that must read a value and then decide can still be
driven step by step. Split it so each scripted stretch is one batch
and only the decision points cost a round trip.

A recovered library shows the user's real photos. Recordings stay in
the gitignored directory. Never commit them, attach them to a commit
message, or copy them into docs.

## Server and Path

The discovery URL and pinned CA hash are sealed inside the encrypted
bundle, so they cannot be read without the password. `Server:` is the
discovery URL the app will contact. `Path:` is the local clone whose
`replycant-data` holds that server's bare repo and CA. Several test
servers can coexist as separate checkouts. Remote keys record `Server:`
only and leave `Path:` as `(remote, no local checkout)`.

### Bringing a stack up

Run `docker-compose.yaml` from the key's `Path:`. Compose volumes
resolve `./replycant-data` and `./replycant-lfs` relative to that
directory:

```bash
cd <Path> && docker compose up -d --build
```

### Live-patching gitd

To test a change that spans gitd and the client, serve the key's dataset
from the workspace build instead of copying working-tree changes into
the test clone. Override the two data paths so gitd is compiled from the
code under edit:

```bash
REPLYCANT_DATA_DIR=<Path>/replycant-data \
REPLYCANT_LFS_DIR=<Path>/replycant-lfs \
docker compose up -d --build gitd
```

Run that from the repo root. The recovered simulator stays pointed at
the same CA and repo while iterating on `server/gitd`.

### Port collisions

Discovery/CA is `${REPLYCANT_CA_PORT:-8080}` and git is
`${REPLYCANT_GIT_PORT:-8443}`. Only one stack can use the defaults at a
time. Additional servers need distinct `REPLYCANT_CA_PORT` and
`REPLYCANT_GIT_PORT` values that match the port in their `Server:` line.
Stop the other stack or fail loudly rather than guessing.

### CA wipe

Deleting a clone's `replycant-data` regenerates the CA.
`RecoveryKeyManager.recover` pins `caSHA256` during discovery, so every
recovery key issued by that stack dies permanently. Rebuild containers.
Do not wipe the data directory unless the keys are expendable.

## Absolute restrictions

- Never echo a recovery link, payload, or password
- Never tap `Revoke used key`
- Never wipe a key's `replycant-data` as part of bringing the stack up
- Never write `RecoveryKeys.md` or `recordings/` into git

## Final output to user

Report:

- Which key heading was used (not the link or password)
- Whether recovery completed, was rejected as revoked, or failed
- Whether the local stack was started or live-patched
- The path to the walkthrough MP4, when one was recorded
- Key frames embedded inline as `![step](recordings/<name>-NN.png)`,
  since chat cannot play video
