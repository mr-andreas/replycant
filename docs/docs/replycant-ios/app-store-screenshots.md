# App Store Screenshots

This flow generates iPhone and iPad timeline and map screenshots for App Store
Connect from a repeatable simulator run, then uploads them with App Store
Connect API keys.

## Source Media

- Raw personal photos stay in a temporary local folder (`demoimages/`) and are
  never committed.
- Sanitized demo photos are committed under `iosapp/iosapp/ScreenshotMedia/` as
  `demo-01.jpg`, `demo-02.jpg`, and so on.
- Sanitization strips EXIF/GPS/device metadata and rewrites names so capture
  dates are not leaked through filenames.

## Screenshot Capture Architecture

The screenshot flow uses the existing UI-test fixture stack:

1. Launch app with `--uitesting --screenshots`.
2. `TestSupport` builds an encrypted local fixture repo and local LFS server.
3. `TestSupport` seeds photo fixtures from `ScreenshotMedia/`. Each fixture
   manifest gets one of a few Stockholm landmark coordinates, so the map has
   place tiles. The demo JPEGs themselves carry no GPS.
4. `ScreenshotUITests` captures the timeline grid (`01-timeline`), then the
   Map tab (`02-map`).
5. Fastlane `snapshot` runs that test on iPhone 17 Pro (6.3", 1206×2622),
   iPhone 17 Pro Max (6.9", 1320×2868), and iPad Pro 13-inch (M5) / iOS
   26.2 (fails if that runtime/device is missing; no fallback to older
   iOS). The two iPhone sizes match the Dynamic Island medium and large
   display slots in App Store Connect.

The `iosappScreenshots` scheme isolates screenshot tests from unit tests.

## Safety Guardrails

- Screenshot media is excluded from `iphoneos` builds:
  `EXCLUDED_SOURCE_FILE_NAMES[sdk=iphoneos*] = ScreenshotMedia`.
- The exclusion targets the folder reference itself. Xcode copies folder
  references as a unit, so per-file globs under that folder do not apply.
- Release builds verify the archive payload excludes `ScreenshotMedia` before
  uploading to TestFlight.
- `ScreenshotMediaTests` verify the same `iosapp/iosapp/ScreenshotMedia/`
  files used by fixture seeding do not include EXIF/GPS metadata and keep
  expected thumbnail dimensions.

## Local Commands

From repository root:

```bash
make ios-screenshots
```

Captures screenshots via Fastlane `snapshot`, frames them with `frameit`
(device bezel, background, and title from `Framefile.json`), and collects
that framed preview under `iosapp/fastlane/screenshots/framed/en-US/`. Also
builds a README-specific black-device frame (no slogan, transparent
background) under `iosapp/fastlane/screenshots/framed/readme/`. Requires the
`iosapp/Gemfile` fastlane pin (`make ios-bundle`) so frameit recognizes
iPhone 17 sizes.

The App Store listing uses the raw captures in
`iosapp/fastlane/screenshots/en-US/`. Within each device size,
`01-timeline` is the first image and `02-map` is the second. Framing stays
on the README images.

```bash
make readme-screenshots
```

Regenerates README product screenshots under `docs/static/img/readme/`: the
framed iPhone timeline, the Electron desktop timeline, and the combined
`apps.png` hero used in the root README.

```bash
make ios-screenshots-upload
```

Uploads the raw captures to the editable App Store Connect version
(requires `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH`). The timeline
is uploaded first and the map second.

```bash
make ios-metadata-upload
```

Uploads listing metadata from `iosapp/fastlane/metadata` (also requires
`ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH`).

## CI Workflow

`.github/workflows/ios-screenshots.yml` (`workflow_dispatch`) captures
screenshots and uploads the raw and framed images as artifacts. With
`upload_to_app_store=true` it uploads the raw captures to the editable App
Store version.

`.github/workflows/ios-app-store-draft.yml` runs after **iOS TestFlight
Release** succeeds for a release tag. It checks out that tag, captures
unframed screenshots, and leaves the uploaded build on a version in
**Prepare for Submission**. The timeline is the first image and the map is
the second. It does not submit for review. A manual TestFlight run does
not start a draft. The workflow file has to be on the default branch
before a tag push will start it.

## App Store Submission Process

1. Push a `vX.Y.Z` tag. The TestFlight workflow uploads the build.
   - Local `make ios-release` also uploads a build. It does not open the
     draft. Create `iosapp/Signing.local.xcconfig` with
     `DEVELOPMENT_TEAM = <your_team_id>` first.
   - CI prereq: set the `APPLE_TEAM_ID` secret.
2. The draft workflow attaches that build and uploads the unframed
   screenshots onto the new version.
3. Run `make ios-metadata-upload` (or the screenshot workflow with
   `upload_metadata=true`) when the draft should use the listing text from
   `iosapp/fastlane/metadata`.
4. Complete App Store Connect fields that are still manual: app privacy
   questionnaire, age rating questionnaire, export-compliance answers, pricing
   and availability, DSA/trader status, final reviewer contact/credentials,
   and reviewer notes (paste from `iosapp/fastlane/review_notes.txt`).
5. Review the draft in App Store Connect, then submit for review manually.

## Submission behavior notes

- The draft workflow, `upload_screenshots`, and `upload_metadata` do not
  submit for review. `deliver` keeps `submit_for_review` at its default
  (`false`) unless set.
- App Store uploads use the raw `en-US` captures. For each device size,
  `01-timeline` is first and `02-map` is second. Framed images stay on the
  README.
- `upload_screenshots` uses `overwrite_screenshots: true`, so each upload
  replaces existing screenshots in the editable version.
- `upload_metadata` intentionally does not write App Store review detail.
  Apple requires all reviewer contact fields when review info is patched.
- Both lanes use `force: true`, so they skip the local HTML preview prompt and
  upload directly to App Store Connect.

## Release-channel decision

Replycant is currently documented as alpha in the root `README.md`. Use
TestFlight for wider validation first if App Store positioning as an alpha
product becomes a review risk.
