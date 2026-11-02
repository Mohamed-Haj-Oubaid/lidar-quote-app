import Foundation
import RoomPlan
import simd

/// Converts RoomPlan results into the app's editable `RoomMeasurement` and
/// manages on-device media files. Runs entirely offline.
enum SurveyEngine {
    /// RoomPlan requires a LiDAR-equipped iPhone Pro / iPad Pro.
    static var isScanningSupported: Bool { RoomCaptureSession.isSupported }

    /// Projects walls, openings and the floor outline onto the 2D floor plan (world X/Z plane).
    static func measurement(from room: CapturedRoom) -> RoomMeasurement {
        var walls: [WallSegment] = []
        for wall in room.walls {
            let position = planPoint(wall.transform.columns.3)
            let direction = simd_normalize(SIMD2(Double(wall.transform.columns.0.x), Double(wall.transform.columns.0.z)))
            let half = Double(wall.dimensions.x) / 2
            walls.append(WallSegment(
                id: wall.identifier,
                start: PlanPoint(x: position.x - direction.x * half, y: position.y - direction.y * half),
                end: PlanPoint(x: position.x + direction.x * half, y: position.y + direction.y * half),
                height: Double(wall.dimensions.y)
            ))
        }

        func openings(_ surfaces: [CapturedRoom.Surface], kind: RoomOpening.Kind) -> [RoomOpening] {
            surfaces.map { surface in
                let center = planPoint(surface.transform.columns.3)
                let wall = walls.first { $0.id == surface.parentIdentifier } ?? nearestWall(to: center, in: walls)
                return RoomOpening(
                    id: surface.identifier,
                    kind: kind,
                    width: Double(surface.dimensions.x),
                    height: Double(surface.dimensions.y),
                    wallID: wall?.id,
                    centerOffset: wall.map { offset(of: center, along: $0) }
                )
            }
        }

        let allOpenings = openings(room.doors, kind: .door)
            + openings(room.windows, kind: .window)
            + openings(room.openings, kind: .opening)

        // Floor corners are in the floor surface's local space – transform them to world space.
        var floorPolygon: [PlanPoint] = []
        if let floor = room.floors.first {
            floorPolygon = floor.polygonCorners.map { corner in
                planPoint(floor.transform * SIMD4(corner.x, corner.y, corner.z, 1))
            }
        }

        return RoomMeasurement(walls: walls, openings: allOpenings, floorPolygon: floorPolygon,
                               floorAreaOverride: nil, source: .roomPlan, manuallyAdjusted: false)
    }

    // MARK: - Media (device-only by default)

    /// Exports the parametric (geometry-only, no camera imagery) USDZ model and
    /// returns its file name inside the protected media directory.
    static func storeModel(_ room: CapturedRoom, surveyID: UUID) throws -> String {
        let fileName = "\(surveyID.uuidString).usdz"
        let url = try mediaDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        try room.export(to: url, exportOptions: .parametric)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return fileName
    }

    static func mediaURL(for fileName: String) throws -> URL {
        try mediaDirectory().appendingPathComponent(fileName)
    }

    static func mediaDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Media", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            // Media must never land in iCloud/iTunes backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(values)
        }
        return directory
    }

    // MARK: - Geometry helpers

    private static func planPoint(_ column: SIMD4<Float>) -> PlanPoint {
        PlanPoint(x: Double(column.x), y: Double(column.z))
    }

    static func offset(of point: PlanPoint, along wall: WallSegment) -> Double {
        let dx = wall.end.x - wall.start.x
        let dy = wall.end.y - wall.start.y
        let length = max(wall.length, .ulpOfOne)
        return ((point.x - wall.start.x) * dx + (point.y - wall.start.y) * dy) / length
    }

    static func distance(from point: PlanPoint, to wall: WallSegment) -> Double {
        let t = min(max(offset(of: point, along: wall) / max(wall.length, .ulpOfOne), 0), 1)
        let px = wall.start.x + (wall.end.x - wall.start.x) * t
        let py = wall.start.y + (wall.end.y - wall.start.y) * t
        return hypot(point.x - px, point.y - py)
    }

    static func nearestWall(to point: PlanPoint, in walls: [WallSegment]) -> WallSegment? {
        walls.min { distance(from: point, to: $0) < distance(from: point, to: $1) }
    }
}
