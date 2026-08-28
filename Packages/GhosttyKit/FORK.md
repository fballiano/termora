# Why this copy exists

This is a copy of `Lakr233/libghostty-spm` at package version 1.4.1 (commit
`2db97f9`, wrapping Ghostty 1.3.1), taken so that Termora can carry two
changes the upstream package does not have. The binary framework still comes
from the upstream release, by URL and checksum, so only the Swift wrapper is
ours.

The copy began with a third change, a wakeup-delivery fix. That one was
accepted upstream as
[Lakr233/libghostty-spm#50](https://github.com/Lakr233/libghostty-spm/pull/50)
and released in 1.4.1, so it is no longer a local change. If the two changes
below are ever accepted upstream too, delete this copy and depend on the
upstream package again.

Read this file before you take a newer upstream version. Every change below
must be made again, or its bug comes back.

## The first change: `isSurfaceVisible` lost behind a hidden tab

`TerminalViewState.isSurfaceVisible` reached the platform view only through
the SwiftUI representable's update pass. SwiftUI (macOS 26) does not
reliably run that pass for a representable whose ancestor sits at
`opacity(0)` — exactly how a host keeps hidden tabs mounted.

A surface built behind a hidden tab was therefore born occluded and never
heard `setSurfaceVisible(true)` when its tab was chosen. In Termora that
showed as a tab that connected while another tab was in front and then
stayed a blank pane for ever. The visible tab had the mirror image: its
`false` was also lost, so it kept rendering behind the tab in front.

The change: `isSurfaceVisible` now has a `didSet` that pushes the new value
to `attachedView` imperatively, keeping `hostDeclaredDisplayVisible` in
step. The representable's own stamping remains, for a view that attaches
after the state was already set.

Files touched:

- `Sources/GhosttyTerminal/State/TerminalViewState.swift`

The regression test is in the application repository:
`TermoraUITests/TabSwitchDuringConnectTests.swift`, run through
`Scripts/uitest-ssh.sh`.

## The second change: programmatic key presses

`TerminalViewState.send(_:)` reaches the terminal through
`ghostty_surface_text`, which Ghostty routes through its clipboard-paste
path. A remote shell with bracketed paste on (readline 8.1 and later turns
it on by default) receives the text framed as `ESC[200~ … ESC[201~`, so a
sent `\r` is inserted into the edit line instead of running it. Termora's
"After connecting" `{ENTER}` therefore did nothing whenever it lost the
race with the remote prompt.

The addition: a public `TerminalKeyPress` enum and
`TerminalViewState.sendKey(_:)` /
`TerminalSurface.sendKeyPress(_:)`, which send a real key event through
`ghostty_surface_key`. Key events are never paste-framed.

Files touched:

- `Sources/GhosttyTerminal/Surface/TerminalKeyPress.swift` (new)
- `Sources/GhosttyTerminal/State/TerminalViewState.swift`

## Other differences from upstream

These are trims, not changes: the copy drops upstream's tests, example app,
scripts, and docs, and `Package.swift` drops the test target. The wrapped
sources are otherwise upstream 1.4.1, byte for byte, except the two changes
above.
