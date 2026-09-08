//
//  TabShortcutsTests.swift
//  TermoraUITests
//

import TermoraModel
import TermoraVault
import XCTest

/// ⌘1…⌘9 reach the tabs with a live session in the way.
///
/// The check needs a pane that a terminal holds. A pane answers a key before
/// the menu bar sees it, so a shortcut that works on an empty window can still
/// do nothing once a session runs.
///
/// The OpenSSH server runs outside the test runner. See
/// `Scripts/uitest-ssh.sh`, which passes the port and the key through the
/// environment. Without them the test is skipped. Run it with:
///
///   ./Scripts/uitest-ssh.sh TermoraUITests/TabShortcutsTests
final class TabShortcutsTests: XCTestCase {
    private static let password = "test master password"

    private var documentURL: URL!
    private var homeURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false

        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["TERMORA_TEST_SSH_PORT"],
              let port = Int(portText),
              let keyPath = environment["TERMORA_TEST_SSH_KEY"]
        else {
            throw XCTSkip("No local sshd. Run this through Scripts/uitest-ssh.sh.")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        documentURL = directory.appendingPathComponent("Fixture.termora")

        // The application's ssh writes known_hosts under this HOME, not yours.
        homeURL = directory.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: homeURL.appendingPathComponent(".ssh"),
            withIntermediateDirectories: true
        )

        let settings = NodeSettings(
            username: .value(NSUserName()),
            authentication: .value(.privateKey(path: keyPath, passphrase: Secret(""))),
            hostKeyPolicy: .value(.acceptNew)
        )
        let alpha = Connection(
            name: "alpha", host: "127.0.0.1", port: port, settings: settings
        )
        let beta = Connection(
            name: "beta", host: "127.0.0.1", port: port, settings: settings
        )
        let document = Document(folders: [], connections: [alpha, beta])
        _ = try await Vault.create(at: documentURL, password: Self.password, document: document)
    }

    override func tearDown() async throws {
        if let directory = documentURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    /// ⌘1 and ⌘2 choose a tab while a terminal holds the keyboard.
    ///
    /// Ghostty binds ⌘1…⌘9 to tabs of its own. Termora has no tabs inside a
    /// pane, so it drops that action, and every press was eaten with nothing
    /// to show for it. `GhosttyEnvironment.menuKeyTriggers` unbinds them.
    func testTabNumbersReachTheMenu() throws {
        let app = launchApp()
        let main = window(of: app)
        unlock(main)

        let alpha = openTab(named: "alpha", in: main)
        let beta = openTab(named: "beta", in: main)
        XCTAssertTrue(beta.isSelected, "The tab opened last must be the chosen one.")

        app.typeKey("1", modifierFlags: [.command])
        XCTAssertTrue(waitUntilSelected(alpha), "⌘1 must choose the first tab.")

        app.typeKey("2", modifierFlags: [.command])
        XCTAssertTrue(waitUntilSelected(beta), "⌘2 must choose the second tab.")
    }

    // MARK: - Helpers

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-TermoraLastDocumentPath", documentURL.path]
        app.launchEnvironment["HOME"] = homeURL.path
        app.launch()
        return app
    }

    private func window(of app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "The application showed no window.")
        return window
    }

    private func unlock(_ main: XCUIElement) {
        let field = main.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("\(Self.password)\r")
        XCTAssertTrue(main.staticTexts["alpha"].firstMatch.waitForExistence(timeout: 10))
    }

    /// Opens a connection from the sidebar and waits for its tab.
    ///
    /// The wait gives ssh time to connect and the pane time to take the
    /// keyboard. A key pressed before that goes to the sidebar, which proves
    /// nothing about a pane.
    private func openTab(named name: String, in main: XCUIElement) -> XCUIElement {
        main.staticTexts[name].firstMatch.doubleClick()
        let tab = main.descendants(matching: .any)
            .matching(identifier: "tab-\(name)").firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "No tab opened for \(name).")
        sleep(6)
        return tab
    }

    private func waitUntilSelected(_ tab: XCUIElement) -> Bool {
        let selected = expectation(for: NSPredicate(format: "selected == true"),
                                   evaluatedWith: tab)
        return XCTWaiter.wait(for: [selected], timeout: 5) == .completed
    }
}
