//
//  TerminalTabsView.swift
//  Termora
//

import GhosttyTerminal
import SwiftUI
import TermoraModel

/// The terminal area: a tab bar, and the split tree of the chosen tab.
struct TerminalTabsView: View {
    @EnvironmentObject private var sessions: SessionsController

    // The tab row is not here: it lives in the window's title bar, as an
    // accessory. See the note on `TitlebarTabs` for the two designs that
    // were tried and failed.
    var body: some View {
        Group {
            if sessions.tabs.isEmpty {
                // The frame fills the column, so the bar above stays at the
                // top instead of centring with this view.
                ContentUnavailableView(
                    "No session",
                    systemImage: "terminal",
                    description: Text("Double-click a connection in the sidebar to open it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Every tab is drawn, and the ones you cannot see are made
                // clear. A tab must not be taken out of the view tree: that
                // ends its terminal surface, and libghostty cannot give the
                // same terminal a second surface. The tab would then stay
                // empty for ever, even after you come back to it.
                //
                // `updateVisibility` stops libghostty drawing the hidden ones,
                // so nothing is wasted.
                ZStack {
                    ForEach(sessions.tabs) { tab in
                        TabContent(tab: tab)
                            .opacity(tab.id == sessions.selectedTabID ? 1 : 0)
                            .allowsHitTesting(tab.id == sessions.selectedTabID)
                            .accessibilityHidden(tab.id != sessions.selectedTabID)
                    }
                }
            }
        }
        .onChange(of: sessions.selectedTabID) { _, _ in
            sessions.updateVisibility()
            sessions.selectedTab?.panes.first { $0.id == sessions.selectedTab?.focusedPaneID }?.focus()
        }
    }
}

/// The row of open tabs.
struct TabBar: View {
    @EnvironmentObject private var sessions: SessionsController

    /// The height of the row of tabs.
    ///
    /// A horizontal `ScrollView` takes whatever height it is offered. Inside a
    /// row it is offered none, and it then draws nothing at all, which is why
    /// the height is named here on both the content and the scroll view.
    static let height: CGFloat = 28

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessions.tabs) { tab in
                    TabButton(tab: tab, isSelected: tab.id == sessions.selectedTabID)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: Self.height)
        }
        .frame(height: Self.height)
    }
}

private struct TabButton: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    @EnvironmentObject private var sessions: SessionsController
    @State private var isHovering = false
    @State private var isHoveringClose = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            // The colour tag tints the icon, the way the sidebar does. It
            // must not touch the status dot: a red Production tag and a red
            // "failed" dot would then look the same.
            Image(systemName: tab.iconName)
                .font(.system(size: 10))
                .foregroundStyle(tagTint)
            Text(tab.connectionName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                sessions.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 13, height: 13)
                    .background(
                        Circle().fill(isHoveringClose
                                      ? AnyShapeStyle(.tertiary)
                                      : AnyShapeStyle(.clear))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }
            // The close mark keeps its room even when it is not drawn, so a
            // name does not jump sideways as the pointer passes over it.
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close this tab")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        // Every tab is the same size, so the gaps between them are even and
        // a long name cannot push its neighbours about.
        .frame(width: 150, height: TabBar.height - 6)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { sessions.selectedTabID = tab.id }
        .onHover { isHovering = $0 }
        .help(tab.connectionName)
        .contextMenu { menu }
        // A name a test can ask for. Without it, a test looking for the tab
        // finds the sidebar row of the same name and passes while the tab bar
        // draws nothing at all.
        .accessibilityIdentifier("tab-\(tab.connectionName)")
    }

    /// A tab you point at is marked, so it is clear what a click will hit.
    ///
    /// The chosen tab is drawn solid. `.selection` is not used: on a bar it
    /// is nearly the colour of the bar itself, and the chosen tab then looks
    /// the same as every other one.
    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.background) }
        if isHovering { return AnyShapeStyle(.tertiary) }
        // Every tab carries a light ground, so the row reads as a row of
        // tabs. With nothing behind them the names float on the bar and the
        // space between them looks uneven.
        return AnyShapeStyle(.quaternary)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Browse Files") { sessions.openFiles(for: tab) }
            .disabled(sessions.connection(of: tab) == nil)
        Button("Duplicate") { sessions.duplicate(tab) }
            .disabled(sessions.connection(of: tab) == nil)
        Divider()
        Button("Close") { sessions.closeTab(tab.id) }
        Button("Close Other Tabs") { sessions.closeOtherTabs(than: tab.id) }
            .disabled(sessions.tabs.count < 2)
    }

    /// The dot says status and nothing else: orange, green, or red.
    private var statusColor: Color {
        switch tab.phase {
        case .connecting, .running: .orange
        case .ready: .green
        case .failed: .red
        }
    }

    private var tagTint: Color {
        switch tab.colorTag {
        case .none: .secondary
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .grey: .gray
        }
    }
}

