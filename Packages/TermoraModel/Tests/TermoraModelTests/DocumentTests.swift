import Foundation
import Testing
@testable import TermoraModel

@Test("Removing a folder removes everything inside it")
func removingAFolderRemovesItsContents() {
    let outer = Folder(name: "Outer")
    let inner = Folder(parentID: outer.id, name: "Inner")
    let kept = Folder(name: "Kept")
    var document = Document(
        folders: [outer, inner, kept],
        connections: [
            Connection(parentID: inner.id, name: "deep", host: "a"),
            Connection(parentID: outer.id, name: "shallow", host: "b"),
            Connection(parentID: kept.id, name: "safe", host: "c"),
        ]
    )

    document.remove(id: outer.id)

    #expect(document.folders.map(\.name) == ["Kept"])
    #expect(document.connections.map(\.name) == ["safe"])
}

@Test("A folder cannot be moved inside itself")
func refusesToMoveAFolderIntoItself() {
    let outer = Folder(name: "Outer")
    let inner = Folder(parentID: outer.id, name: "Inner")
    var document = Document(folders: [outer, inner])

    #expect(document.move(id: outer.id, toParent: inner.id, position: 0) == false)
    #expect(document.move(id: outer.id, toParent: outer.id, position: 0) == false)
    #expect(document.folders.first { $0.id == outer.id }?.parentID == nil)

    // Moving the other way is allowed.
    #expect(document.move(id: inner.id, toParent: nil, position: 0) == true)
}

@Test("Children come back in the order their positions give, folder or not")
func childOrdering() {
    // A folder does not come first because it is a folder. You place it, the
    // way you place it in Royal TSX.
    let folder = Folder(name: "Zulu", position: 5)
    let document = Document(
        folders: [folder],
        connections: [
            Connection(name: "second", position: 1, host: "b"),
            Connection(name: "first", position: 0, host: "a"),
        ]
    )

    let names = DocumentIndex(document).children(of: nil).map(\.name)
    #expect(names == ["first", "second", "Zulu"])
}

@Test("Renumbering gives the children of each parent positions 0, 1, 2")
func renumberPositions() {
    let folder = Folder(name: "Folder")
    var document = Document(
        folders: [folder],
        connections: [
            Connection(parentID: folder.id, name: "b", position: 40, host: "b"),
            Connection(parentID: folder.id, name: "a", position: 10, host: "a"),
        ]
    )

    document.renumberPositions()

    let index = DocumentIndex(document)
    #expect(index.children(of: folder.id).map(\.position) == [0, 1])
    #expect(index.children(of: folder.id).map(\.name) == ["a", "b"])
}

@Test("A document survives a round trip through JSON")
func jsonRoundTrip() throws {
    let folder = Folder(name: "Prod", settings: NodeSettings(username: .value("root")))
    let connection = Connection(
        parentID: folder.id,
        name: "web-01",
        host: "web01.example.com",
        settings: NodeSettings(authentication: .value(.password(Secret("hunter2")))),
        forwards: [PortForward(kind: .local, listenPort: 8080,
                               destinationHost: "localhost", destinationPort: 80)]
    )
    let original = Document(folders: [folder], connections: [connection])

    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(Document.self, from: data)

    #expect(restored == original)
}

@Test("An inherited field is written as null, and a set field as its value")
func inheritedEncodesAsNull() throws {
    let encoder = JSONEncoder()
    #expect(String(data: try encoder.encode(Inherited<String>.inherit), encoding: .utf8) == "null")
    #expect(String(data: try encoder.encode(Inherited<String>.value("root")), encoding: .utf8) == "\"root\"")
}

@Test("A secret never prints its value")
func secretIsRedactedInDescriptions() {
    let secret = Secret("hunter2")
    #expect("\(secret)" == "<redacted>")
    #expect(String(describing: secret) == "<redacted>")
    #expect("\(Secret.empty)" == "<empty>")
    // The value is still readable where it is needed.
    #expect(secret.value == "hunter2")
}

@Test("A tunnel describes itself in one line")
func forwardSummary() {
    let local = PortForward(kind: .local, listenPort: 8080,
                            destinationHost: "localhost", destinationPort: 80)
    #expect(local.summary == "localhost:8080 → localhost:80")

    let bound = PortForward(kind: .local, bindAddress: "0.0.0.0", listenPort: 8080,
                            destinationHost: "web", destinationPort: 80)
    #expect(bound.summary == "0.0.0.0:8080 → web:80")

    #expect(PortForward(kind: .dynamic, listenPort: 1080).summary == "SOCKS on localhost:1080")
}

