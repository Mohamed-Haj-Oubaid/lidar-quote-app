import Foundation
import CryptoKit

/// One room as input to a calculation.
nonisolated struct RoomInput: Hashable {
    var roomName: String
    var measurement: RoomMeasurement
    var selections: [ItemSelection]
}

nonisolated struct QuoteLine: Codable, Hashable, Identifiable {
    var id: String { "\(roomName)|\(itemCode)" }
    var roomName: String
    var itemCode: String
    var itemName: String
    var unit: PricingUnit
    /// Quantities in hundredths of the unit (e.g. 1234 = 12.34 m²).
    var netQuantityHundredths: Int
    var wastePercent: Int
    var billedQuantityHundredths: Int
    var unitPriceCents: Int
    var totalCents: Int
    /// Human-readable explanation of deductions, e.g. "Openings > 2.50 m² deducted, reveals added".
    var note: String?

    var billedQuantity: Double { Double(billedQuantityHundredths) / 100 }
    var netQuantity: Double { Double(netQuantityHundredths) / 100 }
}

nonisolated struct RoomSummary: Codable, Hashable {
    var roomName: String
    var floorAreaHundredths: Int
    var grossWallAreaHundredths: Int
    var openingAreaHundredths: Int
    var perimeterHundredths: Int
    var doorCount: Int
    var windowCount: Int
}

/// Frozen result of a calculation. Stored verbatim on an issued quote so it can
/// be reproduced and disputed later regardless of later price-book changes.
nonisolated struct QuoteCalculation: Codable, Hashable {
    var engineVersion: String
    var priceBookVersionID: UUID
    var priceBookVersion: Int
    var priceBookName: String
    var rooms: [RoomSummary]
    var lines: [QuoteLine]
    var netTotalCents: Int
    var vatRateBasisPoints: Int
    var vatCents: Int
    var grossTotalCents: Int

    /// Canonical JSON (sorted keys) – the basis of the integrity hash.
    func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// SHA-256 of the canonical JSON, recorded on the server audit trail.
    func sha256Hex() throws -> String {
        let digest = SHA256.hash(data: try canonicalJSON())
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Deterministic, versioned pricing engine. Pure function of its inputs, runs
/// fully offline. Bump `version` whenever the rules change so old quotes stay
/// attributable to the rules that produced them.
nonisolated enum EstimationEngine {
    static let version = "1.0.0"

    static func calculate(rooms: [RoomInput], priceBook: PriceBookSnapshot) -> QuoteCalculation {
        let itemsByID = Dictionary(uniqueKeysWithValues: priceBook.items.map { ($0.id, $0) })
        var lines: [QuoteLine] = []
        var summaries: [RoomSummary] = []

        for room in rooms {
            let m = room.measurement
            summaries.append(RoomSummary(
                roomName: room.roomName,
                floorAreaHundredths: hundredths(m.floorArea),
                grossWallAreaHundredths: hundredths(m.grossWallArea),
                openingAreaHundredths: hundredths(m.totalOpeningArea),
                perimeterHundredths: hundredths(m.perimeter),
                doorCount: m.doorCount,
                windowCount: m.windowCount
            ))

            for selection in room.selections {
                guard let item = itemsByID[selection.itemID] else { continue }
                let (quantity, note) = quantity(for: item, in: m)
                let netH = hundredths(quantity)
                let billedH = applyWaste(netH, percent: selection.wastePercent, unit: item.unit)
                guard billedH > 0 else { continue }
                lines.append(QuoteLine(
                    roomName: room.roomName,
                    itemCode: item.code,
                    itemName: item.name,
                    unit: item.unit,
                    netQuantityHundredths: netH,
                    wastePercent: selection.wastePercent,
                    billedQuantityHundredths: billedH,
                    unitPriceCents: item.unitPriceCents,
                    totalCents: roundedDivide(billedH * item.unitPriceCents, by: 100),
                    note: note
                ))
            }
        }

        let net = lines.reduce(0) { $0 + $1.totalCents }
        let vat = roundedDivide(net * priceBook.vatRateBasisPoints, by: 10_000)
        return QuoteCalculation(
            engineVersion: version,
            priceBookVersionID: priceBook.versionID,
            priceBookVersion: priceBook.version,
            priceBookName: priceBook.name,
            rooms: summaries,
            lines: lines,
            netTotalCents: net,
            vatRateBasisPoints: priceBook.vatRateBasisPoints,
            vatCents: vat,
            grossTotalCents: net + vat
        )
    }

    // MARK: - Quantity rules

    static func quantity(for item: PriceItem, in m: RoomMeasurement) -> (Double, String?) {
        switch item.basis {
        case .wallArea:
            return netWallArea(m, rule: item.openingRule)
        case .floorArea, .ceilingArea:
            return (m.floorArea, nil)
        case .skirtingLength:
            let doorWidths = m.openings.filter { $0.kind == .door }.reduce(0) { $0 + $1.width }
            return (max(0, m.perimeter - doorWidths), doorWidths > 0 ? String(localized: "Door widths deducted") : nil)
        case .revealLength:
            return (m.openings.reduce(0) { $0 + $1.revealLength }, nil)
        case .doorCount:
            return (Double(m.doorCount), nil)
        case .windowCount:
            return (Double(m.windowCount), nil)
        case .fixedPiece:
            return (1, nil)
        }
    }

    /// Wall area after applying the opening deduction rule (Öffnungsabzug).
    static func netWallArea(_ m: RoomMeasurement, rule: OpeningRule) -> (Double, String?) {
        let deducted: [RoomOpening]
        let note: String?
        switch rule.mode {
        case .none:
            deducted = []
            note = m.openings.isEmpty ? nil : String(localized: "No opening deduction")
        case .all:
            deducted = m.openings
            note = m.openings.isEmpty ? nil : String(localized: "All openings deducted")
        case .aboveThreshold:
            deducted = m.openings.filter { $0.area > rule.thresholdM2 }
            let threshold = rule.thresholdM2.formatted(.number.precision(.fractionLength(2)))
            note = String(localized: "Openings > \(threshold) m² deducted")
        }

        var area = m.grossWallArea - deducted.reduce(0) { $0 + $1.area }
        var finalNote = note
        if rule.addReveals, !deducted.isEmpty {
            area += deducted.reduce(0) { $0 + $1.revealLength * rule.revealDepthM }
            finalNote = (note ?? "") + String(localized: ", reveals added")
        }
        return (max(0, area), finalNote)
    }

    // MARK: - Integer arithmetic helpers

    static func hundredths(_ value: Double) -> Int {
        Int((value * 100).rounded(.toNearestOrAwayFromZero))
    }

    /// Adds the wastage buffer. Pieces are always rounded up to whole pieces.
    static func applyWaste(_ quantityHundredths: Int, percent: Int, unit: PricingUnit) -> Int {
        let withWaste = roundedDivide(quantityHundredths * (100 + percent), by: 100)
        guard unit == .piece else { return withWaste }
        return Int((Double(withWaste) / 100).rounded(.up)) * 100
    }

    /// Integer division rounding half away from zero (commercial rounding).
    static func roundedDivide(_ value: Int, by divisor: Int) -> Int {
        value >= 0 ? (value + divisor / 2) / divisor : -((-value + divisor / 2) / divisor)
    }
}
