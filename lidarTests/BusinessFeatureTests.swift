import Foundation
import SwiftData
import Testing
import UIKit
@testable import lidar

/// Facade/scaffold, material list, client signature, invoices, XRechnung, DATEV, job stages.
@MainActor
@Suite(.serialized)
struct BusinessFeatureTests {
    private func makeAcceptedQuote(_ context: ModelContext, sign: Bool = true) throws -> Quote {
        let item = PriceItem(id: UUID(), code: "MAL-01", name: "Wandanstrich", basis: .wallArea, unitPriceCents: 1250,
                             openingRule: .noDeduction, defaultWastePercent: 0)
        let book = PriceBookVersion(id: UUID(), priceBookID: UUID(), name: "B", version: 1, vatRateBasisPoints: 1900,
                                    publishedAt: .now, items: [item], isActive: true, isLocalSample: false)
        context.insert(book)
        let job = Job(title: "Wohnung Müller", clientName: "Frau Müller", clientEmail: "m@example.de",
                      siteAddress: "Hauptstraße 5, 10115 Berlin")
        context.insert(job)
        let calculation = EstimationEngine.calculate(
            rooms: [RoomInput(roomName: "Bad", measurement: .rectangle(width: 4, depth: 3, height: 2.5),
                              selections: [ItemSelection(itemID: item.id, wastePercent: 0)])],
            priceBook: book.snapshot)
        let quote = try LocalStore.issueQuote(for: job, calculation: calculation, in: context)
        if sign {
            let signature = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { _ in
                UIBezierPath(rect: CGRect(x: 2, y: 2, width: 30, height: 10)).stroke()
            }
            try LocalStore.signQuote(quote, signerName: "Erika Müller", signature: signature, in: context)
        }
        return quote
    }

    @Test func scaffoldAreaAddsOneMetreToEveryWall() {
        var facade = RoomMeasurement.rectangle(width: 10, depth: 8, height: 6)
        facade.isFacade = true
        // Perimeter 36 m × (6 m + 1 m)
        #expect(abs(facade.scaffoldArea - 252) < 0.001)
        let item = PriceItem(id: UUID(), code: "G", name: "Gerüst", basis: .scaffoldArea, unitPriceCents: 1000,
                             openingRule: .noDeduction, defaultWastePercent: 0)
        #expect(abs(EstimationEngine.quantity(for: item, in: facade).0 - 252) < 0.001)
    }

