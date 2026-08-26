# Why this copy exists

This is a copy of `Lakr233/libghostty-spm` at package version 1.4.0 (tag
`356f730`, wrapping Ghostty 1.3.1), taken so that Termora can fix one bug.
The binary framework still comes from the upstream release, by URL and
checksum, so only the Swift wrapper is ours.

The fix is proposed upstream as
[Lakr233/libghostty-spm#50](https://github.com/Lakr233/libghostty-spm/pull/50).
If that PR is merged and released, delete this copy and depend on the
upstream package again.

Read this file before you take a newer upstream version. Every change below
must be made again, or the bug comes back.

## The bug: one wakeup handler for every surface

`TerminalController` holds one Ghostty application object, and every terminal
surface shares it. The wrapper kept **one** wakeup handler on that controller:

    controller.onWakeup = { [weak self] in self?.requestImmediateTick() }   // per surface
    controller?.onWakeup = nil                                             // on any teardown

With more than one surface open this fails twice:

1. Each new surface writes over the handler, so only the newest surface is
   told to draw.
2. Closing any surface clears the handler, so **no** surface is told to draw.

In Termora that showed as tabs that stayed open, stayed connected, and drew
nothing at all. The tab bar reported them ready, because the SSH connection
and the shell were both alive. Only the drawing was gone.

`shouldProcessWakeup` had the same shape, and was worse: one detached surface
could stop `ghostty_app_tick` for every other surface, which also stops the
application mailbox draining.

## The change

`TerminalController` now keeps a set of observers instead of one handler:

- `addWakeupObserver(_:shouldProcess:onWakeup:)`
- `removeWakeupObserver(_:)`
- `handleWakeup()` ticks when **any** observer says it may, then tells
  **every** observer.

`TerminalSurfaceCoordinator` adds itself when it builds a surface and removes
itself when it tears one down, instead of assigning and clearing.

Files touched:

- `Sources/GhosttyTerminal/Controller/TerminalController.swift`
- `Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift`

## The second bug: `isSurfaceVisible` lost behind a hidden tab

`TerminalViewState.isSurfaceVisible` reached the platform view only through
the SwiftUI representable's update pass. SwiftUI (macOS 26) does not
reliably run that pass for a representable whose ancestor sits at
`opacity(0)` — exactly how a host keeps hidden tabs mounted.

A surface built behind a hidden tab was therefore born occluded and never
heard `setSurfaceVisible(true)` when its tab was chosen. In Termora that
showed as a tab that connected while another tab was in front and then
stayed a blank pane for ever. The visible tab had the mirror image: its
`false` was also lost, so it kept rendering behind the tab in front.

## The change

`isSurfaceVisible` now has a `didSet` that pushes the new value to
`attachedView` imperatively, keeping `hostDeclaredDisplayVisible` in step.
The representable's own stamping remains, for a view that attaches after
the state was already set.

Files touched:

- `Sources/GhosttyTerminal/State/TerminalViewState.swift`

The regression test is in the application repository:
`TermoraUITests/TabSwitchDuringConnectTests.swift`, run through
`Scripts/uitest-ssh.sh`.
