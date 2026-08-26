//
//  ImportSheetTests.swift
//  TermoraUITests
//

import TermoraModel
import TermoraVault
import XCTest

/// Opens the import sheet through the real menu and checks what it offers.
///
/// The file chooser itself belongs to macOS, so the test stops before it. The
/// mapping from a Royal document to a Termora document is covered by the
/// TermoraImport tests, which run against a real Royal TSX file.
final class ImportSheetTests: XCTestCase {
    private static let password = "test master password"
    private var documentURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termora-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        documentURL = directory.appendingPathComponent("Fixture.termora")
        _ = try await Vault.create(at: documentURL, password: Self.password)
    }

    override func tearDown() async throws {
        if let directory = documentURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    func testImportSheetOffersTheChoiceThatLosesNothing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TermoraLastDocumentPath", documentURL.path]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))

        let field = window.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("\(Self.password)\r")

        // The command lives in the File menu.
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10))
        fileMenu.click()

        let importItem = fileMenu.menuItems["Import from Royal TSX…"]
        XCTAssertTrue(importItem.waitForExistence(timeout: 5),
                      "The File menu must offer the Royal TSX import.")
        XCTAssertTrue(importItem.isEnabled, "The import must be available once unlocked.")
        importItem.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "The import sheet must appear.")

        // The sheet must promise that nothing already in the document is lost.
        XCTAssertTrue(
            sheet.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@", "Nothing already in it is removed")
            ).firstMatch.exists,
            "The sheet must say that the import adds to the open document."
        )

        // And it must offer the choice for entries that hold both credentials.
        XCTAssertTrue(
            sheet.radioButtons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Keep the password")
            ).firstMatch.exists,
            "The sheet must let you choose which credential survives."
        )
        // Keeping the password is the default, because a key path is not a
        // secret and can be typed in again, while a password cannot.
        XCTAssertEqual(
            sheet.radioButtons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Keep the password")
            ).firstMatch.value as? Int, 1
        )
        XCTAssertTrue(
            sheet.radioButtons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Keep the private key")
            ).firstMatch.exists
        )

        // Import stays out of reach until a document is chosen.
        let importButton = sheet.buttons["Import"]
        XCTAssertTrue(importButton.exists)
        XCTAssertFalse(importButton.isEnabled,
                       "Import must wait until a Royal TSX document is chosen.")

        sheet.buttons["Cancel"].click()
    }
}
