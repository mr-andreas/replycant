# App Store Screenshots

This flow generates an iPhone timeline screenshot for App Store Connect from a
repeatable simulator run, then uploads it with App Store Connect API keys.

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
3. `TestSupport` seeds photo fixtures from `ScreenshotMedia/`.
4. `ScreenshotUITests` captures the timeline grid screenshot.
5. Fastlane `snapshot` runs that test on iPhone 17 Pro Max (6.9") and
   iPad Pro 13-inch (M5) / iOS 26.2 (fails if that runtime/device is
   missing; no fallback to older iOS).

The `iosappScreenshots` scheme isolates screenshot tests from unit tests.

## Safety Guardrails

- Screenshot media is excluded from `iphoneos` builds:
  `EXCLUDED_SOURCE_FILE_NAMES[sdk=iphoneos*] = ScreenshotMedia/*`.
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

Captures and frames screenshots via Fastlane.

```bash
make ios-screenshots-upload
```

Uploads screenshots to App Store Connect (requires `ASC_KEY_ID`,
`ASC_ISSUER_ID`, and `ASC_KEY_PATH`).

```bash
make ios-metadata-upload
```

Uploads listing metadata from `iosapp/fastlane/metadata` (also requires
`ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH`).

## CI Workflow

Use `.github/workflows/ios-screenshots.yml` (`workflow_dispatch`):

- always captures screenshots and uploads artifacts
- optionally uploads to App Store Connect with `upload_to_app_store=true`

The screenshot flow is intentionally separate from TestFlight release uploads.

## App Store Submission Process

1. Run `make ios-release` (or the TestFlight workflow) to upload a build.
   - Local prereq: create `iosapp/Signing.local.xcconfig` with
     `DEVELOPMENT_TEAM = <your_team_id>`.
   - CI prereq: set the `APPLE_TEAM_ID` secret.
2. In App Store Connect, create/select the app version and attach that build.
3. Run `make ios-screenshots-upload` (or the screenshot workflow with
   `upload_to_app_store=true`).
4. Run `make ios-metadata-upload` (or the screenshot workflow with
   `upload_metadata=true`).
5. Complete App Store Connect fields that are still manual: app privacy
   questionnaire, age rating questionnaire, export-compliance answers, pricing
   and availability, DSA/trader status, final reviewer contact/credentials,
   and reviewer notes (paste from `iosapp/fastlane/review_notes.txt`).
6. Review the draft in App Store Connect, then submit for review manually.

## Submission behavior notes

- `upload_screenshots` and `upload_metadata` do not submit for review.
  `deliver` keeps `submit_for_review` at its default (`false`) unless set.
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
