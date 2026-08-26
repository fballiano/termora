//
//  TabSwitchDuringConnectTests.swift
//  TermoraUITests
//

import CoreGraphics
import TermoraModel
import TermoraVault
import XCTest

/// Reproduces the blank tab: open a session, open a second one, switch back
/// to the first while the second is still connecting, and return once it is
/// ready. The returned tab must draw its terminal.
///
/// The UI test runner may not bind a port, so the OpenSSH server runs
/// outside it, started by `Scripts/uitest-ssh.sh`. The script passes the
/// port and the key through the environment:
///
///   TERMORA_TEST_SSH_PORT   the port of a local sshd
///   TERMORA_TEST_SSH_KEY    a private key that sshd accepts, no passphrase
///
/// Without them the test is skipped. Run it with:
///
///   ./Scripts/uitest-ssh.sh TermoraUITests/TabSwitchDuringConnectTests
final class TabSwitchDuringConnectTests: XCTestCase {
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

        // `seq` fills the whole pane with text, so a screenshot of any part
        // of a drawn terminal is far from uniform.
        func settings(delaySeconds: Int) -> NodeSettings {
            NodeSettings(
                username: .value(NSUserName()),
                authentication: .value(.privateKey(
                    path: keyPath, passphrase: Secret("")
                )),
                hostKeyPolicy: .value(.acceptNew),
                afterConnectText: .value("seq 1 200{ENTER}"),
                beforeConnect: delaySeconds > 0
                    ? .value(LocalCommand(
                        name: "Wait", launchPath: "/bin/sleep",
                        arguments: "\(delaySeconds)"
                    ))
                    : .inherit
            )
        }

        let alpha = Connection(
            name: "alpha", host: "127.0.0.1", port: port,
            settings: settings(delaySeconds: 0)
        )
        // The delay holds the second tab in its opening phase long enough for
        // the test to switch away, the way a slow host does.
        let beta = Connection(
            name: "beta", host: "127.0.0.1", port: port,
            settings: settings(delaySeconds: 4)
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

    func testTabDrawsAfterSwitchingAwayDuringConnect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TermoraLastDocumentPath", documentURL.path]
        app.launchEnvironment["HOME"] = homeURL.path
        app.launch()

        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The application showed no window.")

        let field = main.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("\(Self.password)\r")
        XCTAssertTrue(main.staticTexts["alpha"].waitForExistence(timeout: 10))

        // Open alpha and let it draw: connect, settle, and print.
        main.staticTexts["alpha"].doubleClick()
        let alphaTab = main.descendants(matching: .any)
            .matching(identifier: "tab-alpha").firstMatch
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 10))
        sleep(6)
        XCTAssertTrue(paneHasContent(in: main),
                      "The first tab must draw its terminal before the test goes on.")

        // Open beta, and switch back to alpha while beta is still opening.
        main.staticTexts["beta"].doubleClick()
        let betaTab = main.descendants(matching: .any)
            .matching(identifier: "tab-beta").firstMatch
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5))
        alphaTab.click()

        // Beta finishes its delay, connects, and prints, all while hidden.
        sleep(12)

        // Return to beta. The pane must show the terminal, not an empty area.
        betaTab.click()
        sleep(2)
        XCTAssertTrue(paneHasContent(in: main),
                      "The tab that connected while hidden must draw its terminal.")
    }

    /// True when the pane area of the window holds drawn text.
    ///
    /// The patch starts at 30% of the width, clear of the sidebar, and at 12%
    /// of the height, clear of the title bar. A drawn terminal has thousands
    /// of dark text pixels there, starting with the shell prompt. The blank
    /// pane of this defect has none.
    private func paneHasContent(in window: XCUIElement) -> Bool {
        guard let image = window.screenshot().image
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            XCTFail("The screenshot produced no image.")
            return false
        }
        let dark = Self.darkPixelCount(
            of: image,
            in: CGRect(x: 0.30, y: 0.12, width: 0.68, height: 0.80)
        )
        return dark > 500
    }

    /// How many pixels inside a fractional rect are darker than mid-grey.
    private static func darkPixelCount(of image: CGImage, in fraction: CGRect) -> Int {
        let x = Int(CGFloat(image.width) * fraction.minX)
        let y = Int(CGFloat(image.height) * fraction.minY)
        let width = Int(CGFloat(image.width) * fraction.width)
        let height = Int(CGFloat(image.height) * fraction.height)

        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return 0 }

        context.draw(
            image,
            in: CGRect(x: -x, y: -(image.height - y - height),
                       width: image.width, height: image.height)
        )
        guard let data = context.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var dark = 0
        for index in 0 ..< (width * height) where pixels[index * 4 + 1] < 128 {
            dark += 1
        }
        return dark
    }
}