@Test("A tunnel that OpenSSH would refuse is caught first")
func forwardValidation() {
    let good = PortForward(kind: .local, listenPort: 8080,
                           destinationHost: "localhost", destinationPort: 80)
    #expect(good.isReady)
    #expect(good.problem == nil)

    var badPort = good
    badPort.listenPort = 0
    #expect(badPort.problem?.contains("listening port") == true)

    var noHost = good
    noHost.destinationHost = "  "
    #expect(noHost.problem?.contains("far end") == true)

    var badFarPort = good
    badFarPort.destinationPort = 70000
    #expect(badFarPort.problem?.contains("port of the far end") == true)

    // A SOCKS proxy needs no far end at all.
    #expect(PortForward(kind: .dynamic, listenPort: 1080).isReady)
    #expect(!PortForward(kind: .dynamic, listenPort: 0).isReady)
}

@Test("Two tunnels that listen on the same port are reported")
func clashingForwards() {
    let first = PortForward(kind: .local, listenPort: 8080,
                            destinationHost: "a", destinationPort: 80)
    let second = PortForward(kind: .local, listenPort: 8080,
                             destinationHost: "b", destinationPort: 90)
    let other = PortForward(kind: .local, listenPort: 9090,
                            destinationHost: "c", destinationPort: 90)

    var connection = Connection(name: "host", host: "host", forwards: [first, second, other])
    #expect(connection.clashingForwardIDs == [first.id, second.id])

    // A tunnel that is switched off cannot clash with anything.
    connection.forwards[1].isEnabled = false
    #expect(connection.clashingForwardIDs.isEmpty)

    // A local and a remote tunnel may use the same number, because the
    // listeners are on different machines.
    let remote = PortForward(kind: .remote, listenPort: 8080,
                             destinationHost: "d", destinationPort: 80)
    let mixed = Connection(name: "host", host: "host", forwards: [first, remote])
    #expect(mixed.clashingForwardIDs.isEmpty)
}

@Test("A key sequence is read the way Royal TSX writes it")
func decodesKeySequences() {
    // The sequence in the real document.
    #expect(KeySequence.steps(from: "cd /opt/maho/app{ENTER}")
        == [.text("cd /opt/maho/app"), .text("\r")])

    #expect(KeySequence.steps(from: "su root{ENTER}{DELAY:500}password{ENTER}")
        == [.text("su root"), .text("\r"), .wait(milliseconds: 500),
            .text("password"), .text("\r")])

    #expect(KeySequence.steps(from: "plain text") == [.text("plain text")])
    #expect(KeySequence.steps(from: "").isEmpty)
    #expect(KeySequence.isEmpty(""))
}

@Test("A name nobody knows is kept as it stands, not swallowed")
func keepsUnknownKeyNames() {
    #expect(KeySequence.steps(from: "echo {NOPE} done")
        == [.text("echo {NOPE} done")], "An unknown name must survive as text.")

    // A brace with no closing brace is ordinary text too.
    #expect(KeySequence.steps(from: "awk {print $1}")
        == [.text("awk {print $1}")])
    #expect(KeySequence.steps(from: "unclosed {ENTER") == [.text("unclosed {ENTER")])
}

@Test("A wait cannot hold a session for ever")
func clampsWaits() {
    #expect(KeySequence.steps(from: "{DELAY:999999}")
        == [.wait(milliseconds: KeySequence.maximumWaitMilliseconds)])
    #expect(KeySequence.steps(from: "{DELAY:-5}") == [.wait(milliseconds: 0)])
}

@Test("Text typed after connecting is inherited like every other setting")
func afterConnectTextInherits() {
    let folder = Folder(name: "Maho", settings: NodeSettings(
        afterConnectText: .value("cd /opt/maho/app{ENTER}")
    ))
    let child = Connection(parentID: folder.id, name: "web", host: "web")
    let own = Connection(parentID: folder.id, name: "db", host: "db",
                         settings: NodeSettings(afterConnectText: .value("")))

    let index = DocumentIndex(Document(folders: [folder], connections: [child, own]))
    #expect(index.effectiveSettings(for: child).afterConnectText == "cd /opt/maho/app{ENTER}")
    #expect(index.effectiveSettings(for: own).afterConnectText.isEmpty,
            "A connection may switch the folder's sequence off.")
}

