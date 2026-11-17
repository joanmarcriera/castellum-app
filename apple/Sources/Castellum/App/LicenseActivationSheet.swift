// Castellum - licence key entry / activation sheet (S61).
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd
//
// A simple sheet: enter a key, Activate. Stays open on failure so the user
// can fix a typo or retry — same inline-result UX shape as
// AccountSetupSheet's `startSync` handling. British English throughout.

import SwiftUI

struct LicenseActivationSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""
    @State private var isActivating = false
    @State private var errorMessage: String?

    private var trimmedKey: String {
        LicenseActivationClient.normalizeKey(key)
    }
    private var keyLooksPlausible: Bool {
        LicenseActivationClient.isPlausibleKeyFormat(trimmedKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activate Castellum")
                .font(.headline)
            Text("Enter the licence key from your purchase confirmation.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField(String(localized: "Licence key"), text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .disabled(isActivating)
                .onSubmit { activate() }

            // Assumption 2's number, kept visible rather than buried.
            Text("If Castellum can't reach the licence server, it keeps working for \(LicenseRecord.offlineGraceDays) days from the last successful check.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            HStack {
                if let buyURL = LicenseBuild.buyURL {
                    Button("Buy a licence…") { NSWorkspace.shared.open(buyURL) }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isActivating)
                Button {
                    activate()
                } label: {
                    if isActivating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Activate")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isActivating || !keyLooksPlausible)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func activate() {
        guard keyLooksPlausible, !isActivating else { return }
        isActivating = true
        errorMessage = nil
        let keyToActivate = trimmedKey
        Task {
            let result = await model.activateLicense(key: keyToActivate)
            isActivating = false
            if let result {
                errorMessage = result
            } else {
                dismiss()
            }
        }
    }
}
