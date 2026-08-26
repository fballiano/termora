//
//  RoyalTaskLibrary.swift
//  TermoraImport
//

import Foundation
import TermoraModel

/// The tasks that Royal TSX keeps outside a connections document.
///
/// A connection file names a task, but never holds its commands. Royal TSX
/// writes the commands into its application settings file, in the same XML
/// form as a document. That file is readable, so the commands can be imported
/// with the same parser and with no help from Royal TSX itself.
public struct RoyalTaskLibrary: Sendable {
    /// One `RoyalCommandTask` object.
    public struct Task: Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let commandLine: String
        public let arguments: String
        public let runsInTerminal: Bool
        public let asksFirst: Bool

        public init(id: String, name: String, commandLine: String, arguments: String,
                    runsInTerminal: Bool, asksFirst: Bool) {
            self.id = id
            self.name = name
            self.commandLine = commandLine
            self.arguments = arguments
            self.runsInTerminal = runsInTerminal
            self.asksFirst = asksFirst
        }

        /// The Termora form of this task.
        public var command: LocalCommand {
            LocalCommand(name: name, launchPath: commandLine,
                         arguments: arguments, waitsForCompletion: true)
        }
    }

    public let tasks: [Task]

    public init(tasks: [Task] = []) {
        self.tasks = tasks
    }

    public static let empty = RoyalTaskLibrary()
    public var isEmpty: Bool { tasks.isEmpty }

    /// Where Royal TSX keeps its application settings.
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Royal TSX/UserPreferences.config")
    }

    /// Reads the tasks from a Royal TSX settings file.
    ///
    /// A missing file is not an error. It only means there are no tasks.
    public static func read(contentsOf url: URL = defaultURL) throws -> RoyalTaskLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let objects = try RoyalDocumentParser().parse(contentsOf: url)
        return RoyalTaskLibrary(objects: objects)
    }

    public init(objects: [RoyalObject]) {
        // Royal names the fields for each platform. Take the macOS ones, and
        // fall back to the plain name when only one form is written.
        func pick(_ object: RoyalObject, _ base: String) -> String {
            let mac = object.string(base + "OSX")
            return mac.isEmpty ? object.string(base) : mac
        }

        tasks = objects.filter { $0.type == "RoyalCommandTask" }.map { object in
            Task(
                id: object.id,
                name: object.name,
                commandLine: pick(object, "CommandLine"),
                arguments: pick(object, "Arguments"),
                runsInTerminal: object.bool("ExecuteInTerminalOSX")
                    || object.bool("ExecuteInTerminal"),
                asksFirst: !object.bool("NoConfirmationRequired")
            )
        }
    }

    public func task(named name: String) -> Task? {
        tasks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func task(id: String) -> Task? {
        guard RoyalImporter.isRealIdentifier(id) else { return nil }
        return tasks.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Finds the task a connection asks for before it connects.
    ///
    /// Royal writes a mode: 2 means "look the task up by name". Any other mode
    /// with a real identifier means "look it up by identifier".
    public func preConnectTask(for object: RoyalObject) -> Task? {
        if let byID = task(id: object.string("PreConnectTaskId")) { return byID }
        let name = object.string("PreConnectTaskName")
        guard !name.isEmpty else { return nil }
        return task(named: name)
    }
}
