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

/// H6 – duplicate room names never collide in quotes; default names never repeat.
@MainActor
@Suite(.serialized)
struct DuplicateRoomNameTests {
    @Test func linesOfSameNamedRoomsHaveDistinctIDs() {
        let item = PriceItem(id: UUID(), code: "MAL-01", name: "Paint", basis: .floorArea, unitPriceCents: 1000,
                             openingRule: .noDeduction, defaultWastePercent: 0)
        let book = PriceBookSnapshot(versionID: UUID(), version: 1, name: "B", vatRateBasisPoints: 1900, items: [item])
        let selection = [ItemSelection(itemID: item.id, wastePercent: 0)]
        let rooms = [
            RoomInput(surveyID: UUID(), roomName: "Bad", measurement: .rectangle(width: 2, depth: 2, height: 2.5), selections: selection),
            RoomInput(surveyID: UUID(), roomName: "Bad", measurement: .rectangle(width: 3, depth: 3, height: 2.5), selections: selection),
        ]
        let calculation = EstimationEngine.calculate(rooms: rooms, priceBook: book)
        #expect(calculation.lines.count == 2)
        #expect(Set(calculation.lines.map(\.id)).count == 2)
        #expect(calculation.lines.allSatisfy { $0.itemID == item.id })
        #expect(calculation.engineVersion == EstimationEngine.version)
    }

    @Test func oldQuoteLinesWithoutIDsStillDecode() throws {
        let json = """
        {"roomName":"Bad","itemCode":"MAL-01","itemName":"Paint","unit":"m2","netQuantityHundredths":400,
         "wastePercent":0,"billedQuantityHundredths":400,"unitPriceCents":1000,"totalCents":4000}
        """
        let line = try JSONDecoder().decode(QuoteLine.self, from: Data(json.utf8))
        #expect(line.surveyID == nil && line.itemID == nil)
        #expect(line.id == "Bad|MAL-01")
    }

    @Test func nextRoomNameFillsGapsAfterDeletion() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let job = Job(title: "Job")
        context.insert(job)
        for name in ["Raum 1", "Raum 2", "Raum 3"] {
            context.insert(Survey(roomName: name, measurement: .empty, job: job))
        }
        try context.save()
        #expect(LocalStore.nextRoomName(for: job) == "Raum 4")

        let second = try #require(job.surveys.first { $0.roomName == "Raum 2" })
        context.delete(second)
        try context.save()
        // Old behaviour produced "Raum 3" here – a duplicate.
        #expect(LocalStore.nextRoomName(for: job) == "Raum 2")
        #expect(throws: LocalStoreError.duplicateRoomName("raum 3")) { try LocalStore.validatedRoomName("raum 3", in: job) }
    }
}
