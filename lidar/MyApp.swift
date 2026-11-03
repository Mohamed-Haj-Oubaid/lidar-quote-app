import SwiftUI
import SwiftData

@main struct MyApp: App {
    private let container: ModelContainer
    @State private var backend: BackendClient
    @State private var sync: SyncManager
    @State private var appLock = AppLock()

    init() {
        let schema = Schema([TenantSettings.self, PriceBookVersion.self, Job.self, Survey.self, Quote.self, PendingMutation.self, WorkProof.self, ProofPhoto.self])
        do {
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
        } catch {
            fatalError("Could not open the local store: \(error)")
        }
        let backend = BackendClient()
        _backend = State(initialValue: backend)
        _sync = State(initialValue: SyncManager(container: container, backend: backend))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(backend)
                .environment(sync)
                .environment(appLock)
        }
        .modelContainer(container)
    }
}
