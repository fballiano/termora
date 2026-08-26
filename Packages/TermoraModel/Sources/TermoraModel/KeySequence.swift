//
//  KeySequence.swift
//  TermoraModel
//

import Foundation

/// Text that Termora types into a session after it opens.
///
/// Royal TSX calls this a key sequence and writes it with names in braces,
/// for example `cd /opt/maho/app{ENTER}`. The same form is kept here, so an
/// imported sequence reads the way it did before.
public enum KeySequence {
    /// A key that is pressed, not typed as text.
    ///
    /// Text reaches the terminal through the paste path. A shell with
    /// bracketed paste on inserts a pasted `\r` into its edit line instead
    /// of running the line. A key press is never framed as a paste, so
    /// `{ENTER}` always runs the command.
    public enum Key: Hashable, Sendable {
        case enter, tab, escape, backspace, up, down, left, right
    }

    /// One thing to do, in order.
    public enum Step: Hashable, Sendable {
        case text(String)
        case press(Key)
        case wait(milliseconds: Int)
    }

    /// The names Royal TSX uses, and the key each one presses.
    static let keys: [String: Key] = [
        "ENTER": .enter,
        "RETURN": .enter,
        "TAB": .tab,
        "ESC": .escape,
        "ESCAPE": .escape,
        "BACKSPACE": .backspace,
        "DELETE": .backspace,
        "UP": .up,
        "DOWN": .down,
        "RIGHT": .right,
        "LEFT": .left,
    ]

    /// The longest wait a sequence may ask for, so a typing mistake cannot
    /// hold a session for ever.
    public static let maximumWaitMilliseconds = 60_000

    /// Turns `cd /opt{ENTER}` into the steps that produce it.
    ///
    /// A name in braces that nobody knows is left as it stands, so nothing is
    /// swallowed without being seen.
    public static func steps(from sequence: String) -> [Step] {
        guard !sequence.isEmpty else { return [] }

        var steps: [Step] = []
        var literal = ""
        var rest = Substring(sequence)

        func flush() {
            if !literal.isEmpty {
                steps.append(.text(literal))
                literal = ""
            }
        }

        while let open = rest.firstIndex(of: "{") {
            literal += rest[rest.startIndex ..< open]
            let afterOpen = rest.index(after: open)

            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                // No closing brace: the rest is ordinary text.
                literal += rest[open...]
                rest = rest[rest.endIndex...]
                break
            }

            let name = String(rest[afterOpen ..< close]).uppercased()
            if let key = keys[name] {
                flush()
                steps.append(.press(key))
            } else if name == "SPACE" {
                literal += " "
            } else if name.hasPrefix("DELAY:"), let value = Int(name.dropFirst(6)) {
                flush()
                steps.append(.wait(milliseconds: min(max(0, value), maximumWaitMilliseconds)))
            } else {
                // Unknown, so keep it exactly as written.
                literal += rest[open ... close]
            }
            rest = rest[rest.index(after: close)...]
        }

        literal += rest
        flush()
        return steps
    }

    /// True when the sequence would do nothing.
    public static func isEmpty(_ sequence: String) -> Bool {
        steps(from: sequence).isEmpty
    }
}
