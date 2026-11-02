import Foundation
import Testing
@testable import lidar

/// Shared fixtures for engine tests.
enum Fixture {
    /// 4 × 3 m room, 2.5 m high: walls 35 m² gross, floor 12 m², perimeter 14 m.
    static func room(openings: [RoomOpening] = []) -> RoomMeasurement {
        var room = RoomMeasurement.rectangle(width: 4, depth: 3, height: 2.5)
        room.openings = openings
        return room
    }

    static let door = RoomOpening(id: UUID(), kind: .door, width: 1, height: 2, wallID: nil, centerOffset: nil)        // 2.00 m²
    static let smallWindow = RoomOpening(id: UUID(), kind: .window, width: 1, height: 1, wallID: nil, centerOffset: nil) // 1.00 m²
    static let bigWindow = RoomOpening(id: UUID(), kind: .window, width: 2, height: 1.5, wallID: nil, centerOffset: nil) // 3.00 m²

    static func item(_ basis: QuantityBasis, price: Int = 1000, rule: OpeningRule = .noDeduction) -> PriceItem {
        PriceItem(id: UUID(), code: basis.rawValue, name: basis.title, basis: basis, unitPriceCents: price,
                  openingRule: rule, defaultWastePercent: 0)
    }
}

/// M3 – opening notes.
struct OpeningNoteTests {
    @Test func noNoteWithoutOpenings() {
        for rule in [OpeningRule.noDeduction, .deductAll, .vobPainting] {
            let (area, note) = EstimationEngine.netWallArea(Fixture.room(), rule: rule)
            #expect(abs(area - 35) < 1e-9)
            #expect(note == nil)
        }
    }

    @Test func notesAreJoinedWithoutStraySeparators() throws {
        let rule = OpeningRule(mode: .all, thresholdM2: 0, addReveals: true, revealDepthM: 0.1)
        let (_, note) = EstimationEngine.netWallArea(Fixture.room(openings: [Fixture.door]), rule: rule)
        let text = try #require(note)
        #expect(!text.hasPrefix(","))
        #expect(text.hasSuffix(", reveals added"))
        #expect(text.components(separatedBy: ", ").count == 2)
    }

    @Test func thresholdNoteWithoutDeductedOpeningsHasNoRevealPart() throws {
        let (_, note) = EstimationEngine.netWallArea(Fixture.room(openings: [Fixture.smallWindow]), rule: .vobPainting)
        let text = try #require(note)
        #expect(text.contains("deducted"))
        #expect(!text.contains("reveals"))
    }
}

/// M6 – quantity rules, rounding and VAT of the deterministic engine.
struct EstimationEngineTests {
    private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    private func quantity(_ basis: QuantityBasis, rule: OpeningRule = .noDeduction, openings: [RoomOpening]) -> Double {
        EstimationEngine.quantity(for: Fixture.item(basis, rule: rule), in: Fixture.room(openings: openings)).0
    }

    @Test func everyQuantityBasis() {
        let openings = [Fixture.door, Fixture.smallWindow, Fixture.bigWindow]
        #expect(approx(quantity(.wallArea, openings: openings), 35))           // no deduction rule
        #expect(approx(quantity(.floorArea, openings: openings), 12))
        #expect(approx(quantity(.ceilingArea, openings: openings), 12))
        #expect(approx(quantity(.skirtingLength, openings: openings), 13))     // 14 m minus 1 m door
        #expect(approx(quantity(.revealLength, openings: openings), 5 + 4 + 7)) // door 2h+w, windows 2(h+w)
        #expect(quantity(.doorCount, openings: openings) == 1)
        #expect(quantity(.windowCount, openings: openings) == 2)
        #expect(quantity(.fixedPiece, openings: openings) == 1)
    }

