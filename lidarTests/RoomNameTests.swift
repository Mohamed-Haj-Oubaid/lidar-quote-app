import Foundation
import SwiftData
import Testing
@testable import lidar

/// H2 – renames create exactly one outbox entry. H6 – room names are unique per job.
@MainActor
@Suite(.serialized)
struct RoomNameTests {
    private func setUp() throws -> (ModelContainer, ModelContext, Job) {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = FakeBackend(session: nil)
        let job = Job(title: "Job")
        context.insert(job)
        try LocalStore.save(job: job, in: context)
        return (container, context, job)
    }

    private func upsertSurveyCount(_ context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<PendingMutation>()).filter { $0.kind == "upsert_survey" }.count
    }

    @Test func renameThenLeaveCreatesExactlyOneUpsert() throws {
        let (container, context, job) = try setUp()
        defer { withExtendedLifetime(container) {} }
        let survey = Survey(roomName: "Room 1", measurement: .empty, job: job)
        context.insert(survey)
        try context.save()

        // Return, focus loss and Back may all fire – only the first commit changes anything.
        #expect(try LocalStore.rename(survey: survey, to: "  Bad  ", in: context))
        #expect(try !LocalStore.rename(survey: survey, to: "Bad", in: context))
        #expect(try !LocalStore.rename(survey: survey, to: "Bad", in: context))

        #expect(survey.roomName == "Bad")
        #expect(try upsertSurveyCount(context) == 1)
    }

    @Test func invalidNamesAreRejectedWithoutOutboxEntry() throws {
        let (container, context, job) = try setUp()
        defer { withExtendedLifetime(container) {} }
        let bath = Survey(roomName: "Bad", measurement: .empty, job: job)
        let hall = Survey(roomName: "Flur", measurement: .empty, job: job)
        context.insert(bath)
        context.insert(hall)
        try context.save()

        #expect(throws: LocalStoreError.emptyRoomName) { try LocalStore.rename(survey: hall, to: "   ", in: context) }
        #expect(throws: LocalStoreError.duplicateRoomName("bad")) { try LocalStore.rename(survey: hall, to: " bad ", in: context) }
        #expect(hall.roomName == "Flur")
        #expect(try upsertSurveyCount(context) == 0)
    }
}
