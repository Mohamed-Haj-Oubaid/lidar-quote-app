import Foundation

/// A floor outline drawn by hand. The freehand stroke is turned into straight
/// walls; each wall keeps its drawn direction and receives a real length once the
/// worker measures it (laser meter or typed). The outline is always closed.
nonisolated struct FloorSketch: Codable, Hashable {
    struct Wall: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String? = nil
        /// Direction in which the wall was drawn, in radians (sketch space, y down).
        var angle: Double
        /// Drawn length in sketch points – used only until the wall is measured.
        var sketchLength: Double
        /// Measured length in metres.
        var measuredLength: Double?
        /// Measured height in metres; falls back to the room height.
        var measuredHeight: Double?
        var openings: [RoomOpening] = []
    }

    var walls: [Wall]
    var roomHeight: Double = 2.5

    /// Corners closer than this (sketch points) to the stroke start close the outline.
    static let closeTolerance = 60.0
    /// Directions within this angle (degrees) of a multiple of 45° snap to it.
    static let snapDegrees = 12.0

    // MARK: Stroke → walls

    /// Builds a sketch from a freehand stroke (sketch points). Returns nil when the
    /// stroke is too small to form at least three walls.
    static func fromStroke(_ stroke: [PlanPoint]) -> FloorSketch? {
        guard stroke.count >= 3 else { return nil }
        var corners = simplify(stroke, epsilon: 18)
        // A closed drawing ends near its start – drop the duplicate end corner.
        if corners.count > 3, let first = corners.first, let last = corners.last,
           distance(first, last) <= closeTolerance {
            corners.removeLast()
        }
        corners = removeShortSegments(corners, minimum: 20)
        guard corners.count >= 3 else { return nil }

        let walls = corners.indices.map { index -> Wall in
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            return Wall(angle: snapped(atan2(b.y - a.y, b.x - a.x)), sketchLength: distance(a, b))
        }
        return FloorSketch(walls: walls)
    }

    /// Ramer–Douglas–Peucker: keeps the points where the stroke changes direction.
    static func simplify(_ points: [PlanPoint], epsilon: Double) -> [PlanPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var maxDistance = 0.0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(points[i], lineStart: first, lineEnd: last)
            if d > maxDistance {
                maxDistance = d
                index = i
            }
        }
        // For a closed loop (start == end) the distance falls back to the distance from
        // the start point, so the split happens at the farthest corner.
        guard maxDistance > epsilon else { return [first, last] }
        let left = simplify(Array(points[0...index]), epsilon: epsilon)
        let right = simplify(Array(points[index...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    private static func removeShortSegments(_ corners: [PlanPoint], minimum: Double) -> [PlanPoint] {
        var result = corners
        var changed = true
        while changed, result.count > 3 {
            changed = false
            for i in result.indices {
                let next = (i + 1) % result.count
                if distance(result[i], result[next]) < minimum {
                    result.remove(at: next)
                    changed = true
                    break
                }
            }
        }
        return result
    }

    /// Snaps an angle to the nearest multiple of 45° when it is close enough.
    static func snapped(_ angle: Double) -> Double {
        let step = Double.pi / 4
        let nearest = (angle / step).rounded() * step
        return abs(angle - nearest) <= snapDegrees * .pi / 180 ? nearest : angle
    }

    // MARK: Plan in metres

    /// Fallback scale for unmeasured walls: metres per sketch point, derived from the
    /// measured walls (default 1 m = 40 pt).
    var metersPerPoint: Double {
        let measured = walls.filter { $0.measuredLength != nil && $0.sketchLength > 0 }
        guard !measured.isEmpty else { return 1.0 / 40 }
        let ratios = measured.map { ($0.measuredLength ?? 0) / $0.sketchLength }
        return ratios.reduce(0, +) / Double(ratios.count)
    }

    var allWallsMeasured: Bool { walls.allSatisfy { $0.measuredLength != nil } }

    /// Corner positions in metres. Walls keep their drawn directions; the closing
    /// error is distributed over the unmeasured walls (or, when every wall was
    /// measured, over all walls in proportion to their length – compass rule).
    func corners() -> [PlanPoint] {
        guard !walls.isEmpty else { return [] }
        let scale = metersPerPoint
        let lengths = walls.map { $0.measuredLength ?? $0.sketchLength * scale }
        var vectors = walls.indices.map { PlanPoint(x: cos(walls[$0].angle) * lengths[$0], y: sin(walls[$0].angle) * lengths[$0]) }
        let error = vectors.reduce(PlanPoint(x: 0, y: 0)) { PlanPoint(x: $0.x - $1.x, y: $0.y - $1.y) }

        let adjustable = walls.indices.filter { walls[$0].measuredLength == nil }
        let targets = adjustable.isEmpty ? Array(walls.indices) : adjustable
        let total = targets.reduce(0) { $0 + lengths[$1] }
        if total > 0 {
            for i in targets {
                let share = lengths[i] / total
                vectors[i].x += error.x * share
                vectors[i].y += error.y * share
            }
        }

        var points = [PlanPoint(x: 0, y: 0)]
        for vector in vectors.dropLast() {
            let last = points[points.count - 1]
            points.append(PlanPoint(x: last.x + vector.x, y: last.y + vector.y))
        }
        return points
    }

    /// Converts the sketch into the app's room geometry.
    func measurement() -> RoomMeasurement {
        let points = corners()
        var segments: [WallSegment] = []
        var openings: [RoomOpening] = []
        for (index, wall) in walls.enumerated() {
            let segment = WallSegment(
                id: wall.id,
                name: wall.name,
                start: points[index],
                end: points[(index + 1) % points.count],
                height: wall.measuredHeight ?? roomHeight
            )
            segments.append(segment)
            for (number, opening) in wall.openings.enumerated() {
                var placed = opening
                placed.wallID = wall.id
                // Spread openings evenly along the wall when no position was given.
                placed.centerOffset = opening.centerOffset
                    ?? segment.length * Double(number + 1) / Double(wall.openings.count + 1)
                openings.append(placed)
            }
        }
        return RoomMeasurement(walls: segments, openings: openings, floorPolygon: points,
                               floorAreaOverride: nil, source: .manual, manuallyAdjusted: false)
    }

    // MARK: Helpers

    static func distance(_ a: PlanPoint, _ b: PlanPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private static func perpendicularDistance(_ p: PlanPoint, lineStart a: PlanPoint, lineEnd b: PlanPoint) -> Double {
        let length = distance(a, b)
        guard length > 0 else { return distance(p, a) }
        return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
    }
}
