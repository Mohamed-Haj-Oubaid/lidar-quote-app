import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(BackendClient.self) private var backend
    @Environment(SyncManager.self) private var sync
    @Query private var allSettings: [TenantSettings]
    @Query(sort: \PendingMutation.createdAt) private var pending: [PendingMutation]
    @Query private var jobs: [Job]
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingErase = false

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
                        isConfirmingSignOut = true
                    }
                } else if backend.isConfigured {
                    NavigationLink("Sign In") { SignInView() }
                    if allSettings.first?.tenantID != nil || !jobs.isEmpty {
                        Button("Erase Company Data on This Device", role: .destructive) {
                            isConfirmingErase = true
                        }
                    }
                } else {
                    Text("Supabase is not configured. Set SUPABASE_URL and SUPABASE_ANON_KEY in the target's Info settings. The app works fully offline meanwhile.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let lastSync = allSettings.first?.lastSyncAt {
                    LabeledContent("Last sync", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if case let .needsLocalDataDecision(count) = sync.status {
                Section {
                    Button("Upload to My Company") { Task { await sync.adoptLocalData() } }
                    Button("Discard Jobs on This Device", role: .destructive) { Task { await sync.discardLocalData() } }
                } header: {
                    Text("Jobs created before sign-in")
                } footer: {
                    Text("\(count) jobs were created on this device before you signed in. Nothing is synced until you choose.")
                }
            }

            if sync.foreignMutationCount > 0 {
                Section {
                    Text("\(sync.foreignMutationCount) changes were made by another account on this device and are not sent.")
                        .foregroundStyle(.orange)
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
        .confirmationDialog(signOutTitle, isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            if !pending.isEmpty {
                Button("Sync Now") { Task { await sync.syncNow() } }
            }
            Button(pending.isEmpty ? "Sign Out" : "Sign Out Anyway", role: .destructive) {
                Task { await sync.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Jobs, rooms, quotes and 3D models of your company are removed from this device.")
        }
        .confirmationDialog("Erase company data on this device?", isPresented: $isConfirmingErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { sync.eraseLocalAccountData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pending.isEmpty
                 ? String(localized: "All jobs, rooms and quotes on this device are deleted. Data already synced stays on the server.")
                 : String(localized: "\(pending.count) changes have not been synced and will be lost."))
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    try? modelContext.save()
                    dismiss()
                }
            }
        }
    }

    private var signOutTitle: String {
        pending.isEmpty
            ? String(localized: "Sign out?")
            : String(localized: "\(pending.count) changes have not been synced and will be lost.")
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
    @State private var localJobCount = 0
    @State private var isAskingAboutLocalData = false

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
        .confirmationDialog("Jobs on this device", isPresented: $isAskingAboutLocalData, titleVisibility: .visible) {
            Button("Upload to My Company") {
                Task {
                    await sync.adoptLocalData()
                    dismiss()
                }
            }
            Button("Discard", role: .destructive) {
                Task {
                    await sync.discardLocalData()
                    dismiss()
                }
            }
        } message: {
            Text("\(localJobCount) jobs were created on this device before you signed in. Upload them to your company or discard them?")
        }
    }

    private func submit() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            if codeSent {
                try await backend.verifyOTP(email: email, code: code)
                // Make sure no other company's data on this device is ever sent to this account.
                if case let .needsLocalDataDecision(count) = try sync.checkAccount() {
                    localJobCount = count
                    isAskingAboutLocalData = true
                    return
                }
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
