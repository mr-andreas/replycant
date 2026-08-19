# Mistakes

Log of AI mistakes. Repeated entries are kept on purpose: they show which
mistakes keep happening so a human can later add a Cursor rule.

## Entry format

```markdown
## YYYY-MM-DD: short title

**Category:** short-stable-slug
**What happened:** ...
**Root cause:** ...
**Prevention:** ...
```

Newest entries go below this line.

## 2026-08-18: ran stale tests without rebuilding

**Category:** stale-test-bundle
**What happened:** `test-without-building` executed 15 old
`RecoveryShareItemsTests` after I had added three new cases and
changed Notes/cleanup assertions, so the suite failed on obsolete
expectations.
**Root cause:** I reused an earlier `.xctestrun` instead of
rebuilding after editing the test file.
**Prevention:** After changing tests, run `build-for-testing`
before `test-without-building`, or use a full `xcodebuild test`.

## 2026-08-18: deinit deleted files before tests loaded them

**Category:** premature-cleanup
**What happened:** After adding `deinit` cleanup to
`RecoveryShareItem`, three file-URL load tests failed with
`NSItemProviderErrorDomain` -1000 and nil data.
**Root cause:** The tests called `shareItem().activityViewController`
on a temporary, so `deinit` removed the export directory before
`loadFileRepresentation` ran.
**Prevention:** Keep the share item alive for the duration of any
file-representation load, the same way the view holds it in state.

## 2026-08-17: data representations did not advertise text UTIs

**Category:** item-provider-uti
**What happened:** Recovery share tests failed because the text
attachment's `registeredTypeIdentifiers` stayed empty and HTML
could not be loaded.
**Root cause:** `registerDataRepresentation` on an empty
`NSItemProvider` did not publish `public.utf8-plain-text`,
`public.plain-text`, or `public.html`.
**Prevention:** Advertise those types through
`NSItemProviderWriting.writableTypeIdentifiersForItemProvider`
and `NSItemProvider(object:)`.

## 2026-08-17: used a nonexistent async NSItemProvider load

**Category:** item-provider-async-api
**What happened:** `RecoveryShareItemsTests` failed to compile because
`loadDataRepresentation(for: .html)` has no async overload.
**Root cause:** I assumed the UTType-based load was `async throws`.
The available API takes a completion handler.
**Prevention:** Wrap `loadDataRepresentation(forTypeIdentifier:)` in
`withCheckedContinuation` instead of calling it with `await`.

## 2026-08-17: assumed NSString provider registers public.plain-text

**Category:** item-provider-uti
**What happened:** Recovery share tests failed because the text
attachment did not advertise `public.plain-text`.
**Root cause:** `NSItemProvider(object: NSString)` registers
`public.utf8-plain-text`, not the UTI the tests and plan required.
**Prevention:** Register the intended UTI explicitly with
`NSItemProvider(item:typeIdentifier:)` instead of relying on
`NSItemProvider(object:)`.

## 2026-08-17: treated provider representations as combined content

**Category:** share-sheet-representations
**What happened:** A single `NSItemProvider` registered HTML, PNG, and
plain text. Gmail and Notes received empty bodies; Signal got the image.
**Root cause:** Representations on one provider are alternatives. Gmail
and Notes chose HTML and discarded inline `data:` images, leaving
nothing usable.
**Prevention:** Do not expect one provider's representations to combine.
Use a compound `NSExtensionItem` for share extensions that can take
text plus attachments, and return a single image to Signal.

## 2026-08-17: metadataProvider did not override multi-item header

**Category:** share-sheet-item-count
**What happened:** After switching to `UIActivityItemsConfiguration`
with two item providers, the share sheet header said "2 Images"
instead of "Replycant recovery key".
**Root cause:** iOS replaces custom metadata with its own summary
whenever more than one item is shared. The text provider was counted
as an image because it received the same icon metadata.
**Prevention:** Keep the share a single item if the custom title must
appear. Put extra payloads on that item as representations, not as
additional providers.

## 2026-08-17: adaptive share item only ever sent the image

