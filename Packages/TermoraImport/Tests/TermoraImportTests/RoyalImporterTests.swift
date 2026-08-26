import Foundation
import Testing
@testable import TermoraImport
@testable import TermoraModel

// A small document in the exact shape Royal TSX writes: one flat list of typed
// objects joined by ParentID.
private let sampleXML = """
<?xml version="1.0" encoding="utf-8"?>
<RTSZDocument>
  <RoyalDocument>
    <ID>doc-1</ID>
    <Name>My Connections</Name>
    <DeletedObjectHistory />
  </RoyalDocument>
  <RoyalTrash>
    <ID>trash-1</ID>
    <Name>Trash</Name>
    <ParentID>doc-1</ParentID>
  </RoyalTrash>
  <RoyalFolder>
    <ID>folder-1</ID>
    <Name>Prod</Name>
    <ParentID>doc-1</ParentID>
    <PositionNr>0</PositionNr>
    <IsExpanded>True</IsExpanded>
    <CredentialMode>2</CredentialMode>
    <CredentialFromParent>False</CredentialFromParent>
    <CredentialUsername>root</CredentialUsername>
    <ColorFromParent>False</ColorFromParent>
    <Color>#CE3838</Color>
  </RoyalFolder>
  <RoyalSSHConnection>
    <ID>conn-inherits</ID>
    <Name>web-01</Name>
    <ParentID>folder-1</ParentID>
    <PositionNr>0</PositionNr>
    <URI>web01.example.com</URI>
    <Port>22</Port>
    <CredentialMode>1</CredentialMode>
    <CredentialFromParent>True</CredentialFromParent>
    <ColorFromParent>True</ColorFromParent>
    <IsTelnetConnection>False</IsTelnetConnection>
    <IsSerialPortConnection>False</IsSerialPortConnection>
  </RoyalSSHConnection>
  <RoyalSSHConnection>
    <ID>conn-password</ID>
    <Name>db-01</Name>
    <ParentID>folder-1</ParentID>
    <PositionNr>1</PositionNr>
    <URI>db01.example.com</URI>
    <Port>2222</Port>
    <CredentialMode>2</CredentialMode>
    <CredentialFromParent>False</CredentialFromParent>
    <CredentialUsername>deploy</CredentialUsername>
    <CredentialPassword>ENCRYPTEDBLOB</CredentialPassword>
    <Favorite>True</Favorite>
    <KeepAliveInterval>30</KeepAliveInterval>
    <SSHEnableCompression>True</SSHEnableCompression>
  </RoyalSSHConnection>
  <RoyalSSHConnection>
    <ID>conn-both</ID>
    <Name>app-01</Name>
    <ParentID>folder-1</ParentID>
    <PositionNr>2</PositionNr>
    <URI>app01.example.com</URI>
    <CredentialMode>2</CredentialMode>
    <CredentialFromParent>False</CredentialFromParent>
    <CredentialUsername>fab</CredentialUsername>
    <CredentialPassword>ENCRYPTEDBLOB</CredentialPassword>
    <PrivateKeyPath>/Users/fab/.ssh/id_rsa</PrivateKeyPath>
    <CredentialKeyFile>/Users/fab/.ssh/id_rsa</CredentialKeyFile>
  </RoyalSSHConnection>
  <RoyalSSHConnection>
    <ID>conn-telnet</ID>
    <Name>old-switch</Name>
    <ParentID>folder-1</ParentID>
    <URI>switch.example.com</URI>
    <IsTelnetConnection>True</IsTelnetConnection>
  </RoyalSSHConnection>
  <RoyalSSHConnection>
    <ID>conn-deleted</ID>
    <Name>gone</Name>
    <ParentID>trash-1</ParentID>
    <URI>gone.example.com</URI>
  </RoyalSSHConnection>
</RTSZDocument>
"""

private func parseSample() throws -> [RoyalObject] {
    try RoyalDocumentParser().parse(data: Data(sampleXML.utf8))
}