    @Test func openingRuleModes() {
        let openings = [Fixture.door, Fixture.smallWindow, Fixture.bigWindow]  // 2 + 1 + 3 m²
        #expect(approx(EstimationEngine.netWallArea(Fixture.room(openings: openings), rule: .noDeduction).0, 35))
        #expect(approx(EstimationEngine.netWallArea(Fixture.room(openings: openings), rule: .deductAll).0, 29))
        let threshold = OpeningRule(mode: .aboveThreshold, thresholdM2: 2.5, addReveals: false, revealDepthM: 0)
        #expect(approx(EstimationEngine.netWallArea(Fixture.room(openings: openings), rule: threshold).0, 32))
    }

    @Test func openingOfExactlyTheThresholdIsNotDeducted() {
        let exact = RoomOpening(id: UUID(), kind: .window, width: 2.5, height: 1, wallID: nil, centerOffset: nil) // 2.50 m²
        let (area, _) = EstimationEngine.netWallArea(Fixture.room(openings: [exact]), rule: .vobPainting)
        #expect(approx(area, 35))
    }

    @Test func revealsOfDeductedOpeningsAreAdded() {
        // VOB painting: big window deducted (3 m²), reveal 2·(1.5+2) m × 0.15 m = 1.05 m² added back.
        let (area, _) = EstimationEngine.netWallArea(Fixture.room(openings: [Fixture.door, Fixture.bigWindow]), rule: .vobPainting)
        #expect(approx(area, 35 - 3 + 1.05))
    }

    @Test func wasteRounding() {
        #expect(EstimationEngine.applyWaste(100, percent: 0, unit: .piece) == 100)
        #expect(EstimationEngine.applyWaste(100, percent: 5, unit: .piece) == 200)      // 1.05 pcs → 2 pcs
        #expect(EstimationEngine.applyWaste(300, percent: 10, unit: .piece) == 400)     // 3.3 → 4
        #expect(EstimationEngine.applyWaste(1234, percent: 10, unit: .squareMeter) == 1357) // 13.574 → 13.57
        #expect(EstimationEngine.applyWaste(1235, percent: 10, unit: .linearMeter) == 1359) // 13.585 → 13.59
    }

    @Test func commercialRoundingOfHalvesAndNegatives() {
        #expect(EstimationEngine.roundedDivide(150, by: 100) == 2)
        #expect(EstimationEngine.roundedDivide(149, by: 100) == 1)
        #expect(EstimationEngine.roundedDivide(-150, by: 100) == -2)
        #expect(EstimationEngine.roundedDivide(-149, by: 100) == -1)
        #expect(EstimationEngine.roundedDivide(50, by: 100) == 1)
        #expect(EstimationEngine.roundedDivide(-50, by: 100) == -1)
        #expect(EstimationEngine.hundredths(0.125) == 13)
        #expect(EstimationEngine.hundredths(-0.125) == -13)
    }

    @Test func vatIsRoundedCommerciallyOnTheNetTotal() {
        let item = Fixture.item(.fixedPiece, price: 12345)
        let book = PriceBookSnapshot(versionID: UUID(), version: 1, name: "B", vatRateBasisPoints: 1900, items: [item])
        let calculation = EstimationEngine.calculate(
            rooms: [RoomInput(roomName: "A", measurement: .empty, selections: [ItemSelection(itemID: item.id, wastePercent: 0)])],
            priceBook: book)
        #expect(calculation.netTotalCents == 12345)
        #expect(calculation.vatCents == 2346)           // 2345.55 → 2346
        #expect(calculation.grossTotalCents == 14691)
        #expect(calculation.lines.first?.totalCents == 12345)
    }

    @Test func linesWithZeroQuantityAreOmittedAndUnknownItemsIgnored() {
        let item = Fixture.item(.doorCount)
        let book = PriceBookSnapshot(versionID: UUID(), version: 1, name: "B", vatRateBasisPoints: 1900, items: [item])
        let calculation = EstimationEngine.calculate(
            rooms: [RoomInput(roomName: "A", measurement: Fixture.room(),
                              selections: [ItemSelection(itemID: item.id, wastePercent: 0), ItemSelection(itemID: UUID(), wastePercent: 0)])],
            priceBook: book)
        #expect(calculation.lines.isEmpty)
        #expect(calculation.netTotalCents == 0)
    }
}