private struct TabContent: View {
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var sessions: SessionsController

    var body: some View {
        switch tab.phase {
        case let .running(name):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running \(name)…")
                    Spacer()
                }
                Text("This command runs on this Mac, before the connection opens.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CommandLog(text: tab.commandLog)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(tab.connectionName)…")
                    .foregroundStyle(.secondary)
                Text("Answer any question that appears.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                // A host that does not answer holds the tab until the TCP
                // timeout. This is the way out.
                Button("Cancel") { sessions.closeTab(tab.id) }
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(reason):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Termora could not connect to \(tab.connectionName).")
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button("Close this tab") { sessions.closeTab(tab.id) }
                if !tab.commandLog.isEmpty {
                    CommandLog(text: tab.commandLog)
                        .frame(maxWidth: 640)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

        case .ready:
            if tab.kind == .files {
                if let browser = tab.browser {
                    FileBrowserView(model: browser)
                }
            } else if let root = tab.root {
                PaneTreeView(node: root, tab: tab)
            }
        }
    }
}

/// Draws a node: either one pane, or two nodes with a divider between them.
private struct PaneTreeView: View {
    @ObservedObject var node: PaneNode
    @ObservedObject var tab: TerminalTab

    var body: some View {
        switch node.content {
        case let .pane(session):
            TerminalPaneView(session: session, tab: tab)
        case let .split(axis, first, second):
            SplitContainer(axis: axis, ratio: $node.ratio) {
                PaneTreeView(node: first, tab: tab)
            } second: {
                PaneTreeView(node: second, tab: tab)
            }
        }
    }
}

/// One terminal surface, with a mark showing which pane has the keyboard.
private struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var tab: TerminalTab
    @EnvironmentObject private var sessions: SessionsController

    private var isFocused: Bool { tab.focusedPaneID == session.id }

    var body: some View {
        TerminalSurfaceView(context: session.state)
            .overlay(alignment: .top) {
                // A thin line, so a split shows which half takes the keys
                // without a border that eats space.
                Rectangle()
                    .fill(.tint)
                    .frame(height: 2)
                    .opacity(isFocused && tab.panes.count > 1 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { sessions.focus(paneID: session.id, in: tab) }
            .onAppear {
                // Only a pane on the chosen tab may take the keyboard. A
                // session that becomes ready behind another tab appears too,
                // and it must not steal the keys from what you are typing in.
                if isFocused, sessions.selectedTabID == tab.id { session.focus() }
            }
    }
}

/// Two views with a divider you can drag.
///
/// This is used for the terminal splits and for the two panes of the file
/// browser. `HSplitView` is not: its split view takes the whole window
/// height once the safe area above it is ignored, and it then draws over
/// the tab bar.
struct SplitContainer<First: View, Second: View>: View {
    let axis: Axis
    @Binding var ratio: Double
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    private let thickness: CGFloat = 6
    /// Neither side may shrink past this share, so a pane never disappears.
    private let limits = 0.1 ... 0.9
    /// The ratio when the drag began. A drag reports the distance from its own
    /// start, so without this the movement would add up on every change.
    @State private var ratioAtDragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let usable = max(total - thickness, 1)
            let firstLength = usable * ratio

            if axis == .horizontal {
                HStack(spacing: 0) {
                    first.frame(width: firstLength)
                    divider(total: usable)
                    second.frame(width: max(usable - firstLength, 0))
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: firstLength)
                    divider(total: usable)
                    second.frame(height: max(usable - firstLength, 0))
                }
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(
                width: axis == .horizontal ? thickness : nil,
                height: axis == .horizontal ? nil : thickness
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    axis == .horizontal
                        ? NSCursor.resizeLeftRight.push()
                        : NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = ratioAtDragStart ?? ratio
                        if ratioAtDragStart == nil { ratioAtDragStart = ratio }
                        let delta = axis == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        let proposed = start + delta / total
                        ratio = min(max(proposed, limits.lowerBound), limits.upperBound)
                    }
                    .onEnded { _ in ratioAtDragStart = nil }
            )
    }
}


/// Shows what a command printed, and keeps the newest line in sight.
private struct CommandLog: View {
    let text: String

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                Text(text.isEmpty ? "No output yet." : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("end")
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: 320)
            .onChange(of: text) { _, _ in
                scroller.scrollTo("end", anchor: .bottom)
            }
        }
    }
}
