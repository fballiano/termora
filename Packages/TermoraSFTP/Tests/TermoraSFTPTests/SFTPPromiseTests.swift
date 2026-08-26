import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TermoraSFTP

private func entry(_ name: String, permissions: UInt32, path: String? = nil) -> SFTPEntry {
    SFTPEntry(
        name: name,
        path: path ?? "/remote/\(name)",
        longName: "",
        attributes: SFTPAttributes(size: 10, permissions: permissions)
    )
}

private let file: UInt32 = 0o100_644
private let folder: UInt32 = 0o040_755
private let link: UInt32 = 0o120_777

@Test("Every dragged row gets its own promise")
func onePromisePerRow() {
    let rows = [
        entry("first.txt", permissions: file),
        entry("second.log", permissions: file),
        entry("project", permissions: folder),
    ]
    let promises = SFTPPromise.descriptors(for: rows)

    #expect(promises.count == 3, "Dragging three rows must hand over three promises.")
    #expect(promises.map(\.fileName) == ["first.txt", "second.log", "project"])
    // Each promise must point at its own file, or every one would copy the same.
    #expect(Set(promises.map { $0.userInfo[SFTPPromise.pathKey] }).count == 3)
}

@Test("A folder is announced as a folder, so Finder copies it whole")
func foldersAreAnnouncedAsFolders() throws {
    let promise = try #require(SFTPPromise.descriptor(for: entry("project", permissions: folder)))
    #expect(promise.typeIdentifier == UTType.folder.identifier)
}

@Test("A file is announced by its kind, so Finder gives it the right icon")
func filesUseTheirOwnKind() throws {
    let text = try #require(SFTPPromise.descriptor(for: entry("notes.txt", permissions: file)))
    #expect(text.typeIdentifier == UTType.plainText.identifier)

    // A name with no ending, or one nobody knows, is still offered as data.
    let unknown = try #require(SFTPPromise.descriptor(for: entry("dump", permissions: file)))
    #expect(unknown.typeIdentifier == UTType.data.identifier)
}

@Test("A link is not offered, because a copy would not follow it either")
func linksAreNotDragged() {
    #expect(SFTPPromise.descriptor(for: entry("loop", permissions: link)) == nil)

    let mixed = [
        entry("real.txt", permissions: file),
        entry("loop", permissions: link),
        entry("also-real.txt", permissions: file),
    ]
    let promises = SFTPPromise.descriptors(for: mixed)
    #expect(promises.map(\.fileName) == ["real.txt", "also-real.txt"],
            "The rows that can be dragged still are.")
}

@Test("The name and the path travel with the promise")
func userInfoCarriesWhatTheCallbacksNeed() throws {
    let promise = try #require(SFTPPromise.descriptor(
        for: entry("report.pdf", permissions: file, path: "/var/reports/report.pdf")
    ))
    #expect(SFTPPromise.fileName(from: promise.userInfo) == "report.pdf")
    #expect(SFTPPromise.path(from: promise.userInfo) == "/var/reports/report.pdf")

    // Anything else gives nothing, rather than a wrong answer.
    #expect(SFTPPromise.fileName(from: nil) == nil)
    #expect(SFTPPromise.path(from: "a string") == nil)
}
