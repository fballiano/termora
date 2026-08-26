//
//  ForwardsTests.swift
//  TermoraUITests
//

import TermoraModel
import TermoraVault
import XCTest

/// Checks the tunnel editor in the inspector.
///
/// Opening a tunnel needs a live connection, which these tests do not make.
/// The engine side is covered by the TermoraSSH integration tests, where a
/// tunnel is opened on a real server and traffic is carried through it.
final class ForwardsTests: XCTestCase {
    private static let password = "test master password"
    private var documentURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-forwards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        documentURL = directory.appendingPathComponent("Fixture.termora")

        let connection = Connection(
            name: "web-01",
            host: "web01.example.com",
            forwards: [
                PortForward(kind: .local, listenPort: 8080,
                            destinationHost: "localhost", destinationPort: 80),
            ]
        )
        _ = try await Vault.create(
            at: documentURL,
            password: Self.password,
            document: Document(connections: [connection])
        )
    }

    override func tearDown() async throws {
        if let directory = documentURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    private func unlockedWindow() -> XCUIElement {
        let app = XCUIApplication()
        app.launchArguments = ["-TermoraLastDocumentPath", documentURL.path]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let field = window.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("\(Self.password)\r")

        XCTAssertTrue(window.staticTexts["web-01"].waitForExistence(timeout: 10))
        window.staticTexts["web-01"].click()
        return window
    }

    /// The editor is a sheet, opened from the right-click menu of a row, so
    /// the terminal keeps the whole window.
    private func openEditor(in window: XCUIElement) -> XCUIElement {
        let app = XCUIApplication()
        window.staticTexts["web-01"].rightClick()
        let edit = app.menuItems["Edit…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5),
                      "A right click on a row must offer the editor.")
        edit.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Edit must open the editor.")
        return sheet
    }

    /// The tunnel editor, one launch: the row reads back what it does, Add
    /// offers every kind, and a bad port is reported before connecting.
    func testTunnelEditor() {
        let sheet = openEditor(in: unlockedWindow())

        XCTAssertTrue(sheet.staticTexts["Tunnels"].waitForExistence(timeout: 5),
                      "The editor must have a tunnels section.")

        // The line must read back what the tunnel does, so the two ports
        // cannot be the wrong way round without being noticed.
        let summary = sheet.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "localhost:8080 → localhost:80")
        ).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5),
                      "A tunnel must say what it does, even before you connect.")

        // A SwiftUI Menu is a MenuButton. The PopUpButton in this section is
        // the kind picker of the tunnel that already exists.
        let addButton = sheet.menuButtons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "The tunnels section must offer Add.")
        addButton.click()

        let app = XCUIApplication()
        for kind in ["Local", "Remote", "Dynamic"] {
            XCTAssertTrue(
                app.menuItems.matching(
                    NSPredicate(format: "title BEGINSWITH[c] %@", kind)
                ).firstMatch.waitForExistence(timeout: 5),
                "The Add menu must offer a \(kind) tunnel."
            )
        }
        // Leave the menu without choosing anything.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        // The first field with the "port" placeholder is the listening port.
        let portField = sheet.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "port")
        ).element(boundBy: 0)
        XCTAssertTrue(portField.waitForExistence(timeout: 5))

        portField.click()
        portField.typeKey("a", modifierFlags: .command)
        portField.typeText("0\t")

        let warning = sheet.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "listening port must be")
        ).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5),
                      "A port OpenSSH would refuse must be reported in the editor.")
    }
}
