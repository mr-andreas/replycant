# Bugs

## 1. Denied photo access shows a raw error on Upload

**Status:** fixed
**Area:** iOS app, Upload tab
**Found:** 2026-10-13, simulator, recovered small-repo library

**Steps**

1. Revoke Photos access for Replycant (Settings, or `simctl privacy revoke photos`). Revoking while the app is open kills it; relaunch.
2. Open the Upload tab.
3. Tap Start Upload.

**Expected**

The screen explains that photo library access is off and how to turn it back on. It does not show an internal error code.

**Actual**

Upload fails immediately with:

> The operation couldn’t be completed. (iosapp.PhotoLibraryError error 0.)

No permission prompt appears, because access is already denied. Start Upload stays on screen, and tapping it again shows the same message.

**Cause**

`PhotoSyncManager.startSync()` throws `PhotoLibraryError.accessDenied`. That type does not conform to `LocalizedError`, so `PhotoSyncView` prints `error.localizedDescription`, which is the Swift error name and case index (`accessDenied` is case 0).

Limited ("Select Photos") access is not the same failure. The callback form of `PHPhotoLibrary.requestAuthorization` that the app uses reports limited access as `.authorized`, so choosing Select Photos does not reach this error.

## 2. Month sidebar highlights the wrong month

**Status:** fixed

**Area:** iOS app, Timeline month sidebar
**Found:** 2026-10-13, simulator, recovered small-repo library

**Steps**

1. Open the Timeline. It starts scrolled to the newest photos.
2. Tap the calendar button to show the month sidebar.
3. Compare the highlighted month with the capture date of the photo at the top of the grid.

**Expected**

The highlighted month is the month of the photos at the top of the grid.

**Actual**

The sidebar highlights June 2026. The top-left photo's details say it was captured on 1 August 2024. July and August 2024 are in the sidebar and are not highlighted.

The grid is oldest-first and the first layout scrolls to the bottom so the newest rows are in view (`TimelineInitialBottomAnchor`). The highlight does not follow that viewport.

## 3. Photo details show a UTI as the format

**Area:** iOS app, photo details
**Found:** 2026-10-13, simulator, recovered small-repo library

**Steps**

1. Open a photo from the timeline.
2. Swipe up to open the details panel.
3. Read the Format row.

**Expected**

Format is something a person can read, such as HEIC or JPEG.

**Actual**

Format shows the raw type identifier `public.heic`. Checked on two different photos; both said `public.heic`.

**Cause**

Upload stores `PHAssetResource.uniformTypeIdentifier` in `mimeType` (`PhotoLibraryManager`). That value is a UTI (`public.heic`), not a MIME type (`image/heic`). `MediaInfoContent` prints `mimeType` directly under the Format label.