@Test("The parser reads every object and its fields")
func parsesObjects() throws {
    let objects = try parseSample()
    // The document object, the trash, one folder, and five connections.
    #expect(objects.count == 8)
    #expect(objects.filter { $0.type == "RoyalSSHConnection" }.count == 5)

    let folder = try #require(objects.first { $0.type == "RoyalFolder" })
    #expect(folder.name == "Prod")
    #expect(folder.string("CredentialUsername") == "root")
    #expect(folder.bool("IsExpanded"))
    #expect(folder.int("PositionNr") == 0)
}

@Test("A file that is not a Royal document is refused")
func refusesForeignFiles() {
    #expect(throws: RoyalParseError.notARoyalDocument) {
        _ = try RoyalDocumentParser().parse(data: Data("<?xml version=\"1.0\"?><other/>".utf8))
    }
}

@Test("The tree is rebuilt, and the top level sits under no folder")
func rebuildsTheTree() throws {
    let (document, report) = RoyalImporter().makeDocument(from: try parseSample())
    let index = DocumentIndex(document)

    #expect(report.foldersCreated == 1)
    #expect(report.connectionsCreated == 3)

    let folder = try #require(document.folders.first)
    #expect(folder.parentID == nil, "A child of the document object belongs at the top level.")
    #expect(index.children(of: nil).map(\.name) == ["Prod"])
    #expect(index.children(of: folder.id).map(\.name) == ["web-01", "db-01", "app-01"])
}

@Test("Inheritance is carried across, not flattened")
func carriesInheritance() throws {
    let (document, _) = RoyalImporter().makeDocument(from: try parseSample())
    let index = DocumentIndex(document)

    let web = try #require(document.connections.first { $0.name == "web-01" })
    #expect(web.settings.username == .inherit, "CredentialFromParent must become .inherit.")
    #expect(web.settings.colorTag == .inherit)

    // And the value still arrives from the folder.
    let settings = index.effectiveSettings(for: web)
    #expect(settings.username == "root")
    #expect(settings.colorTag == .red, "#CE3838 is closest to red.")

    let db = try #require(document.connections.first { $0.name == "db-01" })
    #expect(db.settings.username == .value("deploy"))
}

@Test("Ordinary fields come across")
func carriesPlainFields() throws {
    let (document, _) = RoyalImporter().makeDocument(from: try parseSample())

    let db = try #require(document.connections.first { $0.name == "db-01" })
    #expect(db.host == "db01.example.com")
    #expect(db.port == 2222)
    #expect(db.isFavorite)
    #expect(db.settings.keepAliveSeconds == .value(30))
    #expect(db.settings.compression == .value(true))

    let web = try #require(document.connections.first { $0.name == "web-01" })
    #expect(web.port == 22, "A missing port must become 22.")
    #expect(web.settings.compression == .inherit, "A field Royal did not write must inherit.")
}

@Test("Telnet and trashed entries are left out, and the report says so")
func skipsWhatItCannotImport() throws {
    let (document, report) = RoyalImporter().makeDocument(from: try parseSample())

    #expect(!document.connections.contains { $0.name == "old-switch" })
    #expect(!document.connections.contains { $0.name == "gone" })

    #expect(report.skipped.contains { $0.connectionName == "old-switch" })
    #expect(report.skipped.contains { $0.connectionName == "gone" && $0.text.contains("trash") })
}

@Test("A password is imported when Royal TSX hands it over")
func importsRecoveredSecrets() throws {
    let secrets = RoyalImporter.RecoveredSecrets(passwords: ["conn-password": "hunter2"])
    let (document, report) = RoyalImporter().makeDocument(from: try parseSample(), secrets: secrets)

    let db = try #require(document.connections.first { $0.name == "db-01" })
    #expect(db.settings.authentication == .value(.password(Secret("hunter2"))))
    #expect(report.secretsRecovered == 1)
    #expect(!report.missingSecrets.contains { $0.connectionName == "db-01" })
}

