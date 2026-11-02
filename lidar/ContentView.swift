import SwiftUI
import SwiftData

/// App root: jobs list, first-launch seeding, connectivity-driven sync and the app lock.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncManager.self) private var sync
    @Environment(AppLock.self) private var appLock

    var body: some View {
        NavigationStack {
            JobsListView()
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
        case .idle: pending.isEmpty ? String(localized: "Synced") : String(localized: "\(pending.count) changes waiting")
        case .offline: String(localized: "Offline – changes are saved on this device")
        case .notSignedIn: String(localized: "Not signed in – working locally")
        case .syncing: String(localized: "Syncing…")
        case .failed(let message): String(localized: "Sync failed: \(message)")
        }
    }

    private var symbol: String {
        switch sync.status {
        case .idle: pending.isEmpty ? "checkmark.icloud" : "arrow.triangle.2.circlepath.icloud"
        case .offline: "icloud.slash"
        case .notSignedIn: "person.crop.circle.badge.questionmark"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .failed: "exclamationmark.icloud"
        }
    }
}