    @Test func oldMeasurementsDecodeAsRooms() throws {
        let data = try StoreCoding.encoder.encode(RoomMeasurement.rectangle(width: 2, depth: 2, height: 2.5))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "isFacade")
        let decoded = try StoreCoding.decoder.decode(RoomMeasurement.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.isFacade == nil)
    }

    @Test func materialListUsesOnlyMatchingScopeAndRoundsPacksUp() {
        let room = RoomMeasurement.rectangle(width: 4, depth: 3, height: 2.5)     // walls 35 m², floor 12 m²
        var facade = RoomMeasurement.rectangle(width: 10, depth: 10, height: 5)  // walls 200 m²
        facade.isFacade = true
        let paint = MaterialRate(name: "Farbe", scope: .rooms, basis: .wallAndCeilingArea, consumption: 0.15, coats: 2,
                                 unit: "l", packSize: 12.5, packName: "Eimer", wastePercent: 0)
        let boards = MaterialRate(name: "EPS", scope: .facades, basis: .netWallArea, consumption: 1, unit: "m²",
                                  packSize: 2, packName: "Paket", wastePercent: 5)
        let needs = MaterialCalculator.needs(for: [room, facade], materials: [paint, boards])
        let paintNeed = needs.first { $0.material.name == "Farbe" }
        // (35 + 12) m² × 0.15 l × 2 = 14.1 l → 2 buckets
        #expect(abs((paintNeed?.amount ?? 0) - 14.1) < 0.001)
        #expect(paintNeed?.packs == 2)
        let boardNeed = needs.first { $0.material.name == "EPS" }
        // 200 m² × 1.05 = 210 m² → 105 packs
        #expect(boardNeed?.packs == 105)
    }

    @Test func signingAcceptsTheQuoteAndAdvancesTheJob() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = FakeBackend(session: nil)
        let quote = try makeAcceptedQuote(context)
        #expect(quote.status == "accepted")
        #expect(quote.clientSignerName == "Erika Müller")
        #expect(quote.clientSignaturePNG != nil)
        #expect(quote.job?.stage == .ordered)
        // A signed quote cannot be signed again.
        #expect(throws: LocalStoreError.quoteNotSignable) {
            try LocalStore.signQuote(quote, signerName: "X", signature: UIImage(), in: context)
        }
    }

    @Test func invoicesGetUniqueNumbersAndAPDF() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = FakeBackend(session: nil)
        let quote = try makeAcceptedQuote(context)
        let first = try LocalStore.createInvoice(from: quote, serviceDate: .now, in: context)
        let second = try LocalStore.createInvoice(from: quote, serviceDate: .now, in: context)
        #expect(first.number != second.number)
        #expect(first.number.hasSuffix("-0001"))
        #expect(first.pdfData != nil)
        #expect(quote.job?.stage == .invoiced)

        try LocalStore.markPaid(first, in: context)
        #expect(quote.job?.stage == .invoiced)          // second invoice still open
        try LocalStore.markPaid(second, in: context)
        #expect(quote.job?.stage == .paid)
    }

    @Test func unacceptedQuotesCannotBeInvoiced() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = FakeBackend(session: nil)
        let quote = try makeAcceptedQuote(context, sign: false)
        #expect(throws: LocalStoreError.quoteNotAccepted) {
            try LocalStore.createInvoice(from: quote, serviceDate: .now, in: context)
        }
    }

    @Test func xrechnungTotalsMatchTheCalculation() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        _ = FakeBackend(session: nil)
        let settings = LocalStore.settings(in: context)
        settings.firmName = "Malerbetrieb Muster GmbH"
        settings.firmAddress = "Musterweg 1\n12345 Musterstadt"
        settings.email = "info@muster.de"
        settings.phone = "030 123"
        settings.vatID = "DE123456789"
        settings.bankIBAN = "DE02 1203 0000 0000 2020 51"
        let quote = try makeAcceptedQuote(context)
        let invoice = try LocalStore.createInvoice(from: quote, serviceDate: .now, in: context)
        let data = try #require(invoice.eInvoiceData(settings: settings))

        #expect(EInvoice.missingFields(data).isEmpty)
        #expect(data.seller.postalCode == "12345" && data.seller.city == "Musterstadt" && data.seller.street == "Musterweg 1")
        #expect(data.buyer.postalCode == "10115" && data.buyer.city == "Berlin")

        let xml = EInvoice.xrechnungXML(data)
        // 35 m² × 12.50 € = 437.50 net, 83.13 VAT, 520.63 gross
        #expect(xml.contains("<cbc:PayableAmount currencyID=\"EUR\">520.63</cbc:PayableAmount>"))
        #expect(xml.contains("<cbc:TaxAmount currencyID=\"EUR\">83.13</cbc:TaxAmount>"))
        #expect(xml.contains("<cbc:InvoicedQuantity unitCode=\"MTK\">35.00</cbc:InvoicedQuantity>"))
        #expect(xml.contains("DE02120300000000202051"))
        #expect(xml.contains(EInvoice.customizationID))
    }

    @Test func xmlEscapesSpecialCharacters() {
        #expect(EInvoice.escape("Müller & Söhne <GmbH>") == "Müller &amp; Söhne &lt;GmbH&gt;")
    }

    @Test func datevExportHasHeaderColumnsAndGermanAmounts() {
        let booking = EInvoice.DatevBooking(grossCents: 52063, date: Date(timeIntervalSince1970: 1_793_000_000),
                                            invoiceNumber: "RE-2026-ABC123-0001", text: "Frau Müller")
        let csv = EInvoice.datevCSV([booking], settings: .init(consultantNumber: "1001", clientNumber: "1",
                                                               revenueAccount: "8400", debtorAccount: "10000"),
                                    from: .now, to: .now)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("\"EXTF\";700;21;\"Buchungsstapel\""))
        #expect(lines[2].hasPrefix("520,63;\"S\";\"EUR\""))
        #expect(lines[2].contains(";10000;8400;"))
        #expect(lines[2].contains("\"RE-2026-ABC123-0001\""))
    }

    @Test func jobStagesOnlyMoveForward() {
        let job = Job(title: "J")
        LocalStore.advance(job, to: .ordered)
        #expect(job.stage == .ordered)
        LocalStore.advance(job, to: .survey)
        #expect(job.stage == .ordered)
    }

    @Test func aufmassPDFRendersRoomsAndFacades() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let job = Job(title: "Haus")
        context.insert(job)
        var facade = RoomMeasurement.rectangle(width: 12, depth: 9, height: 6)
        facade.isFacade = true
        facade.openings.append(RoomOpening(id: UUID(), kind: .window, width: 1.2, height: 1.3, depth: 0.25,
                                           wallID: facade.walls[0].id, centerOffset: 3))
        context.insert(Survey(roomName: "Fassade 1", measurement: facade, job: job))
        context.insert(Survey(roomName: "Bad", measurement: .rectangle(width: 3, depth: 2, height: 2.5), job: job))
        let data = AufmassPDF.render(job: job, settings: LocalStore.settings(in: context))
        #expect(data.count > 1000)
    }

    @Test func splitPricesCarryLabourShareThroughTheQuote() throws {
        var item = PriceItem(id: UUID(), code: "MAL-01", name: "Anstrich", basis: .wallArea, unitPriceCents: 0,
                             openingRule: .noDeduction, defaultWastePercent: 0)
        item.setPriceSplit(material: 300, labor: 950)
        #expect(item.unitPriceCents == 1250)
        let book = PriceBookSnapshot(versionID: UUID(), version: 1, name: "B", vatRateBasisPoints: 1900, items: [item])
        let calculation = EstimationEngine.calculate(
            rooms: [RoomInput(roomName: "Bad", measurement: .rectangle(width: 4, depth: 3, height: 2.5),
                              selections: [ItemSelection(itemID: item.id, wastePercent: 0)])],
            priceBook: book)
        let line = try #require(calculation.lines.first)
        // 35 m² × (3.00 + 9.50) €
        #expect(line.totalCents == 43750)
        #expect(line.laborCents == 33250)
        #expect(line.materialCents == 10500)
        #expect(line.unitMaterialCents == 300 && line.unitLaborCents == 950)
        #expect(calculation.laborTotalCents == 33250)
        #expect(calculation.laborVATCents == 6318)   // 332.50 × 19 % = 63.175 → 63.18
    }

    @Test func unsplitItemsKeepTheOldCanonicalJSON() throws {
        let item = PriceItem(id: UUID(), code: "X", name: "X", basis: .fixedPiece, unitPriceCents: 1000,
                             openingRule: .noDeduction, defaultWastePercent: 0)
        let book = PriceBookSnapshot(versionID: UUID(), version: 1, name: "B", vatRateBasisPoints: 1900, items: [item])
        let calculation = EstimationEngine.calculate(
            rooms: [RoomInput(roomName: "A", measurement: .empty, selections: [ItemSelection(itemID: item.id, wastePercent: 0)])],
            priceBook: book)
        let json = String(decoding: try calculation.canonicalJSON(), as: UTF8.self)
        #expect(!json.contains("laborCents"))
        #expect(calculation.laborTotalCents == nil)
    }

    @Test func sampleItemsAreSplitAndAddUp() {
        for item in LocalStore.samplePriceItems {
            #expect(item.hasPriceSplit)
            #expect((item.materialCents ?? 0) + (item.laborCents ?? 0) == item.unitPriceCents)
        }
    }

    @Test func materialPurchaseCostUsesPackPrices() {
        var paint = MaterialRate(name: "Farbe", scope: .rooms, basis: .netWallArea, consumption: 0.15, coats: 2,
                                 unit: "l", packSize: 12.5, packName: "Eimer", wastePercent: 0)
        paint.packPriceCents = 4990
        let needs = MaterialCalculator.needs(for: [.rectangle(width: 4, depth: 3, height: 2.5)], materials: [paint])
        // 35 m² × 0.3 l = 10.5 l → 1 bucket
        #expect(MaterialCalculator.totalCost(needs) == 4990)
    }
}
