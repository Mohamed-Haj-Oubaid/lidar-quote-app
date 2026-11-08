import Foundation
import Testing
@testable import lidar

/// H4 – plan edits keep walls connected and the floor consistent. M6 – measurement basics.
struct RoomGeometryTests {
    @Test func openingDepthPrefersTheOpeningOverTheParentWall() {
        let depth = SurveyEngine.resolvedOpeningDepth(
            surfaceDepth: 0.18,
            meshDepth: nil,
            parentWallDepth: 0.33
        )

        #expect(depth == 0.18)
    }

    @Test func openingDepthFallsBackToMeshThenWall() {
        #expect(SurveyEngine.resolvedOpeningDepth(
            surfaceDepth: 0,
            meshDepth: 0.16,
            parentWallDepth: 0.33
        ) == 0.16)
        #expect(SurveyEngine.resolvedOpeningDepth(
            surfaceDepth: 0,
            meshDepth: nil,
            parentWallDepth: 0.24
        ) == 0.24)
    }

    @Test func openingDepthPrefersMeasuredMeshOverRoomPlanBoundingBox() {
        let depth = SurveyEngine.resolvedOpeningDepth(
            surfaceDepth: 0.34,
            meshDepth: 0.23,
            parentWallDepth: 0.34
        )

        #expect(depth == 0.23)
    }

    @Test func windowDepthRejectsSideThatSeesThroughGlass() {
        let left = stride(from: -0.12, through: 0.12, by: 0.01).map { $0 }
        let right = stride(from: -0.12, through: 0.12, by: 0.01).map { $0 }
        let top = stride(from: -0.12, through: 0.12, by: 0.01).map { $0 }
        let contaminatedBottom = stride(from: -0.17, through: 0.17, by: 0.01).map { $0 }

        let depth = SurveyEngine.robustWindowRevealDepth(
            sideSamples: [left, right, top, contaminatedBottom]
        )

        #expect(depth != nil)
        #expect(abs((depth ?? 0) - 0.16) < 0.025)
    }

    @Test func windowDepthNeverAcceptsOutdoorBackground() {
        #expect(SurveyEngine.resolvedWindowDepth(surfaceDepth: 0.51, meshDepth: 0.51) == nil)
        #expect(SurveyEngine.resolvedWindowDepth(surfaceDepth: 0.51, meshDepth: 0.24) == 0.24)
    }
    private func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

    @Test func rectangleFactory() {
        let room = RoomMeasurement.rectangle(width: 4, depth: 3, height: 2.5)
        #expect(room.walls.count == 4)
        #expect(approx(room.floorArea, 12))
        #expect(approx(room.perimeter, 14))
        #expect(approx(room.grossWallArea, 35))
        #expect(RoomMeasurement.closedLoop(of: room.walls) != nil)
    }

    @Test func shoelaceAreaOfLShapeAndOverride() {
        var room = RoomMeasurement.empty
        room.floorPolygon = [PlanPoint(x: 0, y: 0), PlanPoint(x: 4, y: 0), PlanPoint(x: 4, y: 2),
                             PlanPoint(x: 2, y: 2), PlanPoint(x: 2, y: 4), PlanPoint(x: 0, y: 4)]
        #expect(approx(room.floorArea, 12))
        room.floorAreaOverride = 11.5
        #expect(approx(room.floorArea, 11.5))
        room.floorPolygon = Array(room.floorPolygon.prefix(2))
        room.floorAreaOverride = nil
        #expect(room.floorArea == 0)
    }

    @Test func changingOneWallOfARectangleKeepsItRectangular() throws {
        let room = RoomMeasurement.rectangle(width: 4, depth: 3, height: 2.5)
        let edit = room.settingLength(5, ofWall: room.walls[0].id)
        let result = edit.measurement

        #expect(edit.floorRecalculated)
        #expect(approx(result.floorArea, 15))
        #expect(approx(result.perimeter, 16))
        #expect(RoomMeasurement.closedLoop(of: result.walls) != nil)
        #expect(result.walls.map(\.length).map { ($0 * 1000).rounded() / 1000 } == [5, 3, 5, 3])
        #expect(result.manuallyAdjusted)
    }

    @Test func openPlanFallsBackToManualFloorArea() {
        var room = RoomMeasurement.rectangle(width: 4, depth: 3, height: 2.5)
        room.walls.removeLast()                       // three walls – no closed loop
        let edit = room.settingLength(5, ofWall: room.walls[0].id)
        #expect(!edit.floorRecalculated)
        #expect(edit.measurement.floorAreaOverride == 12)
    }

    @Test func triangleMovesOnlyTheSharedCorner() {
        let a = PlanPoint(x: 0, y: 0), b = PlanPoint(x: 3, y: 0), c = PlanPoint(x: 0, y: 4)
        let room = RoomMeasurement(walls: [WallSegment(id: UUID(), start: a, end: b, height: 2.5),
                                           WallSegment(id: UUID(), start: b, end: c, height: 2.5),
                                           WallSegment(id: UUID(), start: c, end: a, height: 2.5)],
                                   openings: [], floorPolygon: [a, b, c], floorAreaOverride: nil,
                                   source: .manual, manuallyAdjusted: false)
        let result = room.settingLength(6, ofWall: room.walls[0].id).measurement
        #expect(RoomMeasurement.closedLoop(of: result.walls) != nil)
        #expect(approx(result.floorArea, 12))           // ½ · 6 · 4
    }

    @Test func widthAndDepthRegenerateTheRectangle() throws {
        var room = RoomMeasurement.rectangle(width: 4, depth: 3, height: 2.5)
        room.openings = [RoomOpening(id: UUID(), kind: .door, width: 0.9, height: 2, wallID: room.walls[0].id, centerOffset: 1)]
        let ids = room.walls.map(\.id)
        let resized = room.resizedRectangle(width: 5, depth: 2)
        let size = try #require(resized.rectangleSize)
        #expect(approx(size.width, 5) && approx(size.depth, 2))
        #expect(approx(resized.floorArea, 10))
        #expect(resized.walls.map(\.id) == ids)
        #expect(resized.openings.first?.wallID == ids[0])
    }
}
