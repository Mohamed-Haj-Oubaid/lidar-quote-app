import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(BackendClient.self) private var backend
    @Environment(SyncManager.self) private var sync
    @Query private var allSettings: [TenantSettings]
    @Query(sort: \PendingMutation.createdAt) private var pending: [PendingMutation]

    var body: some View {
        Form {
            if let settings = allSettings.first {
                FirmSettingsSection(settings: settings, canEdit: canManageFirm)
            }

            Section("Account") {
                if let session = backend.session {
                    LabeledContent("Signed in", value: session.email ?? "–")
                    LabeledContent("Role", value: session.role?.rawValue.capitalized ?? "–")
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await sync.syncNow() }
                    }
                    Button("Sign Out", role: .destructive) {
                        Task { await backend.signOut() }
                    }
                } else if backend.isConfigured {
                    NavigationLink("Sign In") { SignInView() }
                } else {
                    Text("Supabase is not configured. Set SUPABASE_URL and SUPABASE_ANON_KEY in the target's Info settings. The app works fully offline meanwhile.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let lastSync = allSettings.first?.lastSyncAt {
                    LabeledContent("Last sync", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if !pending.isEmpty {
                Section {
                    ForEach(pending) { mutation in
                        VStack(alignment: .leading) {
                            Text(mutation.kind)
                                .font(.callout.monospaced())
                            if let error = mutation.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(pending[index]) }
                        try? modelContext.save()
                    }
                } header: {
                    Text("Waiting to sync (\(pending.count))")
                } footer: {
                    Text("Changes are kept on this device until the server accepts them. Swipe to discard a rejected change.")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    try? modelContext.save()
                    dismiss()
                }
            }
        }
    }

    /// Firm settings are editable locally before sign-in, afterwards only by Owner/Admin.
    private var canManageFirm: Bool {
        guard let session = backend.session else { return true }
        return session.role?.canManageFirm ?? false
    }
}

private struct FirmSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BackendClient.self) private var backend
    @Bindable var settings: TenantSettings
    let canEdit: Bool

    var body: some View {
        Section {
            TextField("Company name", text: $settings.firmName)
            TextField("Company address", text: $settings.firmAddress, axis: .vertical)
            TextField("Quote number prefix", text: $settings.quotePrefix)
                .textInputAutocapitalization(.characters)
        } header: {
            Text("Company")
        }
        .disabled(!canEdit)

        Section {
            Toggle("Keep 3D models & photos on device only", isOn: $settings.mediaDeviceOnly)
                .disabled(!canEdit)
            Toggle("Lock app with Face ID", isOn: $settings.appLockEnabled)
        } header: {
            Text("Privacy & storage")
        } footer: {
            Text("Measurements, jobs and quotes always sync. When device-only is on, USDZ room models never leave this device.")
        }

        Section("Client privacy notice") {
            TextField("Privacy notice", text: $settings.privacyNoticeText, axis: .vertical)
                .lineLimit(4...12)
                .disabled(!canEdit)
        }

        if canEdit, backend.isSignedIn {
            Section {
                Button("Publish Company Settings") {
                    try? LocalStore.save(settings: settings, in: modelContext)
                }
            } footer: {
                Text("Sends these settings to all devices of your company on the next sync.")
            }
        }

        Section("Device") {
            LabeledContent("Device code", value: settings.deviceCode)
            LabeledContent("Next provisional number", value: String(format: "OFFLINE-TEMP-%@-%04d", settings.deviceCode, settings.nextProvisionalSequence))
        }
    }
}

/// Email one-time-code sign-in (Supabase Auth). Users are invited by their firm.
struct SignInView: View {
    @Environment(BackendClient.self) private var backend
    @Environment(SyncManager.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Work email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .disabled(codeSent)
                if codeSent {
                    TextField("Code from email", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                }
            } footer: {
                Text("Your company's Owner or Admin must invite you first.")
            }

            Section {
                Button(codeSent ? "Verify Code" : "Send Code") {
                    Task { await submit() }
                }
                .disabled(isWorking || email.isEmpty || (codeSent && code.isEmpty))
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Sign In")
    }

    private func submit() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            if codeSent {
                try await backend.verifyOTP(email: email, code: code)
                await sync.syncNow()
                dismiss()
            } else {
                try await backend.sendOTP(email: email)
                codeSent = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
