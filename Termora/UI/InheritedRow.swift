//
//  InheritedRow.swift
//  Termora
//

import SwiftUI
import TermoraModel

/// What the inherit checkbox says.
///
/// A node inside a folder inherits. A node at the top level has no folder
/// above it, so "Inherit" would point at nothing: there the checkbox says
/// "Use default".
extension EnvironmentValues {
    @Entry var inheritToggleLabel: String = "Inherit"
}

/// One setting in the inspector, with its "inherit from folder" switch.
///
/// While the switch is on, the row shows the value that the folder chain
/// supplies and names the folder it came from. Turning the switch off copies
/// that value in, so the field never starts empty.
struct InheritedRow<Value: Codable & Hashable & Sendable, Editor: View>: View {
    let title: String
    @Binding var setting: Inherited<Value>
    /// The value the folder chain supplies while this row inherits.
    let inheritedValue: Value
    /// The folder that supplies it, if any.
    let sourceFolderName: String?
    /// Turns a value into text for the greyed-out preview.
    let describe: (Value) -> String
    @ViewBuilder let editor: (Binding<Value>) -> Editor

    @Environment(\.inheritToggleLabel) private var toggleLabel

    private var isInheriting: Bool { setting.inheritsFromParent }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .frame(width: 130, alignment: .trailing)
                    .foregroundStyle(.secondary)

                if isInheriting {
                    Text(describe(inheritedValue))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("This value comes from the folder above.")
                } else {
                    editor(Binding(
                        get: { setting.ownValue ?? inheritedValue },
                        set: { setting = .value($0) }
                    ))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle(toggleLabel, isOn: Binding(
                    get: { isInheriting },
                    set: { shouldInherit in
                        // Copy the inherited value in, so the field is never
                        // empty at the moment the switch turns off.
                        setting = shouldInherit ? .inherit : .value(inheritedValue)
                    }
                ))
                .toggleStyle(.checkbox)
                .fixedSize()
            }

            if isInheriting {
                Text(sourceFolderName.map { "from \($0)" } ?? "Termora default")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 138)
            }
        }
    }
}
