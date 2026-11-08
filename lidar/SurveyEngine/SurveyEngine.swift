import Foundation
import RoomPlan
import simd

/// Converts RoomPlan results into the app's editable `RoomMeasurement` and
/// manages on-device media files. Runs entirely offline.
enum SurveyEngine {
    /// RoomPlan requires a LiDAR-equipped iPhone Pro / iPad Pro.
    static var isScanningSupported: Bool { RoomCaptureSession.isSupported }

    /// Projects walls, openings and the floor outline onto the 2D floor plan (world X/Z plane).
    static func measurement(
        from room: CapturedRoom,
        coloredSurface: ColoredSurfaceMesh? = nil
    ) -> RoomMeasurement {
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
                let parentWall = room.walls.first { $0.identifier == surface.parentIdentifier }
                let meshDepth = coloredSurface.flatMap {
                    estimatedDepth(
                        of: surface,
                        kind: kind,
                        from: $0,
                        roomSide: roomSideSign(of: surface, roomWalls: room.walls)
                    )
                }
                let detectedDepth: Double?
                if kind == .window {
                    detectedDepth = resolvedWindowDepth(
                        surfaceDepth: Double(surface.dimensions.z),
                        meshDepth: meshDepth
                    )
                } else {
                    detectedDepth = resolvedOpeningDepth(
                        surfaceDepth: Double(surface.dimensions.z),
                        meshDepth: meshDepth,
                        parentWallDepth: Double(parentWall?.dimensions.z ?? 0)
                    )
                }
                return RoomOpening(
                    id: surface.identifier,
                    kind: kind,
                    width: Double(surface.dimensions.x),
                    height: Double(surface.dimensions.y),
                    depth: detectedDepth,
                    centerHeight: Double(surface.transform.columns.3.y),
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

    /// Exports RoomPlan's polygon mesh, including wall polygons and recessed
    /// door/window cutouts, and returns its file name inside protected storage.
    static func storeModel(_ room: CapturedRoom, surveyID: UUID) throws -> String {
        let fileName = "\(surveyID.uuidString).usdz"
        let url = try mediaDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        try room.export(to: url, exportOptions: .mesh)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return fileName
    }

    static func storeWallTextures(_ images: [Data], surveyID: UUID) throws -> [String] {
        try images.enumerated().map { index, data in
            let fileName = "\(surveyID.uuidString)-wall-\(index + 1).jpg"
            let url = try mediaURL(for: fileName)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return fileName
        }
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

    private static func estimatedDepth(
        of surface: CapturedRoom.Surface,
        kind: RoomOpening.Kind,
        from mesh: ColoredSurfaceMesh,
        roomSide: Float?
    ) -> Double? {
        guard !mesh.vertices.isEmpty else { return nil }

        let localFromWorld = surface.transform.inverse
        let halfWidth = surface.dimensions.x / 2 + 0.08
        let halfHeight = surface.dimensions.y / 2 + 0.08
        var distances: [Float] = []
        distances.reserveCapacity(256)

        for vertex in mesh.vertices {
            let local = localFromWorld * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
            guard abs(local.x) <= halfWidth,
                  abs(local.y) <= halfHeight,
                  abs(local.z) <= 0.6 else {
                continue
            }
            // Windows: the reveal runs from the room face into the wall. Ignore
            // points in front of the room face and beyond the plausible reveal depth.
            if kind == .window, let roomSide {
                let intoWall = -local.z * roomSide
                if intoWall < -0.10 || intoWall > 0.34 { continue }
            }
            distances.append(abs(local.z))
        }

        if kind == .window, let roomSide,
           let faceDepth = windowRevealFromFaces(
               surface: surface,
               localFromWorld: localFromWorld,
               mesh: mesh,
               intoWallSign: -roomSide
           ) {
            return faceDepth
        }

        if kind == .window,
           let windowSides = windowRevealSideSamples(
               surface: surface,
               localFromWorld: localFromWorld,
               mesh: mesh,
               roomSide: roomSide
           ),
           let windowDepth = robustWindowRevealDepth(sideSamples: windowSides) {
            return windowDepth
        }

        guard distances.count >= 12 else { return nil }
        distances.sort()
        let nearIndex = Int(Double(distances.count - 1) * 0.1)
        let farIndex = Int(Double(distances.count - 1) * 0.9)
        let depth = Double(distances[farIndex] - distances[nearIndex])
        guard depth >= 0.02, depth <= 0.6 else { return nil }
        return depth
    }

    /// +1 / -1: which side of the opening's local Z axis faces the room interior
    /// (the side the worker scans from). Uses the centre of all walls as the interior.
    private static func roomSideSign(of surface: CapturedRoom.Surface, roomWalls: [CapturedRoom.Surface]) -> Float? {
        guard !roomWalls.isEmpty else { return nil }
        let sum = roomWalls.reduce(SIMD3<Float>.zero) { total, wall in
            total + SIMD3(wall.transform.columns.3.x, wall.transform.columns.3.y, wall.transform.columns.3.z)
        }
        let center = sum / Float(roomWalls.count)
        let local = surface.transform.inverse * SIMD4<Float>(center.x, surface.transform.columns.3.y, center.z, 1)
        guard abs(local.z) > 0.2 else { return nil }
        return local.z > 0 ? 1 : -1
    }

    /// Window reveal as seen from the room: distance from the room-side wall face
    /// around the opening to the face of the window frame. Both are front-facing
    /// solid surfaces, so glass and outdoor geometry are not needed.
    private static func windowRevealFromFaces(
        surface: CapturedRoom.Surface,
        localFromWorld: simd_float4x4,
        mesh: ColoredSurfaceMesh,
        intoWallSign: Float
    ) -> Double? {
        guard mesh.triangleIndices.count >= 3 else { return nil }
        let halfWidth = surface.dimensions.x / 2
        let halfHeight = surface.dimensions.y / 2
        var wallFace: [Float] = []
        var frameFace: [Float] = []

        func localPoint(at index: UInt32) -> SIMD3<Float>? {
            guard Int(index) < mesh.vertices.count else { return nil }
            let vertex = mesh.vertices[Int(index)]
            let local = localFromWorld * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
            // z = distance from the room into the wall.
            return SIMD3(local.x, local.y, local.z * intoWallSign)
        }

        for triangleStart in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
            guard let first = localPoint(at: mesh.triangleIndices[triangleStart]),
                  let second = localPoint(at: mesh.triangleIndices[triangleStart + 1]),
                  let third = localPoint(at: mesh.triangleIndices[triangleStart + 2]) else {
                continue
            }
            let cross = simd_cross(second - first, third - first)
            guard simd_length_squared(cross) > 0.000_001 else { continue }
            // Only surfaces that face the room (wall face, frame face).
            guard abs(simd_normalize(cross).z) >= 0.8 else { continue }
            let center = (first + second + third) / 3
            guard (-0.5...0.6).contains(center.z) else { continue }

            // Signed distance from the opening rectangle edge: > 0 outside, < 0 inside.
            let edgeDistance = max(abs(center.x) - halfWidth, abs(center.y) - halfHeight)
            if (0.15...0.50).contains(edgeDistance) {
                wallFace.append(center.z)
            } else if abs(edgeDistance) < 0.15, center.y < halfHeight - 0.15 {
                // Sides and sill only: the head often carries blinds or a roller box.
                frameFace.append(center.z)
            }
        }

        guard wallFace.count >= 20 else { return nil }
        wallFace.sort()
        let wallZ = wallFace[wallFace.count / 2]

        let candidates = frameFace.filter { $0 >= wallZ + 0.03 && $0 <= wallZ + 0.45 }.sorted()
        guard candidates.count >= 12 else { return nil }
        var clusters: [[Float]] = [[]]
        for value in candidates {
            if let previous = clusters.last?.last, value - previous > 0.018 {
                clusters.append([])
            }
            clusters[clusters.count - 1].append(value)
        }
        guard let frame = clusters.filter({ $0.count >= 12 }).max(by: { $0.count < $1.count }) else {
            return nil
        }
        let depth = Double(frame[frame.count / 2] - wallZ)
        guard (0.03...0.40).contains(depth) else { return nil }
        return depth
    }

    /// Samples only four small solid patches around the window corners. The
    /// glass-filled middle and long edge spans are intentionally ignored.
    private static func windowRevealSideSamples(
        surface: CapturedRoom.Surface,
        localFromWorld: simd_float4x4,
        mesh: ColoredSurfaceMesh,
        roomSide: Float?
    ) -> [[Double]]? {
        guard mesh.triangleIndices.count >= 3 else { return nil }
        let cornerBand: Float = 0.18
        // With a known room side, z is flipped so it measures distance from the room
        // face into the wall (reveal direction); the outdoor side is rejected by range.
        let sideSign = roomSide.map { -$0 } ?? 1
        let acceptedZ: ClosedRange<Float> = -0.10...0.34
        let halfWidth = surface.dimensions.x / 2
        let halfHeight = surface.dimensions.y / 2
        var sides = Array(repeating: [Double](), count: 4)

        func localPoint(at index: UInt32) -> SIMD3<Float>? {
            guard Int(index) < mesh.vertices.count else { return nil }
            let vertex = mesh.vertices[Int(index)]
            let local = localFromWorld * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
            return SIMD3(local.x, local.y, local.z * sideSign)
        }

        for triangleStart in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
            guard let first = localPoint(at: mesh.triangleIndices[triangleStart]),
                  let second = localPoint(at: mesh.triangleIndices[triangleStart + 1]),
                  let third = localPoint(at: mesh.triangleIndices[triangleStart + 2]) else {
                continue
            }
            let cross = simd_cross(second - first, third - first)
            guard simd_length_squared(cross) > 0.000_001 else { continue }
            let normal = simd_normalize(cross)
            let center = (first + second + third) / 3
            guard acceptedZ.contains(first.z),
                  acceptedZ.contains(second.z),
                  acceptedZ.contains(third.z),
                  acceptedZ.contains(center.z) else {
                continue
            }

            let nearXEdge = abs(abs(center.x) - halfWidth) <= cornerBand
            let nearYEdge = abs(abs(center.y) - halfHeight) <= cornerBand
            guard nearXEdge, nearYEdge else { continue }

            let isRevealFacing = (abs(normal.x) >= 0.70 || abs(normal.y) >= 0.70)
                && abs(normal.z) <= 0.4
            guard isRevealFacing else { continue }

            // 0: bottom-left, 1: bottom-right, 2: top-left, 3: top-right.
            let cornerIndex = (center.y >= 0 ? 2 : 0) + (center.x >= 0 ? 1 : 0)
            sides[cornerIndex].append(contentsOf: [
                Double(first.z), Double(second.z), Double(third.z)
            ])
        }
        return sides.contains(where: { !$0.isEmpty }) ? sides : nil
    }

    /// Estimates a window reveal from four corner patches and accepts the
    /// largest group that agrees within two centimetres.
    static func robustWindowRevealDepth(sideSamples: [[Double]]) -> Double? {
        var sideDepths: [Double] = []
        for samples in sideSamples where samples.count >= 12 {
            let sorted = samples.filter { $0.isFinite && (-0.10...0.34).contains($0) }.sorted()
            guard sorted.count >= 12 else { continue }
            var clusters: [[Double]] = [[]]
            for value in sorted {
                if let previous = clusters.last?.last, value - previous > 0.018 {
                    clusters.append([])
                }
                clusters[clusters.count - 1].append(value)
            }
            let candidates = clusters.compactMap { cluster -> (depth: Double, count: Int)? in
                guard cluster.count >= 12 else { return nil }
                let near = cluster[Int(Double(cluster.count - 1) * 0.05)]
                let far = cluster[Int(Double(cluster.count - 1) * 0.80)]
                let depth = far - near
                guard depth >= 0.02, depth <= 0.28 else { return nil }
                return (depth, cluster.count)
            }
            if let best = candidates.max(by: { first, second in
                if first.count == second.count {
                    return first.depth > second.depth
                }
                return first.count < second.count
            }) {
                sideDepths.append(best.depth)
            }
        }

        guard sideDepths.count >= 2 else { return nil }
        sideDepths.sort()
        let agreementTolerance = 0.02
        let consensusGroups = sideDepths.map { reference in
            sideDepths.filter { abs($0 - reference) <= agreementTolerance }
        }
        guard let agreed = consensusGroups
            .filter({ $0.count >= 2 })
            .sorted(by: { first, second in
                if first.count == second.count {
                    return first[first.count / 2] < second[second.count / 2]
                }
                return first.count > second.count
            })
            .first else {
            return nil
        }
        return agreed[agreed.count / 2]
    }

    /// The LiDAR mesh measures the separation between the front and inner
    /// surfaces, so it is the best reveal-depth source. RoomPlan's surface Z
    /// dimension is a bounding box and can include the frame or surrounding
    /// wall; use it only when the mesh has insufficient samples.
    static func resolvedOpeningDepth(
        surfaceDepth: Double,
        meshDepth: Double?,
        parentWallDepth: Double
    ) -> Double {
        let validRange = 0.02...0.6
        if let meshDepth, validRange.contains(meshDepth) {
            return meshDepth
        }
        if validRange.contains(surfaceDepth) {
            return surfaceDepth
        }
        if validRange.contains(parentWallDepth) {
            return parentWallDepth
        }
        return 0.12
    }

    static func resolvedWindowDepth(surfaceDepth: Double, meshDepth: Double?) -> Double? {
        let validWindowRange = 0.02...0.4
        if let meshDepth, validWindowRange.contains(meshDepth) {
            return meshDepth
        }
        if validWindowRange.contains(surfaceDepth) {
            return surfaceDepth
        }
        return nil
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
