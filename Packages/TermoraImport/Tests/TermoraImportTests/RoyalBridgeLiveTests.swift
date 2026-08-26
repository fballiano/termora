import Foundation
import Testing
@testable import TermoraImport

/// Drives the real bridge against the real Royal TSX application.
///
/// This suite launches Royal TSX and asks macOS for permission to control it,
/// so it does not run by itself. Set `TERMORA_TEST_ROYAL_BRIDGE=1` to switch
/// it on, together with a Royal document that `RealDocument` can find.
///
/// It prints no secret. It reports how many secrets came back and how long
/// they are, and it checks that each one differs from the stored blob.
@MainActor
@Suite(.serialized, .enabled(if: RoyalBridgeLive.isEnabled))
struct RoyalBridgeLiveTests {
    private let objects: [RoyalObject]
    private let documentPath: String

    init() throws {
        let url = try #require(RealDocument.url)
        documentPath = url.path
        objects = try RoyalDocumentParser().parse(contentsOf: url)
    }

    /// Every object that holds a secret, and the encrypted text it holds.
    private var carriers: [(object: RoyalObject, key: String, blob: String)] {
        objects.compactMap { object -> [(RoyalObject, String, String)]? in
            guard object.type == "RoyalSSHConnection" else { return nil }
            var found: [(RoyalObject, String, String)] = []
            if let blob = object["CredentialPassword"], !blob.isEmpty {
                found.append((object, "CredentialPassword", blob))
            }
            if let blob = object["CredentialPassphrase"], !blob.isEmpty {
                found.append((object, "CredentialPassphrase", blob))
            }
            return found.isEmpty ? nil : found
        }
        .flatMap { $0 }
        .map { (object: $0.0, key: $0.1, blob: $0.2) }
    }

    @Test("Royal TSX hands every stored secret to the bridge, decrypted")
    func recoversEverySecret() throws {
        let bridge = RoyalTSXBridge()
        try #require(RoyalTSXBridge.isInstalled, "Royal TSX must be installed.")

        let availability = bridge.openDocument(path: documentPath)
        try #require(availability == .ready,
                     "Royal TSX refused to open the document: \(availability)")

        let all = carriers
        #expect(!all.isEmpty, "The document must hold at least one secret to test.")

        var recovered = 0
        for carrier in all {
            let value = bridge.value(ofKey: carrier.key, objectID: carrier.object.id)
            guard !value.isEmpty else { continue }

            // Never compare or print the value itself, only its shape.
            #expect(value != carrier.blob,
                    "\(carrier.key) came back unchanged, so it is still encrypted.")
            #expect(value.count < carrier.blob.count,
                    "A decrypted secret is shorter than its ciphertext.")
            recovered += 1
        }

        #expect(recovered == all.count,
                "Royal TSX handed over \(recovered) of \(all.count) secrets.")
    }

    @Test("An identifier Royal TSX does not know gives nothing, and does not fail loudly")
    func unknownIdentifierIsSafe() {
        let bridge = RoyalTSXBridge()
        bridge.openDocument(path: documentPath)
        let value = bridge.value(ofKey: "CredentialPassword",
                                 objectID: "00000000-0000-0000-0000-000000000000")
        #expect(value.isEmpty)
    }
}

enum RoyalBridgeLive {
    /// This suite starts another application, so it is off unless asked for.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TERMORA_TEST_ROYAL_BRIDGE"] == "1"
            && RealDocument.url != nil
            && RoyalTSXBridge.isInstalled
    }
}
