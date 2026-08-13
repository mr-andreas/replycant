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