@Test("A password Royal TSX withheld is named in the report, not lost quietly")
func reportsMissingSecrets() throws {
    let (document, report) = RoyalImporter().makeDocument(from: try parseSample())

    let db = try #require(document.connections.first { $0.name == "db-01" })
    #expect(db.settings.authentication == .value(.password(Secret(""))))
    #expect(report.missingSecrets.contains { $0.connectionName == "db-01" })
}

@Test("An entry with no stored credentials lets OpenSSH decide")
func fallsBackToSSHConfig() throws {
    let objects = try parseSample()
    // web-01 inherits, so use a copy that carries its own empty credentials.
    let bare = RoyalObject(type: "RoyalSSHConnection", fields: [
        "ID": "bare", "Name": "bare", "ParentID": "doc-1",
        "URI": "bare.example.com", "CredentialMode": "2",
        "CredentialFromParent": "False", "CredentialUsername": "fab",
    ])
    let (document, _) = RoyalImporter().makeDocument(from: objects + [bare])

    let connection = try #require(document.connections.first { $0.name == "bare" })
    #expect(connection.settings.authentication == .value(.sshConfig))
    #expect(connection.settings.username == .value("fab"))
}

@Test("When an entry has both a key and a password, the choice is yours and the report says what was left out")
func handlesBothCredentials() throws {
    let objects = try parseSample()
    let secrets = RoyalImporter.RecoveredSecrets(passwords: ["conn-both": "hunter2"])

    let keepingPassword = RoyalImporter(options: ImportOptions(whenBothCredentialsExist: .keepPassword))
        .makeDocument(from: objects, secrets: secrets)
    let app = try #require(keepingPassword.document.connections.first { $0.name == "app-01" })
    #expect(app.settings.authentication == .value(.password(Secret("hunter2"))))
    #expect(keepingPassword.report.notImported.contains {
        $0.connectionName == "app-01" && $0.text.contains("id_rsa")
    }, "The report must name the key that was left out.")

    let keepingKey = RoyalImporter(options: ImportOptions(whenBothCredentialsExist: .keepPrivateKey))
        .makeDocument(from: objects, secrets: secrets)
    let sameApp = try #require(keepingKey.document.connections.first { $0.name == "app-01" })
    #expect(sameApp.settings.authentication
        == .value(.privateKey(path: "/Users/fab/.ssh/id_rsa", passphrase: Secret(""))))
    #expect(keepingKey.report.notImported.contains {
        $0.connectionName == "app-01" && $0.text.contains("password")
    })
}

@Test("Every imported identifier is new, so a second import cannot collide")
func makesFreshIdentifiers() throws {
    let objects = try parseSample()
    let first = RoyalImporter().makeDocument(from: objects).document
    let second = RoyalImporter().makeDocument(from: objects).document

    let firstIDs = Set(first.connections.map(\.id) + first.folders.map(\.id))
    let secondIDs = Set(second.connections.map(\.id) + second.folders.map(\.id))
    #expect(firstIDs.isDisjoint(with: secondIDs))
}

// Royal writes the text of a key sequence into the entry, but keeps tasks and
// named sequences in a different document. These tests hold that difference.
private let sequenceXML = """
<?xml version="1.0" encoding="utf-8"?>
<RTSZDocument>
  <RoyalDocument><ID>doc-1</ID><Name>Doc</Name></RoyalDocument>
  <RoyalSSHConnection>
    <ID>c-on</ID><Name>with-sequence</Name><ParentID>doc-1</ParentID>
    <URI>a.example.com</URI>
    <KeySequence>cd /opt/maho/app{ENTER}</KeySequence>
    <KeySequenceEnabled>True</KeySequenceEnabled>
    <KeySequenceFromParent>False</KeySequenceFromParent>
  </RoyalSSHConnection>
  <RoyalSSHConnection>
    <ID>c-off</ID><Name>sequence-off</Name><ParentID>doc-1</ParentID>
    <URI>b.example.com</URI>
    <KeySequence>cd /opt/maho/app{ENTER}</KeySequence>
    <KeySequenceEnabled>False</KeySequenceEnabled>
    <KeySequenceFromParent>False</KeySequenceFromParent>
  </RoyalSSHConnection>
  <RoyalSSHConnection>
    <ID>c-named</ID><Name>named-sequence</Name><ParentID>doc-1</ParentID>
    <URI>c.example.com</URI>
    <KeySequenceName>su root</KeySequenceName>
    <KeySequenceId>52207f74-eda5-4d3b-8f4f-320c49f06d59</KeySequenceId>
  </RoyalSSHConnection>
  <RoyalSSHConnection>
    <ID>c-task</ID><Name>with-task</Name><ParentID>doc-1</ParentID>
    <URI>d.example.com</URI>
    <PreConnectTaskName>Add IP to MahoCloudFirewall</PreConnectTaskName>
    <PreConnectTaskId>00000000-0000-0000-0000-000000000000</PreConnectTaskId>
  </RoyalSSHConnection>
  <RoyalSSHConnection>
    <ID>c-plain</ID><Name>plain</Name><ParentID>doc-1</ParentID>
    <URI>e.example.com</URI>
    <PreConnectTaskId>00000000-0000-0000-0000-000000000000</PreConnectTaskId>
    <PostDisconnectTaskId>00000000-0000-0000-0000-000000000000</PostDisconnectTaskId>
  </RoyalSSHConnection>
</RTSZDocument>
"""

