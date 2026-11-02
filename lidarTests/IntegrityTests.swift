import Foundation
import SwiftData
import Testing
@testable import lidar

/// H5 – the server can reproduce the device's hash from the bytes it receives.
@MainActor
@Suite(.serialized)
struct IntegrityTests {
    @Test func outboxSendsExactlyTheHashedBytes() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = FakeBackend(session: nil)
        let item = PriceItem(id: UUID(), code: "MAL-01", name: "Wall painting / 2 coats", basis: .floorArea,
                             unitPriceCents: 1250, openingRule: .noDeduction, defaultWastePercent: 0)
        let book = PriceBookVersion(id: UUID(), priceBookID: UUID(), name: "Standard", version: 1, vatRateBasisPoints: 1900,
                                    publishedAt: .now, items: [item], isActive: true, isLocalSample: false)
        context.insert(book)
        let job = Job(title: "Job")
        context.insert(job)
        let survey = Survey(roomName: "Bad/WC", measurement: .rectangle(width: 2, depth: 2, height: 2.5), job: job)
        survey.selections = [ItemSelection(itemID: item.id, wastePercent: 0)]
        context.insert(survey)
        try context.save()

        let calculation = EstimationEngine.calculate(
            rooms: [RoomInput(surveyID: survey.id, roomName: survey.roomName, measurement: survey.measurement, selections: survey.selections)],
            priceBook: book.snapshot)
        let quote = try LocalStore.issueQuote(for: job, calculation: calculation, in: context)

        let mutation = try #require(try context.fetch(FetchDescriptor<PendingMutation>()).first { $0.kind == "issue_quote" })
        let payload = try #require(try JSONSerialization.jsonObject(with: mutation.payload) as? [String: Any])
        let raw = try #require(payload["calculation_json"] as? String)

        #expect(QuoteCalculation.sha256Hex(of: Data(raw.utf8)) == quote.snapshotSHA256)
        #expect(payload["snapshot_sha256"] as? String == quote.snapshotSHA256)
        #expect(raw.contains("Bad/WC"))           // "/" is not escaped
        #expect(!raw.contains("\\/"))
        #expect(raw.contains("\"itemID\""))
    }

    @Test func canonicalJSONIsDeterministic() throws {
        let item = PriceItem(id: UUID(), code: "X", name: "Item", basis: .fixedPiece, unitPriceCents: 999,
                             openingRule: .noDeduction, defaultWastePercent: 0)
        let book = PriceBookSnapshot(versionID: UUID(), version: 3, name: "B", vatRateBasisPoints: 700, items: [item])
        let rooms = [RoomInput(surveyID: UUID(), roomName: "A", measurement: .rectangle(width: 3, depth: 4, height: 2.5),
                               selections: [ItemSelection(itemID: item.id, wastePercent: 0)])]
        let first = EstimationEngine.calculate(rooms: rooms, priceBook: book)
        let second = EstimationEngine.calculate(rooms: rooms, priceBook: book)
        #expect(try first.canonicalJSON() == second.canonicalJSON())
        #expect(try first.sha256Hex() == second.sha256Hex())
    }
}
