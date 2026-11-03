import SwiftUI
import SwiftData

/// App root: jobs list, first-launch seeding, connectivity-driven sync and the app lock.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncManager.self) private var sync
    @Environment(AppLock.self) private var appLock
    @Environment(BackendClient.self) private var backend

    /// Nothing opens until the user is signed in to a company and has decided about
    /// jobs left on the device. Builds without Supabase config stay offline-only.
    private var needsSignIn: Bool {
        guard backend.isConfigured else { return false }
        if backend.session?.tenantID == nil { return true }
        if case .needsLocalDataDecision = sync.status { return true }
        return false
    }

    var body: some View {
        Group {
            if needsSignIn {
                SignInGate()
            } else {
                NavigationStack {
                    JobsListView()
                }
            }
        }
        .overlay {
            if appLock.isLocked {
                LockScreen()
            }
        }
        .task {
            LocalStore.seedIfNeeded(in: modelContext)
            appLock.lockIfEnabled(LocalStore.settings(in: modelContext).appLockEnabled)
            sync.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                appLock.lockIfEnabled(LocalStore.settings(in: modelContext).appLockEnabled)
            case .active:
                Task { await sync.syncNow() }
            default:
                break
            }
        }
    }
}

/// Full-screen sign-in shown instead of the app while signed out.
private struct SignInGate: View {
    @Environment(BackendClient.self) private var backend
    @Environment(SyncManager.self) private var sync

    var body: some View {
        NavigationStack {
            if case let .needsLocalDataDecision(count) = sync.status {
                Form {
                    Section {
                        Button("Upload to My Company") { Task { await sync.adoptLocalData() } }
                        Button("Discard Jobs on This Device", role: .destructive) { Task { await sync.discardLocalData() } }
                    } header: {
                        Text("Jobs on this device")
                    } footer: {
                        Text("\(count) jobs were created on this device before you signed in. Upload them to your company or discard them?")
                    }
                }
                .navigationTitle("Welcome")
            } else {
                SignInView()
                    .safeAreaInset(edge: .top) {
                        VStack(spacing: 8) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 44))
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            Text("Sign in with your work email to continue.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                    .toolbar {
                        if backend.isSignedIn {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Sign Out") { Task { await sync.signOut() } }
                            }
                        }
                    }
            }
        }
    }
}

private struct LockScreen: View {
    @Environment(AppLock.self) private var appLock

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text("Locked")
                    .font(.title2.bold())
                Button("Unlock") {
                    Task { await appLock.unlock() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .task { await appLock.unlock() }
    }
}

/// Compact sync indicator for toolbars.
struct SyncStatusBadge: View {
    @Environment(SyncManager.self) private var sync
    @Query private var pending: [PendingMutation]

    private var blockedCount: Int { pending.filter(\.isBlocked).count }

    var body: some View {
        Button {
            Task { await sync.syncNow() }
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .symbolEffect(.pulse, isActive: sync.status == .syncing)
        }
        .accessibilityLabel(title)
        .badge(pending.count)
    }

    private var title: String {
        switch sync.status {
        case .idle where blockedCount > 0: String(localized: "\(blockedCount) changes need attention")
        case .idle: pending.isEmpty ? String(localized: "Synced") : String(localized: "\(pending.count) changes waiting")
        case .offline: String(localized: "Offline – changes are saved on this device")
        case .notSignedIn: String(localized: "Not signed in – working locally")
        case .syncing: String(localized: "Syncing…")
        case .needsLocalDataDecision: String(localized: "Choose what to do with jobs on this device (Settings)")
        case .failed(let message): String(localized: "Sync failed: \(message)")
        }
    }

    private var symbol: String {
        switch sync.status {
        case .idle where blockedCount > 0: "exclamationmark.icloud"
        case .idle: pending.isEmpty ? "checkmark.icloud" : "arrow.triangle.2.circlepath.icloud"
        case .offline: "icloud.slash"
        case .notSignedIn: "person.crop.circle.badge.questionmark"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .needsLocalDataDecision: "exclamationmark.icloud"
        case .failed: "exclamationmark.icloud"
        }
    }
}
