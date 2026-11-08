import Foundation
import Testing
@testable import lidar

struct FloorSketchTests {
    /// A hand-drawn rectangle: 4 sides with slight wobble, ending near the start.
    private func wobblyRectangle() -> [PlanPoint] {
        var points: [PlanPoint] = []
        func line(_ a: PlanPoint, _ b: PlanPoint) {
            for step in 0..<20 {
                let t = Double(step) / 20
                let wobble = (step % 2 == 0 ? 2.0 : -2.0)
                points.append(PlanPoint(x: a.x + (b.x - a.x) * t + (a.y == b.y ? 0 : wobble),
                                        y: a.y + (b.y - a.y) * t + (a.y == b.y ? wobble : 0)))
            }
        }
        let corners = [PlanPoint(x: 0, y: 0), PlanPoint(x: 400, y: 0), PlanPoint(x: 400, y: 300), PlanPoint(x: 0, y: 300)]
        for i in corners.indices { line(corners[i], corners[(i + 1) % 4]) }
        points.append(PlanPoint(x: 5, y: 4))
        return points
    }

    @Test func strokeBecomesFourStraightWalls() throws {
        let sketch = try #require(FloorSketch.fromStroke(wobblyRectangle()))
        #expect(sketch.walls.count == 4)
        // Directions snap to right angles.
        for wall in sketch.walls {
            let degrees = wall.angle * 180 / .pi
            #expect(abs(degrees - (degrees / 90).rounded() * 90) < 0.001)
        }
    }

    @Test func measuredRectangleGivesExactArea() throws {
        var sketch = try #require(FloorSketch.fromStroke(wobblyRectangle()))
        let lengths = [5.0, 4.0, 5.0, 4.0]
        for i in sketch.walls.indices { sketch.walls[i].measuredLength = lengths[i] }
        sketch.roomHeight = 2.5
        let measurement = sketch.measurement()
        #expect(abs(measurement.floorArea - 20) < 0.001)
        #expect(abs(measurement.grossWallArea - 45) < 0.001)
        #expect(RoomMeasurement.closedLoop(of: measurement.walls) != nil)
    }

    @Test func unmeasuredWallClosesTheOutline() throws {
        var sketch = try #require(FloorSketch.fromStroke(wobblyRectangle()))
        sketch.walls[0].measuredLength = 6
        sketch.walls[1].measuredLength = 3
        sketch.walls[2].measuredLength = 6
        let walls = sketch.measurement().walls
        #expect(abs(walls[3].length - 3) < 0.001)
        #expect(abs(walls[0].length - 6) < 0.001)
    }

    @Test func tinyStrokeIsRejected() {
        #expect(FloorSketch.fromStroke([PlanPoint(x: 0, y: 0), PlanPoint(x: 3, y: 1), PlanPoint(x: 1, y: 2)]) == nil)
    }

    @Test func laserProtocolsDecodeMetres() {
        var leica = Data(count: 4)
        withUnsafeBytes(of: Float(2.345).bitPattern.littleEndian) { leica = Data($0) }
        #expect(abs((LaserMeterProtocol.leicaDistance(from: leica) ?? 0) - 2.345) < 0.0001)

        var bosch = Data([0xC0, 0x55, 0x10, 0x06, 0x00, 0x00, 0x00])
        withUnsafeBytes(of: Float(4.1).bitPattern.littleEndian) { bosch.append(contentsOf: $0) }
        #expect(abs((LaserMeterProtocol.boschDistance(from: bosch) ?? 0) - 4.1) < 0.0001)
        #expect(LaserMeterProtocol.boschDistance(from: Data([0x00, 0x01])) == nil)
    }
}
