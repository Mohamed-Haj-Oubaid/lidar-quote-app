import Foundation
import CryptoKit

/// One room as input to a calculation.
nonisolated struct RoomInput: Hashable {
    var surveyID: UUID?
    var roomName: String
    var measurement: RoomMeasurement
    var selections: [ItemSelection]

    init(surveyID: UUID? = nil, roomName: String, measurement: RoomMeasurement, selections: [ItemSelection]) {
        self.surveyID = surveyID
        self.roomName = roomName
        self.measurement = measurement
        self.selections = selections
    }
}

nonisolated struct QuoteLine: Codable, Hashable, Identifiable {
    /// Stable even when two rooms share a name (engine ≥ 1.1.0). Quotes from
    /// 1.0.0 have no ids and fall back to name and code.
    var id: String { "\(surveyID?.uuidString ?? roomName)|\(itemID?.uuidString ?? itemCode)" }
    /// Room the line belongs to (optional so 1.0.0 quotes still decode).
    var surveyID: UUID?
    /// Price-book item the line was priced from (optional so 1.0.0 quotes still decode).
    var itemID: UUID?
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
    /// Material and labour per unit and the labour share of `totalCents` (engine ≥ 1.3.0,
    /// only when the price item is split). Material share = total − labour.
    var unitMaterialCents: Int? = nil
    var unitLaborCents: Int? = nil
    var laborCents: Int? = nil

    var materialCents: Int? { laborCents.map { totalCents - $0 } }

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

    /// Canonical JSON – the ONLY encoding used for both the integrity hash and the
    /// bytes sent to the server (`calculation_json`), so the server can verify the hash.
    /// Sorted keys, compact, "/" not escaped (since engine 1.1.0).
    /// Labour costs contained in the net total (§ 35a EStG); nil when no line is split.
    var laborTotalCents: Int? {
        let split = lines.compactMap(\.laborCents)
        return split.isEmpty ? nil : split.reduce(0, +)
    }

    /// VAT on the labour share, rounded like the total VAT.
    var laborVATCents: Int? {
        laborTotalCents.map { EstimationEngine.roundedDivide($0 * vatRateBasisPoints, by: 10_000) }
    }

    func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// SHA-256 of the canonical JSON, verified by the server and recorded on the audit trail.
    func sha256Hex() throws -> String {
        Self.sha256Hex(of: try canonicalJSON())
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Deterministic, versioned pricing engine. Pure function of its inputs, runs
/// fully offline. Bump `version` whenever the rules change so old quotes stay
/// attributable to the rules that produced them.
nonisolated enum EstimationEngine {
    /// 1.1.0: quote lines carry surveyID/itemID, canonical JSON without escaped
    /// slashes, opening notes built from parts (no stray separators).
    /// 1.2.0: scaffold-area basis (wall length × (height + 1 m)).
    /// 1.3.0: lines of split price items carry material/labour per unit and the labour share.
    static let version = "1.3.0"

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
                let totalCents = roundedDivide(billedH * item.unitPriceCents, by: 100)
                let laborCents = item.hasPriceSplit
                    ? min(roundedDivide(billedH * (item.laborCents ?? 0), by: 100), totalCents)
                    : nil
                lines.append(QuoteLine(
                    surveyID: room.surveyID,
                    itemID: item.id,
                    roomName: room.roomName,
                    itemCode: item.code,
                    itemName: item.name,
                    unit: item.unit,
                    netQuantityHundredths: netH,
                    wastePercent: selection.wastePercent,
                    billedQuantityHundredths: billedH,
                    unitPriceCents: item.unitPriceCents,
                    totalCents: totalCents,
                    note: note,
                    unitMaterialCents: item.hasPriceSplit ? (item.materialCents ?? 0) : nil,
                    unitLaborCents: item.hasPriceSplit ? (item.laborCents ?? 0) : nil,
                    laborCents: laborCents
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
        case .scaffoldArea:
            return (m.scaffoldArea, String(localized: "Wall length × (height + 1.00 m)"))
        }
    }

    /// Wall area after applying the opening deduction rule (Öffnungsabzug).
    /// The note is built from parts and is nil when the room has no openings (1.1.0).
    static func netWallArea(_ m: RoomMeasurement, rule: OpeningRule) -> (Double, String?) {
        guard !m.openings.isEmpty else { return (max(0, m.grossWallArea), nil) }
        let deducted: [RoomOpening]
        var parts: [String] = []
        switch rule.mode {
        case .none:
            deducted = []
            parts.append(String(localized: "No opening deduction"))
        case .all:
            deducted = m.openings
            parts.append(String(localized: "All openings deducted"))
        case .aboveThreshold:
            deducted = m.openings.filter { $0.area > rule.thresholdM2 }
            let threshold = rule.thresholdM2.formatted(.number.precision(.fractionLength(2)))
            parts.append(String(localized: "Openings > \(threshold) m² deducted"))
        }

        var area = m.grossWallArea - deducted.reduce(0) { $0 + $1.area }
        if rule.addReveals, !deducted.isEmpty {
            area += deducted.reduce(0) { $0 + $1.revealLength * rule.revealDepthM }
            parts.append(String(localized: "reveals added"))
        }
        return (max(0, area), parts.joined(separator: ", "))
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
