import Foundation
import Testing
@testable import TermoraModel

/// A tree three levels deep:
///   Prod                      username = "root",  compression = true
///     └── Web                 username inherits,  colour = .blue
///           ├── web-01        everything inherits
///           └── web-02        username = "deploy"
private struct Fixture {
    let prod = Folder(name: "Prod", settings: NodeSettings(
        username: .value("root"),
        compression: .value(true)
    ))
    var web: Folder
    var webOne: Connection
    var webTwo: Connection
    var document: Document

    init() {
        web = Folder(parentID: prod.id, name: "Web", settings: NodeSettings(
            colorTag: .value(.blue)
        ))
        webOne = Connection(parentID: web.id, name: "web-01", host: "web01.example.com")
        webTwo = Connection(parentID: web.id, name: "web-02", host: "web02.example.com",
                            settings: NodeSettings(username: .value("deploy")))
        document = Document(folders: [prod, web], connections: [webOne, webTwo])
    }

    var index: DocumentIndex { DocumentIndex(document) }
}

@Test("An inherited field takes the value of the nearest ancestor that sets one")
func inheritsFromGrandparent() {
    let fixture = Fixture()
    let settings = fixture.index.effectiveSettings(for: fixture.webOne)
    #expect(settings.username == "root")
    #expect(settings.compression == true)
    #expect(settings.colorTag == .blue)
}

@Test("A value on the connection stops the search")
func ownValueStopsTheSearch() {
    let fixture = Fixture()
    let settings = fixture.index.effectiveSettings(for: fixture.webTwo)
    #expect(settings.username == "deploy")
    // The other fields still come from above.
    #expect(settings.compression == true)
    #expect(settings.colorTag == .blue)
}

@Test("A field that no ancestor sets falls back to the default")
func fallbackWhenNobodySetsTheField() {
    let fixture = Fixture()
    let settings = fixture.index.effectiveSettings(for: fixture.webOne)
    #expect(settings.keepAliveSeconds == EffectiveSettings.fallback.keepAliveSeconds)
    #expect(settings.hostKeyPolicy == .ask)
    #expect(settings.jumpHost.isEmpty)
}

@Test("The inspector can name the folder that supplies an inherited field")
func namesTheSourceFolder() {
    let fixture = Fixture()
    let index = fixture.index
    #expect(index.sourceFolder(of: \.username, for: fixture.webOne)?.name == "Prod")
    #expect(index.sourceFolder(of: \.colorTag, for: fixture.webOne)?.name == "Web")
    // web-02 sets its own username, so no folder supplies it.
    #expect(index.sourceFolder(of: \.username, for: fixture.webTwo) == nil)
}

@Test("A parent loop returns an answer instead of hanging")
func parentLoopTerminates() {
    var first = Folder(name: "First")
    var second = Folder(name: "Second")
    first.parentID = second.id
    second.parentID = first.id
    let connection = Connection(parentID: first.id, name: "looped", host: "example.com")
    let index = DocumentIndex(Document(folders: [first, second], connections: [connection]))

    let settings = index.effectiveSettings(for: connection)
    #expect(settings.username == EffectiveSettings.fallback.username)
    #expect(index.ancestors(ofParent: first.id).count == Document.maximumDepth)
}
