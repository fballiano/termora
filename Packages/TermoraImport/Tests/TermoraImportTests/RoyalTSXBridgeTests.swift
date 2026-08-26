import Foundation
import Testing
@testable import TermoraImport

@Test("A quote in a value cannot end the script and add commands")
func escapesQuotesAndBackslashes() {
    #expect(RoyalTSXBridge.escape("plain") == "plain")
    #expect(RoyalTSXBridge.escape("say \"hello\"") == "say \\\"hello\\\"")
    #expect(RoyalTSXBridge.escape("back\\slash") == "back\\\\slash")

    let injection = #"" & (do shell script "whoami") & ""#
    let script = RoyalTSXBridge.script(forKey: "CredentialPassword", objectID: injection)

    // The text is still there, but every quote in it is escaped, so it stays
    // one string instead of closing the string and adding a command.
    #expect(!script.contains(injection), "The raw injection must not survive.")
    #expect(script.contains(#"\" & (do shell script \"whoami\") & \""#))
}

@Test("The script asks the right application for the right property")
func buildsTheExpectedScript() {
    let script = RoyalTSXBridge.script(forKey: "CredentialPassphrase", objectID: "abc-123")
    #expect(script.contains("tell application \"Royal TSX\""))
    #expect(script.contains("get property value of key \"CredentialPassphrase\" from id \"abc-123\""))
}

@Test("Whether Royal TSX is installed matches what is on this Mac")
func reportsInstallation() {
    let onDisk = FileManager.default.fileExists(atPath: "/Applications/Royal TSX.app")
    if onDisk {
        #expect(RoyalTSXBridge.isInstalled)
    }
    // The other direction is not asserted: Royal TSX may sit elsewhere.
}

@Test("Opening the document waits for Royal TSX to settle")
func openScriptWaits() {
    let script = RoyalTSXBridge.openDocumentScript(path: "/tmp/My Doc.rtsz")
    #expect(script.contains("open document \"/tmp/My Doc.rtsz\""))
    #expect(script.contains("delay \(RoyalTSXBridge.settleSeconds)"),
            "Royal TSX answers nothing until the document has loaded.")
}