@Test("A key sequence written in the entry is imported and will be typed")
func importsKeySequences() throws {
    let objects = try RoyalDocumentParser().parse(data: Data(sequenceXML.utf8))
    let (document, _) = RoyalImporter().makeDocument(from: objects)

    let on = try #require(document.connections.first { $0.name == "with-sequence" })
    #expect(on.settings.afterConnectText == .value("cd /opt/maho/app{ENTER}"))
    #expect(KeySequence.steps(from: "cd /opt/maho/app{ENTER}")
        == [.text("cd /opt/maho/app"), .text("\r")])
}

@Test("A sequence switched off in Royal stays off, and its text is kept in the notes")
func keepsDisabledSequences() throws {
    let objects = try RoyalDocumentParser().parse(data: Data(sequenceXML.utf8))
    let (document, report) = RoyalImporter().makeDocument(from: objects)

    let off = try #require(document.connections.first { $0.name == "sequence-off" })
    #expect(off.settings.afterConnectText == .inherit, "An entry switched off must not type.")
    #expect(off.notes.contains("cd /opt/maho/app{ENTER}"), "The text must not be lost.")
    #expect(report.notImported.contains { $0.connectionName == "sequence-off" })
}

@Test("A sequence kept in another Royal document is named, not invented")
func reportsNamedSequences() throws {
    let objects = try RoyalDocumentParser().parse(data: Data(sequenceXML.utf8))
    let (document, report) = RoyalImporter().makeDocument(from: objects)

    let named = try #require(document.connections.first { $0.name == "named-sequence" })
    #expect(named.settings.afterConnectText == .inherit)
    #expect(report.notImported.contains {
        $0.connectionName == "named-sequence" && $0.text.contains("su root")
    }, "The report must name the sequence Termora could not read.")
}

@Test("A task whose commands are not on this Mac is named in the report")
func reportsTasksByName() throws {
    let objects = try RoyalDocumentParser().parse(data: Data(sequenceXML.utf8))
    let (_, report) = RoyalImporter().makeDocument(from: objects)

    #expect(report.notImported.contains {
        $0.connectionName == "with-task"
            && $0.text.contains("Add IP to MahoCloudFirewall")
            && $0.text.contains("did not find its commands")
    }, "The report must name the task and say why it cannot run.")

    // An entry whose task identifier is all zeros has no task at all.
    #expect(!report.notImported.contains { $0.connectionName == "plain" },
            "An empty identifier must not be reported as a missing task.")
}

@Test("An identifier of all zeros means nothing, not something")
func recognisesEmptyIdentifiers() {
    #expect(!RoyalImporter.isRealIdentifier("00000000-0000-0000-0000-000000000000"))
    #expect(!RoyalImporter.isRealIdentifier(""))
    #expect(RoyalImporter.isRealIdentifier("52207f74-eda5-4d3b-8f4f-320c49f06d59"))
}
