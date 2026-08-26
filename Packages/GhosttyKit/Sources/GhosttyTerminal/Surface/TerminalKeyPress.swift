//
//  TerminalKeyPress.swift
//  libghostty-spm
//

import GhosttyKit

/// A named key a host can press programmatically.
///
/// `sendText(_:)` reaches the terminal through the paste path. An
/// application that has turned bracketed paste on receives that text framed
/// as a paste: a shell then inserts a pasted `\r` into its edit line instead
/// of running the line. A key event is never framed, so a programmatic
/// Enter always acts as the Enter key.
public enum TerminalKeyPress: Sendable {
    case enter
    case tab
    case escape
    case backspace
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight

    var ghosttyKey: ghostty_input_key_e {
        switch self {
        case .enter: GHOSTTY_KEY_ENTER
        case .tab: GHOSTTY_KEY_TAB
        case .escape: GHOSTTY_KEY_ESCAPE
        case .backspace: GHOSTTY_KEY_BACKSPACE
        case .arrowUp: GHOSTTY_KEY_ARROW_UP
        case .arrowDown: GHOSTTY_KEY_ARROW_DOWN
        case .arrowLeft: GHOSTTY_KEY_ARROW_LEFT
        case .arrowRight: GHOSTTY_KEY_ARROW_RIGHT
        }
    }
}

extension TerminalSurface {
    /// Presses one named key, as if it was typed on the keyboard.
    @discardableResult
    public func sendKeyPress(_ key: TerminalKeyPress) -> Bool {
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = TerminalHardwareKeyRouter.appKitKeyCode(for: key.ghosttyKey)
        return sendKeyEvent(event)
    }
}
