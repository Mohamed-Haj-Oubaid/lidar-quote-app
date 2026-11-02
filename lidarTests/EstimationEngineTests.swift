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
