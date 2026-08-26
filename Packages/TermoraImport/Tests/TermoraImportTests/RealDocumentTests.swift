import Foundation
import Testing
@testable import TermoraImport
@testable import TermoraModel

/// Runs against a real Royal TSX document when one is present.
///
/// The test reads the file and never writes it. It prints no host name, no
/// user name, and no secret: it checks shapes and counts only. When the file
/// is missing, the suite is skipped, so the tests still pass on another
/// machine.
@Suite(.enabled(if: RealDocument.url != nil))
struct RealDocumentTests {
    private let objects: [RoyalObject]

    init() throws {
        objects = try RoyalDocumentParser().parse(contentsOf: RealDocument.url!)
    }

    @Test("The real document parses, and every object carries an identifier")
    func parsesTheRealDocument() {
        #expect(!objects.isEmpty)
        #expect(objects.allSatisfy { !$0.id.isEmpty },
                "Every Royal object must have an ID, because the tree is built from it.")
    }

    @Test("Every connection becomes a Termora connection under the right folder")
    func importsEverything() {
        let royalConnections = objects.filter {
            $0.type == "RoyalSSHConnection"
                && !$0.bool("IsTelnetConnection")
                && !$0.bool("IsSerialPortConnection")
                && !$0.bool("IsConnectionTemplate")
        }
        let royalFolders = objects.filter { $0.type == "RoyalFolder" }

        let (document, report) = RoyalImporter().makeDocument(from: objects)

        #expect(report.connectionsCreated == royalConnections.count)
        #expect(report.foldersCreated == royalFolders.count)

        // No entry may be left without a parent that exists.
        let folderIDs = Set(document.folders.map(\.id))
        #expect(document.connections.allSatisfy {
            $0.parentID == nil || folderIDs.contains($0.parentID!)
        }, "Every connection must sit at the top level or inside a folder that exists.")
    }

    @Test("Every connection has a host and a usable port")
    func hasUsableTargets() {
        let (document, _) = RoyalImporter().makeDocument(from: objects)
        #expect(document.connections.allSatisfy { !$0.host.isEmpty })
        #expect(document.connections.allSatisfy { (1 ... 65535).contains($0.port) })
    }

    @Test("Inheritance survives: an entry that inherited in Royal still inherits")
    func inheritanceSurvives() {
        let inheriting = objects.filter {
            $0.type == "RoyalSSHConnection"
                && ($0.bool("CredentialFromParent") || $0.int("CredentialMode") == 1)
        }
        let (document, _) = RoyalImporter().makeDocument(from: objects)

        let names = Set(inheriting.map(\.name))
        let imported = document.connections.filter { names.contains($0.name) }
        #expect(imported.count == inheriting.count)
        #expect(imported.allSatisfy { $0.settings.username == .inherit },
                "An entry that took its credentials from the folder must still do so.")
    }

    @Test("Without Royal TSX, every stored secret is listed as missing")
    func namesEverySecretItCouldNotRead() {
        let withStoredSecret = objects.filter {
            $0.type == "RoyalSSHConnection"
                && ($0["CredentialPassword"] != nil || $0["CredentialPassphrase"] != nil)
        }
        let (_, report) = RoyalImporter().makeDocument(from: objects)

        // Every entry that holds a secret in Royal must appear, either because
        // Termora needs it typed in, or because the other credential was kept.
        let named = Set(report.missingSecrets.map(\.connectionName)
            + report.notImported.map(\.connectionName))
        for entry in withStoredSecret {
            #expect(named.contains(entry.name),
                    "An entry holding a secret must be named in the report.")
        }
    }

    @Test("The imported document survives a round trip through JSON")
    func roundTrips() throws {
        let (document, _) = RoyalImporter().makeDocument(from: objects)
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(Document.self, from: data) == document)
    }
}

enum RealDocument {
    /// The document this project was written against. Change the path, or set
    /// TERMORA_ROYAL_DOCUMENT, to run these tests against your own file.
    static var url: URL? {
        if let path = ProcessInfo.processInfo.environment["TERMORA_ROYAL_DOCUMENT"],
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let candidate = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/CloudStorage/OneDrive-Personale/RoyalConnections.rtsz")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
