import Foundation
import SwiftData
import Testing
@testable import lidar

/// C3 – switching accounts on one device must never leak data between companies.
@MainActor
@Suite(.serialized)
struct AccountSwitchTests {
    let userA = UUID()
    let userB = UUID()
    let tenantA = UUID()
    let tenantB = UUID()

    /// Creates a job + room as the signed-in user, without syncing.
    private func createWork(in context: ModelContext, title: String) throws {
        let job = Job(title: title, clientName: "Frau Müller")
        context.insert(job)
        try LocalStore.save(job: job, in: context)
        let survey = Survey(roomName: "Bad", measurement: .rectangle(width: 3, depth: 2, height: 2.5), job: job)
        context.insert(survey)
        try LocalStore.save(survey: survey, in: context)
    }

    @Test func signOutWipesAndNextCompanyPushesNothing() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        LocalStore.seedIfNeeded(in: context)
        let backend = FakeBackend(session: makeSession(user: userA, tenant: tenantA))
        let sync = SyncManager(container: container, backend: backend, monitorsConnectivity: false)
        LocalStore.settings(in: context).tenantID = tenantA

        try createWork(in: context, title: "A's job")
        #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 2)

        await sync.signOut()

        #expect(try context.fetchCount(FetchDescriptor<Job>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Survey>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
        let settings = LocalStore.settings(in: context)
        #expect(settings.tenantID == nil)
        #expect(settings.syncCursor == 0)
        #expect(LocalStore.activePriceBook(in: context)?.isLocalSample == true)

        backend.session = makeSession(user: userB, tenant: tenantB)
        #expect(try sync.checkAccount() == .ok)
        await sync.syncNow()
        #expect(backend.pushed.isEmpty)
    }

    @Test func differentCompanyWithoutSignOutWipesBeforeFirstSync() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        LocalStore.seedIfNeeded(in: context)
        let backend = FakeBackend(session: makeSession(user: userA, tenant: tenantA))
        let sync = SyncManager(container: container, backend: backend, monitorsConnectivity: false)
        LocalStore.settings(in: context).tenantID = tenantA
        try createWork(in: context, title: "A's job")

        // A's token expired (no explicit sign-out); B of another company signs in.
        backend.session = makeSession(user: userB, tenant: tenantB)
        await sync.syncNow()

        #expect(backend.pushed.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Job>()) == 0)
        #expect(LocalStore.settings(in: context).tenantID == tenantB)
    }

    @Test func colleagueOfSameCompanyNeverPushesOtherUsersChanges() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        LocalStore.seedIfNeeded(in: context)
        let backend = FakeBackend(session: makeSession(user: userA, tenant: tenantA))
        let sync = SyncManager(container: container, backend: backend, monitorsConnectivity: false)
        LocalStore.settings(in: context).tenantID = tenantA
        try createWork(in: context, title: "A's job")

        let colleague = UUID()
        backend.session = makeSession(user: colleague, tenant: tenantA)
        await sync.syncNow()

        #expect(backend.pushed.isEmpty)
        #expect(sync.foreignMutationCount == 2)
        #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 2)
    }

    @Test func offlineJobsRequireADecisionBeforeUpload() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        LocalStore.seedIfNeeded(in: context)
        let backend = FakeBackend(session: nil)
        let sync = SyncManager(container: container, backend: backend, monitorsConnectivity: false)
        try createWork(in: context, title: "Offline job")

        backend.session = makeSession(user: userA, tenant: tenantA)
        await sync.syncNow()
        #expect(sync.status == .needsLocalDataDecision(jobCount: 1))
        #expect(backend.pushed.isEmpty)

        await sync.adoptLocalData()
        #expect(backend.pushedKinds == ["upsert_job", "upsert_survey"])
        #expect(LocalStore.settings(in: context).tenantID == tenantA)
    }

    @Test func discardingOfflineJobsPushesNothing() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        LocalStore.seedIfNeeded(in: context)
        let backend = FakeBackend(session: nil)
        let sync = SyncManager(container: container, backend: backend, monitorsConnectivity: false)
        try createWork(in: context, title: "Offline job")

        backend.session = makeSession(user: userA, tenant: tenantA)
        await sync.discardLocalData()
        #expect(backend.pushed.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Job>()) == 0)
    }

    @Test func outboxEntriesRecordTheirOwner() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = FakeBackend(session: makeSession(user: userA, tenant: tenantA))
        try createWork(in: context, title: "Job")
        let owners = try context.fetch(FetchDescriptor<PendingMutation>()).map(\.userID)
        #expect(owners == [userA, userA])
    }

    @Test func configRejectsPlaceholdersAndUnexpandedVariables() {
        #expect(SupabaseConfig.from(url: "$(SUPABASE_URL)", key: "$(SUPABASE_ANON_KEY)") == nil)
        #expect(SupabaseConfig.from(url: "", key: "") == nil)
        #expect(SupabaseConfig.from(url: "https://YOUR-PROJECT.supabase.co", key: "k") == nil)
        #expect(SupabaseConfig.from(url: "https://abc.supabase.co", key: "sb_publishable_x") != nil)
    }
}
