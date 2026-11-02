import Foundation
import SwiftData
import Testing
@testable import lidar

/// H1 – deleting rooms and jobs is synced; never-sent creations are just dropped.
@MainActor
@Suite(.serialized)
struct DeletionTests {
    let user = UUID()
    let tenant = UUID()

    private func setUp() throws -> (ModelContext, FakeBackend, SyncManager) {
        let container = try makeTestContainer()
        let context = container.mainContext
        LocalStore.seedIfNeeded(in: context)
        LocalStore.settings(in: context).tenantID = tenant
        let backend = FakeBackend(session: makeSession(user: user, tenant: tenant))
        return (context, backend, SyncManager(container: container, backend: backend, monitorsConnectivity: false))
    }

    private func makeJobWithRoom(_ context: ModelContext) throws -> (Job, Survey) {
        let job = Job(title: "Job")
        context.insert(job)
        try LocalStore.save(job: job, in: context)
        let survey = Survey(roomName: "Bad", measurement: .rectangle(width: 3, depth: 2, height: 2.5), job: job)
        context.insert(survey)
        try LocalStore.save(survey: survey, in: context)
        return (job, survey)
    }

    @Test func deletingASyncedRoomSendsDeleteSurvey() async throws {
        let (context, backend, sync) = try setUp()
        let (_, survey) = try makeJobWithRoom(context)
        let surveyID = survey.id
        await sync.syncNow()

        try LocalStore.delete(survey: survey, in: context)
        await sync.syncNow()

        #expect(backend.pushedKinds == ["upsert_job", "upsert_survey", "delete_survey"])
        let payload = try #require(backend.pushed.last?["payload"] as? [String: Any])
        #expect(payload["id"] as? String == surveyID.uuidString)
        #expect(try context.fetchCount(FetchDescriptor<Survey>()) == 0)
    }

    @Test func deletingANeverSentRoomSendsNothingForIt() async throws {
        let (context, backend, sync) = try setUp()
        let (_, survey) = try makeJobWithRoom(context)

        try LocalStore.delete(survey: survey, in: context)
        await sync.syncNow()

        #expect(backend.pushedKinds == ["upsert_job"])
    }

    @Test func deletingASyncedJobSendsDeleteJob() async throws {
        let (context, backend, sync) = try setUp()
        let (job, _) = try makeJobWithRoom(context)
        await sync.syncNow()

        try LocalStore.delete(job: job, in: context)
        await sync.syncNow()

        #expect(backend.pushedKinds.last == "delete_job")
        #expect(try context.fetchCount(FetchDescriptor<Job>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Survey>()) == 0)
    }

    @Test func deletingANeverSentJobDropsEverything() async throws {
        let (context, backend, sync) = try setUp()
        let (job, _) = try makeJobWithRoom(context)

        try LocalStore.delete(job: job, in: context)
        await sync.syncNow()

        #expect(backend.pushed.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
    }
}