// MARK: - Moving nodes, the way a drag in the sidebar does

@Suite("Moving a node")
struct MoveTests {
    /// A tree: two folders at the top, one bookmark in each.
    private func tree() -> (Document, Folder, Folder, Connection, Connection) {
        let left = Folder(name: "Left", position: 0)
        let right = Folder(name: "Right", position: 1)
        let one = Connection(parentID: left.id, name: "one", position: 0, host: "a")
        let two = Connection(parentID: right.id, name: "two", position: 0, host: "b")
        return (Document(folders: [left, right], connections: [one, two]), left, right, one, two)
    }

    @Test("A bookmark moves into another folder")
    func movesIntoAFolder() {
        var (document, _, right, one, _) = tree()
        let moved = document.move(id: one.id, toParent: right.id, position: .max)
        #expect(moved)
        document.renumberPositions()

        let index = DocumentIndex(document)
        #expect(index.children(of: right.id).map(\.name).sorted() == ["one", "two"])
        #expect(index.children(of: right.id).count == 2)
    }

    @Test("A bookmark moves to the top level")
    func movesToTheTop() {
        var (document, _, _, one, _) = tree()
        let moved = document.move(id: one.id, toParent: nil, position: .max)
        #expect(moved)
        document.renumberPositions()
        #expect(DocumentIndex(document).children(of: nil).map(\.name).contains("one"))
    }

    @Test("A folder cannot be put inside itself")
    func refusesItself() {
        var (document, left, _, _, _) = tree()
        let moved = document.move(id: left.id, toParent: left.id, position: 0)
        #expect(!moved)
    }

    @Test("A folder cannot be put inside one of its own children")
    func refusesAChild() {
        var (document, left, _, _, _) = tree()
        let inner = Folder(parentID: left.id, name: "Inner")
        document.add(inner)
        let moved = document.move(id: left.id, toParent: inner.id, position: 0)
        #expect(!moved, "That would cut the folder off from the tree.")
    }

    @Test("A move leaves the positions in order")
    func keepsPositionsTidy() {
        var (document, left, _, _, two) = tree()
        let three = Connection(parentID: left.id, name: "three", position: 5, host: "c")
        document.add(three)
        let moved = document.move(id: two.id, toParent: left.id, position: 1)
        #expect(moved)
        document.renumberPositions()

        let positions = DocumentIndex(document).children(of: left.id).map(\.position)
        #expect(positions == Array(0 ..< positions.count),
                "Positions must be 0, 1, 2 after a move.")
    }
}

@Suite("Where a drop lands")
struct DropPlacementTests {
    @Test("A folder row keeps a band in the middle for dropping inside")
    func readsAFolderRow() {
        #expect(DropPlacement.at(fraction: 0.0, isFolder: true) == .before)
        #expect(DropPlacement.at(fraction: 0.2, isFolder: true) == .before)
        #expect(DropPlacement.at(fraction: 0.5, isFolder: true) == .inside)
        #expect(DropPlacement.at(fraction: 0.8, isFolder: true) == .after)
        #expect(DropPlacement.at(fraction: 1.0, isFolder: true) == .after)
    }

    @Test("A bookmark row splits in two, because it has no inside")
    func readsABookmarkRow() {
        #expect(DropPlacement.at(fraction: 0.1, isFolder: false) == .before)
        #expect(DropPlacement.at(fraction: 0.9, isFolder: false) == .after)
        #expect(DropPlacement.at(fraction: 0.5, isFolder: false) == .after)
    }

    @Test("A fraction outside the row is held at its ends")
    func holdsTheEnds() {
        #expect(DropPlacement.at(fraction: -3, isFolder: true) == .before)
        #expect(DropPlacement.at(fraction: 9, isFolder: true) == .after)
    }
}

@Suite("Dropping next to a row")
struct RelativeMoveTests {
    /// One folder holding three bookmarks, in order.
    private func tree() -> (Document, Folder, [Connection]) {
        let folder = Folder(name: "Group", position: 0)
        let items = (0 ..< 3).map {
            Connection(parentID: folder.id, name: "item\($0)", position: $0, host: "h\($0)")
        }
        return (Document(folders: [folder], connections: items), folder, items)
    }

