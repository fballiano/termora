//
//  RoyalTaskTests.swift
//  TermoraImportTests
//

import Foundation
import TermoraModel
import Testing
@testable import TermoraImport

private let settingsXML = """
<?xml version="1.0" encoding="utf-8"?>
<RTSZDocument>
  <RoyalCommandTask>
    <ID>a1</ID>
    <Name>Ping</Name>
    <CommandLineOSX>ping</CommandLineOSX>
    <ArgumentsOSX>$URI$</ArgumentsOSX>
    <ExecuteInTerminalOSX>True</ExecuteInTerminalOSX>
  </RoyalCommandTask>
  <RoyalCommandTask>
    <ID>b2</ID>
    <Name>Add IP to Firewall</Name>
    <CommandLineOSX>/opt/scripts/firewall.sh</CommandLineOSX>
    <NoConfirmationRequired>True</NoConfirmationRequired>
  </RoyalCommandTask>
  <RoyalCommandTask>
    <ID>c3</ID>
    <Name>Log In</Name>
    <CommandLineOSX>/opt/scripts/login.sh</CommandLineOSX>
    <ArgumentsOSX>--user $USERNAME$ --pass $PASSWORD$</ArgumentsOSX>
  </RoyalCommandTask>
</RTSZDocument>
"""

private func library() throws -> RoyalTaskLibrary {
    RoyalTaskLibrary(objects: try RoyalDocumentParser().parse(data: Data(settingsXML.utf8)))
}

private func connection(_ fields: [String: String]) -> RoyalObject {
    var all = ["ID": "conn", "Name": "web-01", "URI": "web01.example.com"]
    all.merge(fields) { _, new in new }
    return RoyalObject(type: "RoyalSSHConnection", fields: all)
}

@Suite("Royal tasks")
struct RoyalTaskTests {
    @Test("The settings file gives up its tasks")
    func readsTasks() throws {
        let tasks = try library()
        #expect(tasks.tasks.count == 3)
        let ping = try #require(tasks.task(named: "Ping"))
        #expect(ping.commandLine == "ping")
        #expect(ping.arguments == "$URI$")
        #expect(ping.runsInTerminal)
        #expect(ping.asksFirst, "Royal asks first unless the task says not to.")
        #expect(tasks.task(named: "Add IP to Firewall")?.asksFirst == false)
    }

    @Test("A name finds a task whatever its letter case")
    func findsByName() throws {
        #expect(try library().task(named: "add ip to firewall") != nil)
        #expect(try library().task(named: "No Such Task") == nil)
    }

    @Test("An identifier of all zeros finds nothing")
    func ignoresEmptyIdentifier() throws {
        #expect(try library().task(id: "00000000-0000-0000-0000-000000000000") == nil)
        #expect(try library().task(id: "b2") != nil)
    }

    @Test("A connection that names a task gets its commands")
    func importsTheTask() throws {
        let object = connection([
            "PreConnectTaskMode": "2",
            "PreConnectTaskName": "Add IP to Firewall",
            "PreConnectTaskId": "00000000-0000-0000-0000-000000000000",
        ])
        let importer = RoyalImporter(tasks: try library())
        let (document, _) = importer.makeDocument(from: [object])
        let command = try #require(document.connections.first?.settings.beforeConnect.ownValue)
        #expect(command.launchPath == "/opt/scripts/firewall.sh")
        #expect(command.name == "Add IP to Firewall")
        #expect(command.waitsForCompletion)
    }

    @Test("The task can also be found by its identifier")
    func importsByIdentifier() throws {
        let object = connection(["PreConnectTaskId": "a1", "PreConnectTaskWait": "False"])
        let (document, _) = RoyalImporter(tasks: try library()).makeDocument(from: [object])
        let command = try #require(document.connections.first?.settings.beforeConnect.ownValue)
        #expect(command.launchPath == "ping")
        #expect(command.waitsForCompletion == false)
    }

    @Test("A task that asks for a password is refused")
    func refusesASecretOnTheCommandLine() throws {
        let object = connection(["PreConnectTaskName": "Log In"])
        let (document, report) = RoyalImporter(tasks: try library()).makeDocument(from: [object])
        #expect(document.connections.first?.settings.beforeConnect.inheritsFromParent == true)
        #expect(report.notImported.contains { $0.text.contains("readable by every program") })
    }

    @Test("A task whose commands are missing is reported, not dropped")
    func reportsAMissingTask() throws {
        let object = connection(["PreConnectTaskName": "Gone"])
        let (document, report) = RoyalImporter(tasks: try library()).makeDocument(from: [object])
        #expect(document.connections.first?.settings.beforeConnect.inheritsFromParent == true)
        #expect(report.notImported.contains { $0.text.contains("\"Gone\"") })
    }

    @Test("A task taken from the folder stays inherited")
    func keepsInheritance() throws {
        let object = connection([
            "PreConnectTaskFromParent": "True",
            "PreConnectTaskName": "Ping",
        ])
        let (document, _) = RoyalImporter(tasks: try library()).makeDocument(from: [object])
        #expect(document.connections.first?.settings.beforeConnect.inheritsFromParent == true)
    }

    @Test("A task run after disconnecting is reported")
    func reportsTheDisconnectTask() throws {
        let object = connection(["PostDisconnectTaskName": "Ping"])
        let (_, report) = RoyalImporter(tasks: try library()).makeDocument(from: [object])
        #expect(report.notImported.contains { $0.text.contains("after disconnecting") })
    }

    @Test("A missing settings file is not an error")
    func missingFileIsEmpty() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-royal-\(UUID().uuidString).config")
        #expect(try RoyalTaskLibrary.read(contentsOf: url).isEmpty)
    }

    @Test("The marks in a command are replaced")
    func fillsInTheMarks() {
        let values = CommandPlaceholders.Values(
            host: "web01.example.com", port: 2222, username: "root", name: "web-01"
        )
        let filled = CommandPlaceholders.resolve("$URI$ $PORT$ $USERNAME$ $NAME$", with: values)
        #expect(filled == "web01.example.com 2222 root web-01")
    }
}
