import Foundation
import SwiftData
import Testing
@testable import lidar

/// H7 – quote status changes work offline; erasure clears the local copy.
@MainActor
@Suite(.serialized)
struct QuoteLifecycleTests {
    private func makeQuote(_ context: ModelContext) throws -> Quote {
        let item = PriceItem(id: UUID(), code: "X", name: "Item", basis: .fixedPiece, unitPriceCents: 1000,
                             openingRule: .noDeduction, defaultWastePercent: 0)
        let book = PriceBookVersion(id: UUID(), priceBookID: UUID(), name: "B", version: 1, vatRateBasisPoints: 1900,
                                    publishedAt: .now, items: [item], isActive: true, isLocalSample: false)
        context.insert(book)
        let job = Job(title: "Job", clientName: "Frau Müller", clientEmail: "m@example.de")
        context.insert(job)
        let calculation = EstimationEngine.calculate(
            rooms: [RoomInput(roomName: "A", measurement: .empty, selections: [ItemSelection(itemID: item.id, wastePercent: 0)])],
            priceBook: book.snapshot)
        return try LocalStore.issueQuote(for: job, calculation: calculation, in: context)
    }

    @Test func statusChangesAreQueuedAndFollowTheServerRules() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = FakeBackend(session: nil)
        let quote = try makeQuote(context)
        #expect(LocalStore.allowedStatusChanges(for: quote) == ["sent", "accepted", "rejected"])

        try LocalStore.setStatus("sent", of: quote, in: context)
        try LocalStore.setStatus("accepted", of: quote, in: context)
        try LocalStore.setStatus("sent", of: quote, in: context)        // not allowed any more – ignored

        #expect(quote.status == "accepted")
        #expect(quote.clientSignedAt != nil)
        let changes = try context.fetch(FetchDescriptor<PendingMutation>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter { $0.kind == "set_quote_status" }
        #expect(changes.count == 2)
        let last = try #require(try JSONSerialization.jsonObject(with: changes[1].payload) as? [String: Any])
        #expect(last["status"] as? String == "accepted")
        #expect(last["quote_id"] as? String == quote.id.uuidString)
        #expect(last["client_signed_at"] is String)
        #expect(LocalStore.allowedStatusChanges(for: quote).isEmpty)
    }

    @Test func erasureClearsClientFieldsWithoutQueueingAnything() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = FakeBackend(session: nil)
        let quote = try makeQuote(context)
        let job = try #require(quote.job)
        let outbox = try context.fetchCount(FetchDescriptor<PendingMutation>())

        try LocalStore.applyClientErasure(to: job, in: context)

        #expect(job.clientName.isEmpty && job.clientEmail.isEmpty)
        #expect(job.clientDataErasedAt != nil)
        #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == outbox)
        #expect(try context.fetchCount(FetchDescriptor<Quote>()) == 1)   // quotes stay
    }
}