    private func names(_ document: Document, in parent: UUID?) -> [String] {
        DocumentIndex(document).children(of: parent).map(\.name)
    }

    @Test("A bookmark lands above the row it was dropped on")
    func landsBefore() {
        var (document, folder, items) = tree()
        let moved = document.move(id: items[2].id, relativeTo: items[0].id, placement: .before)
        #expect(moved)
        #expect(names(document, in: folder.id) == ["item2", "item0", "item1"])
    }

    @Test("A bookmark lands below the row it was dropped on")
    func landsAfter() {
        var (document, folder, items) = tree()
        let moved = document.move(id: items[0].id, relativeTo: items[1].id, placement: .after)
        #expect(moved)
        #expect(names(document, in: folder.id) == ["item1", "item0", "item2"])
    }

    @Test("A folder can be dropped anywhere in a list, not only first")
    func aFolderLandsWhereItIsDropped() {
        var (document, folder, items) = tree()
        let other = Folder(name: "Other", position: 1)
        document.add(other)

        let moved = document.move(id: other.id, relativeTo: items[1].id, placement: .after)
        #expect(moved)
        #expect(names(document, in: folder.id) == ["item0", "item1", "Other", "item2"],
                "A folder must land in the middle of a list, not at its head.")
    }

    @Test("Dropping into a folder puts the node at its end")
    func landsInside() {
        var (document, folder, items) = tree()
        let outside = Connection(name: "outside", position: 0, host: "x")
        document.add(outside)

        let moved = document.move(id: outside.id, relativeTo: folder.id, placement: .inside)
        #expect(moved)
        #expect(names(document, in: folder.id) == ["item0", "item1", "item2", "outside"])
        _ = items
    }

    @Test("Dropping inside something that is not a folder does nothing")
    func refusesInsideABookmark() {
        var (document, _, items) = tree()
        let moved = document.move(id: items[0].id, relativeTo: items[1].id, placement: .inside)
        #expect(!moved)
    }

    @Test("A node dropped on itself does nothing")
    func refusesItself() {
        var (document, _, items) = tree()
        let moved = document.move(id: items[0].id, relativeTo: items[0].id, placement: .after)
        #expect(!moved)
    }

    @Test("Every brother keeps its own place in the list after a move")
    func numbersStayUnique() {
        var (document, folder, items) = tree()
        _ = document.move(id: items[2].id, relativeTo: items[0].id, placement: .before)
        let positions = DocumentIndex(document).children(of: folder.id).map(\.position)
        #expect(positions == [0, 1, 2],
                "Two brothers sharing a position would leave the order to chance.")
    }
}

@Suite("What a delete would take")
struct FolderContentsTests {
    @Test("An empty folder holds nothing")
    func countsAnEmptyFolder() {
        let folder = Folder(name: "Empty")
        let held = DocumentIndex(Document(folders: [folder], connections: [])).contents(of: folder.id)
        #expect(held.folders == 0)
        #expect(held.connections == 0)
    }

    @Test("A folder counts everything below it, at every depth")
    func countsDeeply() {
        let top = Folder(name: "Top")
        let middle = Folder(parentID: top.id, name: "Middle")
        let bottom = Folder(parentID: middle.id, name: "Bottom")
        let document = Document(
            folders: [top, middle, bottom],
            connections: [
                Connection(parentID: top.id, name: "a", host: "a"),
                Connection(parentID: middle.id, name: "b", host: "b"),
                Connection(parentID: bottom.id, name: "c", host: "c"),
                Connection(name: "outside", host: "d"),
            ]
        )

        let held = DocumentIndex(document).contents(of: top.id)
        #expect(held.folders == 2, "Middle and Bottom go with Top.")
        #expect(held.connections == 3, "The bookmark outside Top is not counted.")
    }

    @Test("Counting ends even if a document names a parent loop")
    func survivesALoop() {
        var left = Folder(name: "Left")
        var right = Folder(name: "Right")
        left.parentID = right.id
        right.parentID = left.id
        let held = DocumentIndex(Document(folders: [left, right], connections: []))
            .contents(of: left.id)
        #expect(held.folders <= 2, "A loop must not make the count run for ever.")
    }
}
