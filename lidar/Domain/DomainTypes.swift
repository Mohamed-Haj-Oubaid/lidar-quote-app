import Foundation

// MARK: - Pricing units & quantity bases

/// Billing unit printed on a quote line.
nonisolated enum PricingUnit: String, Codable, CaseIterable, Identifiable {
    case squareMeter = "m2"
    case linearMeter = "lm"
    case piece = "pc"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .squareMeter: "m²"
        case .linearMeter: "lm"
        case .piece: "pc"
        }
    }
}

/// Which measured quantity of a room a price item is billed against.
/// The billing unit is derived from the basis so a price-book entry can never
/// combine e.g. "per m²" with a door count.
nonisolated enum QuantityBasis: String, Codable, CaseIterable, Identifiable {
    case wallArea
    case floorArea
    case ceilingArea
    case skirtingLength
    case revealLength
    case doorCount
    case windowCount
    case fixedPiece

    var id: String { rawValue }

    var unit: PricingUnit {
        switch self {
        case .wallArea, .floorArea, .ceilingArea: .squareMeter
        case .skirtingLength, .revealLength: .linearMeter
        case .doorCount, .windowCount, .fixedPiece: .piece
        }
    }

    var title: String {
        switch self {
        case .wallArea: String(localized: "Wall area")
        case .floorArea: String(localized: "Floor area")
        case .ceilingArea: String(localized: "Ceiling area")
        case .skirtingLength: String(localized: "Skirting length")
        case .revealLength: String(localized: "Reveal length")
        case .doorCount: String(localized: "Per door")
        case .windowCount: String(localized: "Per window")
        case .fixedPiece: String(localized: "Fixed piece")
        }
    }
}

// MARK: - Opening deduction (Öffnungsabzug)

/// Opening deduction rule for wall-area items. Modelled as a value object, not a
/// boolean, because German trade billing (VOB/C, e.g. DIN 18363 for painting)
/// only deducts openings above a size threshold and may add reveals (Laibungen).
/// Thresholds must be confirmed with a trade expert per trade.
nonisolated struct OpeningRule: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case none
        case all
        case aboveThreshold
        var id: String { rawValue }
    }

    var mode: Mode
    /// Only openings strictly larger than this area (m²) are deducted in `.aboveThreshold` mode.
    var thresholdM2: Double
    /// When true, the reveal area of every deducted opening is added back to the wall area.
    var addReveals: Bool
    /// Reveal depth in metres (typical wall thickness at the opening).
    var revealDepthM: Double

    static let noDeduction = OpeningRule(mode: .none, thresholdM2: 0, addReveals: false, revealDepthM: 0)
    static let deductAll = OpeningRule(mode: .all, thresholdM2: 0, addReveals: false, revealDepthM: 0)
    /// DIN 18363-style default: deduct openings > 2.5 m², add reveals.
    static let vobPainting = OpeningRule(mode: .aboveThreshold, thresholdM2: 2.5, addReveals: true, revealDepthM: 0.15)
    /// Facade systems (e.g. WDVS, DIN 18345): deduct openings > 2.5 m²; reveals are billed as their own item.
    static let wallSystem = OpeningRule(mode: .aboveThreshold, thresholdM2: 2.5, addReveals: false, revealDepthM: 0)
}

// MARK: - Price book

/// One service / material in a tenant's price book. Money is stored as integer
/// cents so every calculation is exactly reproducible.
nonisolated struct PriceItem: Codable, Identifiable, Hashable {
    var id: UUID
    var code: String
    var name: String
    var basis: QuantityBasis
    var unitPriceCents: Int
    var openingRule: OpeningRule
    /// Default wastage buffer (Verschnitt) in percent, e.g. 0, 5 or 10.
    var defaultWastePercent: Int

    var unit: PricingUnit { basis.unit }
}

/// Immutable view of a published price-book version used as calculation input.
nonisolated struct PriceBookSnapshot: Codable, Hashable {
    var versionID: UUID
    var version: Int
    var name: String
    /// VAT rate in basis points (1900 = 19 %).
    var vatRateBasisPoints: Int
    var items: [PriceItem]
}

/// A price item chosen for a room, with its wastage buffer.
nonisolated struct ItemSelection: Codable, Hashable, Identifiable {
    var itemID: UUID
    var wastePercent: Int
    var id: UUID { itemID }
}

// MARK: - Room geometry (Aufmaß)

/// A point on the 2D floor plan, in metres (world X / Z plane).
nonisolated struct PlanPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

