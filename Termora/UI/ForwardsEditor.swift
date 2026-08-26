//
//  ForwardsEditor.swift
//  Termora
//

import SwiftUI
import TermoraModel

/// Edits the tunnels of one connection, and controls them while it is open.
///
/// A tunnel can be added, changed, or removed at any time. When the connection
/// is open, each tunnel also has a switch that opens or closes it at once,
/// because OpenSSH changes a tunnel on the control socket without
/// reconnecting anything.
struct ForwardsEditor: View {
    @EnvironmentObject private var sessions: SessionsController
    @Binding var forwards: [PortForward]
    let connectionID: UUID

    private var isLive: Bool { sessions.isLive(connectionID: connectionID) }

    private var clashing: Set<UUID> {
        Connection(name: "", host: "", forwards: forwards).clashingForwardIDs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tunnels").font(.headline)
                Spacer()
                if isLive {
                    Label("Connected", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Menu {
                    Button("Local, this Mac to the far side") { add(.local) }
                    Button("Remote, the far side to this Mac") { add(.remote) }
                    Button("Dynamic, a SOCKS proxy") { add(.dynamic) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if forwards.isEmpty {
                Text("No tunnels. A tunnel carries a port through this connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($forwards) { $forward in
                    ForwardRow(
                        forward: $forward,
                        connectionID: connectionID,
                        isLive: isLive,
                        clashes: clashing.contains(forward.id),
                        onRemove: { remove(forward) }
                    )
                }
            }
        }
    }

    private func add(_ kind: PortForward.Kind) {
        let used = Set(forwards.map(\.listenPort))
        var port = kind == .dynamic ? 1080 : 8080
        while used.contains(port), port < 65535 { port += 1 }

        forwards.append(PortForward(
            kind: kind,
            listenPort: port,
            destinationHost: kind == .dynamic ? "" : "localhost",
            destinationPort: kind == .dynamic ? 0 : 80
        ))
    }

    private func remove(_ forward: PortForward) {
        if isLive, sessions.isForwardActive(forward, on: connectionID) {
            Task { await sessions.setForward(forward, on: connectionID, active: false) }
        }
        forwards.removeAll { $0.id == forward.id }
    }
}

private struct ForwardRow: View {
    @EnvironmentObject private var sessions: SessionsController
    @Binding var forward: PortForward
    let connectionID: UUID
    let isLive: Bool
    let clashes: Bool
    let onRemove: () -> Void

    @State private var listenText: String = ""
    @State private var destinationText: String = ""

    private var isActive: Bool {
        isLive && sessions.isForwardActive(forward, on: connectionID)
    }

    /// Text in a port field that is not a number. The stored port keeps its
    /// last good value, so the problem must be said, not fixed quietly.
    private var portTextProblem: String? {
        if Int(listenText) == nil {
            return "The listening port must be a number."
        }
        if forward.usesDestination, Int(destinationText) == nil {
            return "The port of the far end must be a number."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $forward.kind) {
                    Text("Local").tag(PortForward.Kind.local)
                    Text("Remote").tag(PortForward.Kind.remote)
                    Text("SOCKS").tag(PortForward.Kind.dynamic)
                }
                .labelsHidden()
                .frame(width: 92)

                // The placeholder is the default, so the field explains
                // itself: empty means listen on localhost.
                TextField("localhost", text: $forward.bindAddress)
                    .frame(width: 88)
                    .help("Leave this empty to listen on this machine only.")

                TextField("port", text: $listenText)
                    .frame(width: 62)
                    .onChange(of: listenText) { _, new in
                        forward.listenPort = Int(new) ?? forward.listenPort
                    }

                if forward.usesDestination {
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("host", text: $forward.destinationHost)
                    TextField("port", text: $destinationText)
                        .frame(width: 62)
                        .onChange(of: destinationText) { _, new in
                            forward.destinationPort = Int(new) ?? forward.destinationPort
                        }
                }

                Spacer(minLength: 4)

                if isLive {
                    Toggle("", isOn: Binding(
                        get: { isActive },
                        set: { wanted in
                            let target = forward
                            Task { await sessions.setForward(target, on: connectionID, active: wanted) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!forward.isReady)
                    .help(isActive ? "Close this tunnel now" : "Open this tunnel now")
                } else {
                    Toggle("", isOn: $forward.isEnabled)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("Open this tunnel when the connection starts")
                }

                Button {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this tunnel")
            }

            // Always say what the tunnel does. Reading it back is the only
            // way to be sure the two ports are the way round you meant.
            if let problem = portTextProblem {
                note(problem, "exclamationmark.triangle.fill", .orange)
            } else if let problem = forward.problem {
                note(problem, "exclamationmark.triangle.fill", .orange)
            } else if clashes {
                note("Another tunnel already listens on port \(forward.listenPort).",
                     "exclamationmark.triangle.fill", .orange)
            } else if isLive {
                note(isActive ? "Open. \(forward.summary)" : "Closed. \(forward.summary)",
                     isActive ? "bolt.fill" : "bolt.slash",
                     isActive ? .green : .secondary)
            } else {
                note(forward.isEnabled
                     ? "Opens with the connection. \(forward.summary)"
                     : "Off. \(forward.summary)",
                     forward.isEnabled ? "bolt.badge.clock" : "bolt.slash",
                     .secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            listenText = String(forward.listenPort)
            destinationText = String(forward.destinationPort)
        }
    }

    private func note(_ text: String, _ icon: String, _ tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.leading, 4)
    }
}
