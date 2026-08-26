//
//  ImportSheet.swift
//  Termora
//

import SwiftUI
import TermoraImport

/// Chooses a Royal TSX document, runs the import, and shows the report.
struct ImportSheet: View {
    @ObservedObject var controller: ImportController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch controller.stage {
            case .choosing:
                setup
            case .reading:
                progress(title: "Reading the document…", value: nil)
            case let .fetchingSecrets(done, total):
                progress(
                    title: "Asking Royal TSX for your saved passwords…",
                    value: total > 0 ? Double(done) / Double(total) : nil
                )
            case let .finished(report):
                ReportView(report: report) { dismiss() }
            case let .failed(reason):
                failure(reason)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(controller.isWorking)
    }

    // MARK: - Before the import

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Royal TSX").font(.title2.weight(.semibold))
            Text("Termora adds the folders and connections to the document you "
                 + "have open. Nothing already in it is removed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Text(controller.sourceURL?.lastPathComponent ?? "No document chosen")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(controller.sourceURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") { controller.chooseFile() }
            }

            Divider()

            Toggle(isOn: $controller.askRoyalForSecrets) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask Royal TSX for the saved passwords")
                    Text(controller.isRoyalInstalled
                         ? "Royal TSX opens the document and hands the passwords over. "
                            + "macOS asks you once for permission."
                         : "Royal TSX is not installed, so the passwords cannot be read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!controller.isRoyalInstalled)

            VStack(alignment: .leading, spacing: 6) {
                Text("When an entry has both a private key and a password")
                    .font(.callout)
                Picker("", selection: $controller.options.whenBothCredentialsExist) {
                    Text("Keep the password, and name the key in the report")
                        .tag(ImportOptions.BothCredentials.keepPassword)
                    Text("Keep the private key, and name the password in the report")
                        .tag(ImportOptions.BothCredentials.keepPrivateKey)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                Text("A Termora connection uses one method. The report names every "
                     + "entry this touched, so nothing disappears without a word.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { Task { await controller.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.sourceURL == nil)
            }
        }
    }

    // MARK: - During and after

    private func progress(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if let value {
                ProgressView(value: value)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text("Do not quit Royal TSX while this runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failure(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Termora could not import the document", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(reason).font(.callout).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// What the import did, and everything it could not do.
private struct ReportView: View {
    let report: ImportReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import finished", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            HStack(spacing: 22) {
                count(report.connectionsCreated, "connections")
                count(report.foldersCreated, "folders")
                count(report.secretsRecovered, "secrets")
            }

            if report.hasProblems {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        section("Type these in", report.missingSecrets, "key.fill", .orange)
                        section("Left out", report.notImported, "info.circle.fill", .secondary)
                        section("Not imported", report.skipped, "minus.circle.fill", .red)
                    }
                }
                .frame(maxHeight: 260)
            } else {
                Text("Everything came across.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section(
        _ title: String,
        _ notes: [ImportReport.Note],
        _ icon: String,
        _ tint: Color
    ) -> some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(title) (\(notes.count))", systemImage: icon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(tint)
                ForEach(notes) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(note.connectionName)
                            .font(.callout.weight(.medium))
                            .frame(width: 140, alignment: .trailing)
                        Text(note.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
