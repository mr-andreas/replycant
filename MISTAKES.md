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
