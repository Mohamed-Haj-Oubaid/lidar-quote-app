import Foundation
import SwiftData
import Testing
@testable import lidar

/// The local sample book gains new sample items on update without breaking room selections.
@MainActor
struct SamplePriceBookTests {
    @Test func olderSampleBookGetsNewItemsAndKeepsIDs() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let oldItems = Array(LocalStore.samplePriceItems.prefix(3)).map { item in
            var copy = item
            copy.id = UUID()
            return copy
        }
        context.insert(PriceBookVersion(id: UUID(), priceBookID: UUID(), name: "Sample", version: 0, vatRateBasisPoints: 1900,
                                        publishedAt: .now, items: oldItems, isActive: true, isLocalSample: true))
        try context.save()

        LocalStore.seedIfNeeded(in: context)
        LocalStore.seedIfNeeded(in: context)

        let book = try #require(try context.fetch(FetchDescriptor<PriceBookVersion>()).first)
        #expect(book.items.count == LocalStore.samplePriceItems.count)
        #expect(Array(book.items.prefix(3)).map(\.id) == oldItems.map(\.id))
        #expect(book.items.contains { $0.code == "WDV-01" })
        #expect(Set(book.items.map(\.code)).count == book.items.count)
    }
}