nonisolated struct WallSegment: Codable, Hashable, Identifiable {
    var id: UUID
    var start: PlanPoint
    var end: PlanPoint
    var height: Double

    var length: Double { hypot(end.x - start.x, end.y - start.y) }
    var grossArea: Double { length * height }
}

nonisolated struct RoomOpening: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case door, window, opening
        var id: String { rawValue }
        var title: String {
            switch self {
            case .door: String(localized: "Door")
            case .window: String(localized: "Window")
            case .opening: String(localized: "Opening")
            }
        }
    }

    var id: UUID
    var kind: Kind
    var width: Double
    var height: Double
    /// Wall this opening sits in (if known) and the distance of its centre from the wall start.
    var wallID: UUID?
    var centerOffset: Double?

    var area: Double { width * height }

    /// Linear metres of reveal around the opening (doors have no reveal at the floor).
    var revealLength: Double {
        switch kind {
        case .door: 2 * height + width
        case .window, .opening: 2 * (height + width)
        }
    }
}

/// Complete measured geometry of one room. Produced by the `SurveyEngine` from a
/// RoomPlan scan or entered manually, and editable afterwards in the plan editor.
nonisolated struct RoomMeasurement: Codable, Hashable {
    enum Source: String, Codable { case roomPlan, manual }

    var walls: [WallSegment]
    var openings: [RoomOpening]
    var floorPolygon: [PlanPoint]
    /// Manual override for the floor area, e.g. after the worker re-measured by tape.
    var floorAreaOverride: Double?
    var source: Source
    var manuallyAdjusted: Bool

    static let empty = RoomMeasurement(walls: [], openings: [], floorPolygon: [], floorAreaOverride: nil, source: .manual, manuallyAdjusted: false)

    var grossWallArea: Double { walls.reduce(0) { $0 + $1.grossArea } }
    var totalOpeningArea: Double { openings.reduce(0) { $0 + $1.area } }
    var doorCount: Int { openings.filter { $0.kind == .door }.count }
    var windowCount: Int { openings.filter { $0.kind == .window }.count }

    var averageWallHeight: Double {
        guard !walls.isEmpty else { return 0 }
        return walls.reduce(0) { $0 + $1.height } / Double(walls.count)
    }

    /// Floor area via the shoelace formula over the floor polygon.
    var floorArea: Double {
        if let floorAreaOverride { return floorAreaOverride }
        guard floorPolygon.count >= 3 else { return 0 }
        var sum = 0.0
        for index in floorPolygon.indices {
            let a = floorPolygon[index]
            let b = floorPolygon[(index + 1) % floorPolygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Perimeter along the walls.
    var perimeter: Double { walls.reduce(0) { $0 + $1.length } }

    // MARK: Plan editing

    /// Corners closer than this (metres) count as connected.
    static let joinTolerance = 0.05

    /// Result of a geometry edit.
    struct Edit {
        var measurement: RoomMeasurement
        /// False when the walls do not form a closed loop, so the floor area could not be
        /// recalculated; the previous area is then kept as a manual override.
        var floorRecalculated: Bool
    }

    /// Changes one wall's length and keeps the plan consistent:
    /// the wall's end moves along its direction, the wall attached at that corner is
    /// shifted by the same offset (keeping its length and direction) and the wall after
    /// it stretches to stay connected – a 4 × 3 rectangle with one 5 m wall becomes
    /// 5 × 3. The floor polygon is rebuilt from the walls when they form a closed loop.
    func settingLength(_ newLength: Double, ofWall wallID: UUID) -> Edit {
        guard let index = walls.firstIndex(where: { $0.id == wallID }),
              newLength > 0, walls[index].length > 0 else {
            return Edit(measurement: self, floorRecalculated: true)
        }
        var result = self
        let wall = walls[index]
        let factor = newLength / wall.length
        let newEnd = PlanPoint(x: wall.start.x + (wall.end.x - wall.start.x) * factor,
                               y: wall.start.y + (wall.end.y - wall.start.y) * factor)
        let delta = PlanPoint(x: newEnd.x - wall.end.x, y: newEnd.y - wall.end.y)
        let tolerance = Self.joinTolerance
        func near(_ a: PlanPoint, _ b: PlanPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) <= tolerance }
        func moved(_ p: PlanPoint) -> PlanPoint { PlanPoint(x: p.x + delta.x, y: p.y + delta.y) }

        result.walls[index].end = newEnd
        for j in walls.indices where j != index {
            let other = walls[j]
            let atStart = near(other.start, wall.end)
            let atEnd = near(other.end, wall.end)
            guard atStart || atEnd else { continue }
            let far = atStart ? other.end : other.start
            // In a triangle the attached wall's far corner is this wall's start: just move the shared corner.
            if near(far, wall.start) {
                if atStart { result.walls[j].start = newEnd } else { result.walls[j].end = newEnd }
                continue
            }
            // Shift the attached wall, then drag the corner of the next wall along.
            result.walls[j].start = moved(other.start)
            result.walls[j].end = moved(other.end)
            for k in walls.indices where k != index && k != j {
                if near(walls[k].start, far) { result.walls[k].start = moved(walls[k].start) }
                if near(walls[k].end, far) { result.walls[k].end = moved(walls[k].end) }
            }
        }
        // Keep openings inside their (possibly shorter) walls.
        for o in result.openings.indices {
            guard let id = result.openings[o].wallID, let w = result.walls.first(where: { $0.id == id }),
                  let offset = result.openings[o].centerOffset else { continue }
            result.openings[o].centerOffset = min(max(offset, 0), w.length)
        }
        result.manuallyAdjusted = true
        return result.rebuildingFloor()
    }

    /// Rebuilds `floorPolygon` from the walls when they form a closed loop; otherwise keeps
    /// the current floor area as a manual override.
    func rebuildingFloor() -> Edit {
        var result = self
        if let loop = Self.closedLoop(of: walls) {
            result.floorPolygon = loop
            return Edit(measurement: result, floorRecalculated: true)
        }
        if result.floorAreaOverride == nil { result.floorAreaOverride = floorArea }
        return Edit(measurement: result, floorRecalculated: false)
    }

    /// Ordered corner points when the walls connect end-to-start into one closed loop
    /// (walls may point either way), else nil.
    static func closedLoop(of walls: [WallSegment]) -> [PlanPoint]? {
        guard walls.count >= 3, let first = walls.first else { return nil }
        func near(_ a: PlanPoint, _ b: PlanPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) <= joinTolerance }
        var remaining = Array(walls.dropFirst())
        var points = [first.start]
        var cursor = first.end
        while !remaining.isEmpty {
            guard let next = remaining.firstIndex(where: { near($0.start, cursor) || near($0.end, cursor) }) else { return nil }
            let wall = remaining.remove(at: next)
            points.append(cursor)
            cursor = near(wall.start, cursor) ? wall.end : wall.start
        }
        return near(cursor, first.start) ? points : nil
    }

    /// Width and depth when the room is an axis-aligned rectangle (as created by
    /// `rectangle(width:depth:height:)`), else nil.
    var rectangleSize: (width: Double, depth: Double)? {
        guard walls.count == 4, Self.closedLoop(of: walls) != nil else { return nil }
        let tolerance = Self.joinTolerance
        for (index, wall) in walls.enumerated() {
            let horizontal = abs(wall.end.y - wall.start.y) <= tolerance
            let vertical = abs(wall.end.x - wall.start.x) <= tolerance
            guard index.isMultiple(of: 2) ? horizontal : vertical else { return nil }
        }
        return (walls[0].length, walls[1].length)
    }

    /// Regenerates a rectangular room with new width and depth, keeping wall ids,
    /// heights and openings.
    func resizedRectangle(width: Double, depth: Double) -> RoomMeasurement {
        guard rectangleSize != nil, width > 0, depth > 0 else { return self }
        let origin = walls[0].start
        let sx = walls[0].end.x >= walls[0].start.x ? 1.0 : -1.0
        let sy = walls[1].end.y >= walls[1].start.y ? 1.0 : -1.0
        let corners = [origin,
                       PlanPoint(x: origin.x + sx * width, y: origin.y),
                       PlanPoint(x: origin.x + sx * width, y: origin.y + sy * depth),
                       PlanPoint(x: origin.x, y: origin.y + sy * depth)]
        var result = self
        for index in walls.indices {
            result.walls[index].start = corners[index]
            result.walls[index].end = corners[(index + 1) % 4]
        }
        result.floorPolygon = corners
        result.manuallyAdjusted = true
        return result
    }

    /// Builds a simple rectangular room – used for manual entry on devices without LiDAR.
    static func rectangle(width: Double, depth: Double, height: Double) -> RoomMeasurement {
        let corners = [PlanPoint(x: 0, y: 0), PlanPoint(x: width, y: 0), PlanPoint(x: width, y: depth), PlanPoint(x: 0, y: depth)]
        let walls = corners.indices.map { index in
            WallSegment(id: UUID(), start: corners[index], end: corners[(index + 1) % corners.count], height: height)
        }
        return RoomMeasurement(walls: walls, openings: [], floorPolygon: corners, floorAreaOverride: nil, source: .manual, manuallyAdjusted: false)
    }
}
