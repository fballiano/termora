//
//  UnlockAndBrowseTests.swift
//  TermoraUITests
//

import TermoraModel
import TermoraVault
import XCTest

/// Drives the real application through the unlock screen and into the sidebar.
///
/// The test writes a document with the vault API, then points the application
/// at it. `UserDefaults` reads `-key value` pairs from the command line, so
/// passing the path as a launch argument is enough. No application code knows
/// that a test is running.
///
/// Each test is one flow through several related checks. Every launch costs
/// seconds, so one test per assertion would spend most of its time waiting
/// for the same unlock screen.
final class UnlockAndBrowseTests: XCTestCase {
    private static let password = "test master password"

    private var documentURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        documentURL = directory.appendingPathComponent("Fixture.termora")

        let prod = Folder(name: "Prod", settings: NodeSettings(
            username: .value("root"),
            colorTag: .value(.red)
        ))
        let web = Connection(
            parentID: prod.id,
            name: "web-01",
            host: "web01.example.com",
            settings: NodeSettings(authentication: .value(.password(Secret("hunter2"))))
        )
        let standalone = Connection(name: "laptop", host: "192.168.1.10")
        let document = Document(folders: [prod], connections: [web, standalone])

        _ = try await Vault.create(at: documentURL, password: Self.password, document: document)
    }

    override func tearDown() async throws {
        if let directory = documentURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-TermoraLastDocumentPath", documentURL.path]
        app.launch()
        return app
    }

    /// Always query through the window, never through the application.
    ///
    /// A query rooted at the application makes XCUITest snapshot the menu bar
    /// as well, and opening every menu for inspection can take longer than the
    /// snapshot is allowed. The window then never appears in the tree, and a
    /// correct application looks empty.
    private func window(of app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "The application showed no window.")
        return window
    }

    /// Types the master password into the unlock screen.
    private func unlock(_ main: XCUIElement) {
        let field = main.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("\(Self.password)\r")
        XCTAssertTrue(main.staticTexts["Prod"].waitForExistence(timeout: 10),
                      "The folder from the document must appear in the sidebar.")
    }

    /// The whole unlock flow: the screen names the document, refuses a wrong
    /// password with an inline message, and opens with the right one.
    func testUnlockRefusesWrongPasswordThenOpens() {
        let main = window(of: launchApp())

        XCTAssertTrue(
            main.staticTexts["Fixture"].waitForExistence(timeout: 10),
            "The unlock screen must name the document."
        )
        let field = main.secureTextFields.firstMatch
        XCTAssertTrue(field.exists, "The unlock screen must offer a password field.")

        field.click()
        field.typeText("not the password\r")

        // The message is inline under the field, not an alert. Inline text
        // carries the words in its label; an alert carried them in its value.
        let message = main.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        "password is wrong", "password is wrong")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10),
                      "A wrong password must produce a message.")

        // The next attempt needs no extra click: no alert stands in the way.
        field.click()
        field.typeText("\(Self.password)\r")
        XCTAssertTrue(main.staticTexts["Prod"].waitForExistence(timeout: 10),
                      "The folder from the document must appear in the sidebar.")
        XCTAssertTrue(main.staticTexts["laptop"].exists,
                      "A connection at the top level must appear in the sidebar.")

        // No secret is ever drawn on screen.
        XCTAssertFalse(main.staticTexts["hunter2"].exists)
    }

    /// Both editors, one launch: the folder editor explains inheritance, and
    /// the connection editor names the folder an inherited value comes from.
    func testEditorsExplainInheritance() {
        let app = launchApp()
        let main = window(of: app)
        unlock(main)

        // The editor appears as a sheet over the window, reached from the
        // right-click menu of the row.
        main.staticTexts["Prod"].rightClick()
        var edit = app.menuItems["Edit…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5),
                      "A right click on a folder must offer the editor.")
        edit.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(
            sheet.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] 'unless it sets its own'")
            ).firstMatch.waitForExistence(timeout: 5),
            "The folder editor must explain inheritance."
        )
        sheet.buttons["Done"].click()

        // A folder arrives open, so its children are already on screen.
        XCTAssertTrue(main.staticTexts["web-01"].waitForExistence(timeout: 5),
                      "A connection inside an open folder must be in the sidebar.")
        main.staticTexts["web-01"].rightClick()
        edit = app.menuItems["Edit…"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(
            sheet.staticTexts["from Prod"].waitForExistence(timeout: 5),
            "An inherited field must name the folder it came from."
        )
        sheet.buttons["Done"].click()
    }

    /// The session commands and the tab bar, one launch: Browse Files needs a
    /// selection, and a double click opens a drawn tab.
    func testSessionMenuAndTabs() {
        let app = launchApp()
        let main = window(of: app)
        unlock(main)
        XCTAssertTrue(main.staticTexts["laptop"].waitForExistence(timeout: 10))

        // Before anything is opened there is nothing to show.
        XCTAssertTrue(main.staticTexts["No session"].exists,
                      "With no tab open the detail area says so.")

        // With nothing chosen, browsing files makes no sense.
        let sessionMenu = app.menuBars.menuBarItems["Session"]
        XCTAssertTrue(sessionMenu.waitForExistence(timeout: 10))
        sessionMenu.click()
        let browseItem = sessionMenu.menuItems["Browse Files"]
        XCTAssertTrue(browseItem.waitForExistence(timeout: 5),
                      "The Session menu must offer the file browser.")
        XCTAssertFalse(browseItem.isEnabled,
                       "Browsing files needs a connection to be chosen first.")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        // Once a connection is chosen, it becomes available.
        main.staticTexts["laptop"].click()
        sessionMenu.click()
        XCTAssertTrue(sessionMenu.menuItems["Browse Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(sessionMenu.menuItems["Browse Files"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        // A double click opens a tab, the way a double click opens a file.
        main.staticTexts["laptop"].doubleClick()

        // Ask for the tab by name. Looking for the text "laptop" would find
        // the sidebar row instead, and pass even with an empty tab bar.
        // The identifier sits on a row of views, so several elements carry it.
        let tab = main.descendants(matching: .any)
            .matching(identifier: "tab-laptop").firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10),
                      "A double click must open a tab for the connection.")
        XCTAssertTrue(tab.frame.height > 1 && tab.frame.width > 1,
                      "The tab must be drawn, not laid out with no size.")
        XCTAssertFalse(main.staticTexts["No session"].exists,
                       "The detail area must show the tab now.")
    }
}
