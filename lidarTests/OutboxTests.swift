import Foundation
import SwiftData
import Testing
@testable import lidar

/// C5 – permanent rejections block, transient ones back off, dependents wait.
@MainActor
@Suite(.serialized)
struct OutboxTests {
    let user = UUID()
    let tenant = UUID()

    private func setUp() throws -> (ModelContext, FakeBackend, SyncManager) {
        let container = try makeTestContainer()
        let context = container.mainContext
        LocalStore.seedIfNeeded(in: context)
        LocalStore.settings(in: context).tenantID = tenant
        let backend = FakeBackend(session: makeSession(user: user, tenant: tenant))
        let sync = SyncManager(container: container, backend: backend, monitorsConnectivity: false)
        return (context, backend, sync)
    }

    private static func reject(_ item: [String: Any], retryable: Bool, error: String = "AVV not signed") -> [String: Any] {
        ["idempotency_key": item["idempotency_key"] ?? "", "status": "rejected", "error": error,
         "sqlstate": retryable ? "40001" : "P0001", "retryable": retryable]
    }

    private func addJob(_ context: ModelContext) throws -> Job {
        let job = Job(title: "Bad Müller")
        context.insert(job)
        try LocalStore.save(job: job, in: context)
        return job
    }

    private func addRoom(to job: Job, _ context: ModelContext) throws {
        let survey = Survey(roomName: "Bad", measurement: .rectangle(width: 3, depth: 2, height: 2.5), job: job)
        context.insert(survey)
        try LocalStore.save(survey: survey, in: context)
    }

    @Test func permanentRejectionIsSentOnceThenBlocked() async throws {
        let (context, backend, sync) = try setUp()
        backend.pushResult = { Self.reject($0, retryable: false) }
        _ = try addJob(context)

        await sync.syncNow()
        await sync.syncNow()
        await sync.syncNow()

        #expect(backend.pushed.count == 1)
        let mutation = try #require(try context.fetch(FetchDescriptor<PendingMutation>()).first)
        #expect(mutation.blockedReason == "AVV not signed")
        #expect(mutation.attempts == 1)
    }

    @Test func dependentsOfABlockedJobAreBlockedToo() async throws {
        let (context, backend, sync) = try setUp()
        backend.pushResult = { Self.reject($0, retryable: false) }
        let job = try addJob(context)
        await sync.syncNow()

        backend.pushResult = { ["idempotency_key": $0["idempotency_key"] ?? "", "status": "applied"] }
        try addRoom(to: job, context)
        await sync.syncNow()

        #expect(backend.pushedKinds == ["upsert_job"])
        let room = try #require(try context.fetch(FetchDescriptor<PendingMutation>()).first { $0.kind == "upsert_survey" })
        #expect(room.blockedReason == SyncManager.waitingForJobReason)
    }

    @Test func transientFailureBacksOffExponentially() async throws {
        let (context, backend, sync) = try setUp()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        sync.now = { clock }
        backend.pushResult = { Self.reject($0, retryable: true, error: "lock timeout") }
        _ = try addJob(context)

        await sync.syncNow()
        let mutation = try #require(try context.fetch(FetchDescriptor<PendingMutation>()).first)
        #expect(mutation.blockedReason == nil)
        #expect(mutation.nextAttemptAt == clock.addingTimeInterval(2))

        await sync.syncNow()                       // still inside the backoff window
        #expect(backend.pushed.count == 1)

        clock = clock.addingTimeInterval(3)
        await sync.syncNow()                       // window passed → resent, next wait 4 s
        #expect(backend.pushed.count == 2)
        #expect(mutation.nextAttemptAt == clock.addingTimeInterval(4))

        #expect(PendingMutation.backoff(afterAttempts: 20) == 3600)
    }

    @Test func retryUnblocksJobAndItsDependents() async throws {
        let (context, backend, sync) = try setUp()
        backend.pushResult = { Self.reject($0, retryable: false) }
        let job = try addJob(context)
        await sync.syncNow()
        try addRoom(to: job, context)
        await sync.syncNow()

        backend.pushResult = { ["idempotency_key": $0["idempotency_key"] ?? "", "status": "applied"] }
        let jobMutation = try #require(try context.fetch(FetchDescriptor<PendingMutation>()).first { $0.kind == "upsert_job" })
        await sync.retry(jobMutation)

        #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
        #expect(backend.pushedKinds == ["upsert_job", "upsert_job", "upsert_survey"])
    }

    @Test func discardRemovesDependents() async throws {
        let (context, backend, sync) = try setUp()
        backend.pushResult = { Self.reject($0, retryable: false) }
        let job = try addJob(context)
        await sync.syncNow()
        try addRoom(to: job, context)

        let jobMutation = try #require(try context.fetch(FetchDescriptor<PendingMutation>()).first { $0.kind == "upsert_job" })
        #expect(sync.dependents(of: jobMutation).map(\.kind) == ["upsert_survey"])
        sync.discard(jobMutation)
        #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
    }

    @Test func sampleBookCannotIssueQuotes() throws {
        // Keep the SyncManager: it owns the ModelContainer backing `context`.
        let (context, _, sync) = try setUp()
        defer { withExtendedLifetime(sync) {} }
        let job = try addJob(context)
        let book = try #require(LocalStore.activePriceBook(in: context))
        #expect(book.isLocalSample)
        let calculation = EstimationEngine.calculate(rooms: [], priceBook: book.snapshot)
        let sequence = LocalStore.settings(in: context).nextProvisionalSequence
        let outbox = try context.fetchCount(FetchDescriptor<PendingMutation>())

        #expect(throws: LocalStoreError.self) {
            try LocalStore.issueQuote(for: job, calculation: calculation, in: context)
        }
        // The watermarked preview renders without side effects.
        #expect(PDFGenerator.renderSamplePreview(calculation: calculation, job: job, settings: LocalStore.settings(in: context)) != nil)
        #expect(try context.fetchCount(FetchDescriptor<Quote>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == outbox)
        #expect(LocalStore.settings(in: context).nextProvisionalSequence == sequence)
    }
}
