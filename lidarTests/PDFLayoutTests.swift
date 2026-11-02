import Foundation
import PDFKit
import SwiftData
import Testing
@testable import lidar

/// M4 – complete multi-page quote PDF.
@MainActor
@Suite(.serialized)
struct PDFLayoutTests {
    private func document(lines count: Int, longNote: Bool = false) -> QuoteDocument {
        let lines = (0..<count).map { index in
            QuoteLine(surveyID: UUID(), itemID: UUID(), roomName: "Room \(index)", itemCode: "MAL-\(index)", itemName: "Wall painting",
                      unit: .squareMeter, netQuantityHundredths: 1000, wastePercent: 0, billedQuantityHundredths: 1000,
                      unitPriceCents: 1250, totalCents: 12500,
                      note: longNote && index == count - 1 ? String(repeating: "Very long explanation of the deduction. ", count: 40) : nil)
        }
        let net = lines.reduce(0) { $0 + $1.totalCents }
        let calculation = QuoteCalculation(engineVersion: "1.1.0", priceBookVersionID: UUID(), priceBookVersion: 1, priceBookName: "Standard",
                                           rooms: [], lines: lines, netTotalCents: net, vatRateBasisPoints: 1900,
                                           vatCents: net * 19 / 100, grossTotalCents: net + net * 19 / 100)
        return QuoteDocument(number: "ANG-2026-00001", revision: 1, issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
                             isProvisional: false, snapshotSHA256: String(repeating: "a", count: 64), calculation: calculation, watermark: nil)
    }

    private func settings(_ context: ModelContext) -> TenantSettings {
        let settings = LocalStore.settings(in: context)
        settings.firmName = "Malerbetrieb Muster"
        settings.bankIBAN = "DE02120300000000202051"
        settings.vatID = "DE123456789"
        settings.paymentTerms = "14 days net"
        settings.quoteValidityDays = 30
        return settings
    }

    private func pageTexts(_ data: Data) throws -> [String] {
        let pdf = try #require(PDFDocument(data: data))
        return (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
    }

    @Test func multiPageQuoteHasHeadersFootersAndPageNumbers() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let settings = settings(context)
        let job = Job(title: "Job", clientName: "Frau Müller")
        context.insert(job)

        let doc = document(lines: 60)
        let data = try #require(PDFGenerator.render(doc, job: job, settings: settings))
        let pages = try pageTexts(data)

        #expect(pages.count >= 2)
        #expect(pages.count == PDFGenerator.pageCount(doc, job: job, settings: settings))
        for (index, text) in pages.enumerated() {
            #expect(text.contains("Page \(index + 1) of \(pages.count)"))
            #expect(text.contains("DE02120300000000202051"))
        }
        // Table header repeats on continuation pages that still contain rows.
        #expect(pages[1].contains("Description"))
        let all = pages.joined(separator: "\n")
        #expect(all.contains("Valid until"))
        #expect(all.contains("14 days net"))
    }

    @Test func tallRowMovesToTheNextPageInsteadOfOverflowing() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let settings = settings(context)
        let job = Job(title: "Job")
        context.insert(job)

        // Enough short rows to nearly fill page 1, then one very tall row.
        let doc = document(lines: 26, longNote: true)
        let pages = try pageTexts(try #require(PDFGenerator.render(doc, job: job, settings: settings)))
        let page = try #require(pages.firstIndex { $0.contains("Very long explanation") })
        // The tall row is drawn in one piece on a single page.
        #expect(pages.filter { $0.contains("Very long explanation") }.count == 1)
        #expect(pages[page].contains("Room 25"))
    }
}