**Category:** share-sheet-single-payload
**What happened:** After collapsing to one `UIActivityItemSource`, the
share sheet title looked correct, but every destination received only
the QR card image.
**Root cause:** A single activity item can return only one payload, and
the image placeholder plus default routing sent the card everywhere
except Copy and Mail.
**Prevention:** When the user needs both an image and a recovery link,
use `UIActivityItemsConfiguration` with two item providers instead of
routing one `UIActivityItemSource` by activity type.

## 2026-08-17: two-item share sheet diagnosed as missing metadata

**Category:** share-sheet-item-count
**What happened:** The recovery share header showed a blank title, then
"2 Links", after two attempts to fix `LPLinkMetadata` fields.
**Root cause:** The share sheet only uses per-item metadata when there
is exactly one activity item. Two items (text plus image) made iOS
ignore both titles and show an aggregate count instead.
**Prevention:** When a share-sheet header ignores custom metadata,
check the activity-item count before adding more `LPLinkMetadata`
fields or a URL.

## 2026-08-17: title-only share metadata left header blank

**Category:** incomplete-link-metadata
**What happened:** Recovery share items set only `LPLinkMetadata.title`.
The share sheet still showed a blank title and lost the Replycant icon.
**Root cause:** Custom metadata was planned and shipped without Apple's
required `url`/`originalURL` fields or an explicit `iconProvider`,
which also dropped UIKit's automatic app-icon fallback.
**Prevention:** When customizing a share-sheet preview, supply complete
`LPLinkMetadata` (title, real URL, and icon) and verify the header on
device instead of assuming title-only metadata is enough.

## 2026-08-16: added unwanted Done-unlock hint copy

**Category:** extra-explanatory-copy
**What happened:** The recovery-key created step included a footnote
that Done unlocks after sharing. The user asked to remove it.
**Root cause:** The hint was added to justify a disabled button instead
of letting the disabled state and the share CTA stand alone.
**Prevention:** Do not add instructional helper text around an already
disabled control unless the user asks for that copy.

## 2026-08-16: preview crash blamed on RecoveryKeyView refresh

**Category:** preview-crash-misdiagnosis
**What happened:** RecoveryKeyView Canvas still crashed after skipping
its repository refresh. The preview host launches the real app, and
simulator auto-connect plus ContentView auto-resync start clone/git
work that aborts the preview process.
**Root cause:** Diagnosed only the view-local `.task` and did not check
whether `@main` App/ContentView launch work also runs inside Canvas.
**Prevention:** When a SwiftUI preview crashes, inspect
`XCODE_RUNNING_FOR_PREVIEWS` launch paths (App init, ContentView
`.task`, auto-resync) before treating the previewed view as the only
cause.

## 2026-08-16: page description placed as a trailing section footer

**Category:** ui-copy-placement
**What happened:** The recovery key explanation was added as a `footer:`
on the create-button section, so it rendered as a footnote near the
bottom of the screen. The user asked for text that introduces the page
instead, and it had to be moved to a leading section.
**Root cause:** Placement was chosen from the SwiftUI list idiom for
supplementary hints without considering that the copy answers "what is
this screen for", which readers expect before the controls.
**Prevention:** Copy that explains a whole screen goes above the
content it describes; reserve section footers for hints about one
specific control.

## 2026-08-13: iOS tests asserted unverified AVPlayer.play() rate semantics

**Category:** unverified-avfoundation-semantics
**What happened:** Agent-authored FullscreenVideoDismissPlaybackTests
landed on main asserting `player.rate == 0` after `play()` on an
AVPlayer whose item had already been detached. GitHub CI failed both
`stopPlaybackDetachesPlayerItem` and
`lateSeekResumeCannotRestartAfterTeardown` because `AVPlayer.play()`
sets `rate` to `1.0` even when `currentItem` is `nil`.
**Root cause:** The tests treated `rate` as proof that audio cannot
resume, without checking how AVFoundation actually updates that
property after `replaceCurrentItem(with: nil)`.
**Prevention:** When asserting playback teardown, treat detached
`currentItem` as the no-audio invariant. Only assert `rate == 0` at
the moment teardown returns, not after a subsequent `play()`.
