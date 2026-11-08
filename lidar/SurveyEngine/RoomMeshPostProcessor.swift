import Foundation
import simd

/// Conservative, on-device cleanup for the measured ARKit mesh.
///
/// The processor only modifies geometry close to RoomPlan's structural
/// surfaces and fills small closed boundary loops. It deliberately avoids
/// inventing large hidden surfaces behind furniture or across doorways.
enum RoomMeshPostProcessor {
    struct Result {
        let coloredSurface: ColoredSurfaceMesh
        let texturedSurface: TexturedSurfaceMesh
        let filledHoleCount: Int
    }

    private static let wallSnapDistance: Float = 0.055
    private static let horizontalSnapDistance: Float = 0.035
    private static let maximumHoleRadius: Float = 0.20
    private static let maximumHoleVertices = 96

    static func process(
        coloredSurface: ColoredSurfaceMesh,
        texturedSurface: TexturedSurfaceMesh,
        measurement: RoomMeasurement
    ) -> Result {
        let snappedColoredVertices = snap(
            coloredSurface.vertices,
            to: measurement
        )
        let cleanedIndices = removeDegenerateTriangles(
            coloredSurface.triangleIndices,
            vertices: snappedColoredVertices
        )
        let filled = fillSmallHoles(
            vertices: snappedColoredVertices,
            triangleIndices: cleanedIndices
        )

        let processedChunks: [TexturedSurfaceChunk] = texturedSurface.chunks.compactMap { chunk -> TexturedSurfaceChunk? in
            let vertices = snap(chunk.vertices, to: measurement)
            let indices = removeDegenerateTriangles(
                chunk.triangleIndices,
                vertices: vertices
            )
            guard !indices.isEmpty else { return nil }
            return TexturedSurfaceChunk(
                vertices: vertices,
                textureCoordinates: chunk.textureCoordinates,
                triangleIndices: indices,
                jpegData: chunk.jpegData
            )
        }

        return Result(
            coloredSurface: ColoredSurfaceMesh(
                vertices: filled.vertices,
                triangleIndices: filled.indices
            ),
            texturedSurface: TexturedSurfaceMesh(chunks: processedChunks),
            filledHoleCount: filled.holeCount
        )
    }

    private static func snap(
        _ vertices: [PhotoPoint],
        to measurement: RoomMeasurement
    ) -> [PhotoPoint] {
        guard !vertices.isEmpty else { return vertices }

        let yValues = vertices.map(\.y).sorted()
        let floorY = percentile(yValues, fraction: 0.02)
        let ceilingY = percentile(yValues, fraction: 0.98)

        return vertices.map { vertex in
            var position = SIMD3<Float>(vertex.x, vertex.y, vertex.z)

            if abs(position.y - floorY) <= horizontalSnapDistance {
                position.y = floorY
            } else if abs(position.y - ceilingY) <= horizontalSnapDistance {
                position.y = ceilingY
            }

            var nearestWallPoint: SIMD2<Float>?
            var nearestWallDistance = Float.greatestFiniteMagnitude
            let point = SIMD2<Float>(position.x, position.z)

            for wall in measurement.walls {
                let start = SIMD2<Float>(Float(wall.start.x), Float(wall.start.y))
                let end = SIMD2<Float>(Float(wall.end.x), Float(wall.end.y))
                let segment = end - start
                let squaredLength = simd_length_squared(segment)
                guard squaredLength > .ulpOfOne else { continue }

                let parameter = simd_clamp(
                    simd_dot(point - start, segment) / squaredLength,
                    0,
                    1
                )
                let candidate = start + segment * parameter
                let distance = simd_distance(point, candidate)
                let isWithinWallHeight = position.y >= floorY - 0.08
                    && position.y <= floorY + Float(wall.height) + 0.08
                if isWithinWallHeight, distance < nearestWallDistance {
                    nearestWallDistance = distance
                    nearestWallPoint = candidate
                }
            }

            if nearestWallDistance <= wallSnapDistance,
               let nearestWallPoint {
                position.x = nearestWallPoint.x
                position.z = nearestWallPoint.y
            }

            return PhotoPoint(
                x: position.x,
                y: position.y,
                z: position.z,
                red: vertex.red,
                green: vertex.green,
                blue: vertex.blue
            )
        }
    }

    private static func percentile(_ values: [Float], fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let index = min(
            values.count - 1,
            max(0, Int((Double(values.count - 1) * fraction).rounded()))
        )
        return values[index]
    }

    private static func removeDegenerateTriangles(
        _ indices: [UInt32],
        vertices: [PhotoPoint]
    ) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(indices.count)

        for start in stride(from: 0, to: max(0, indices.count - 2), by: 3) {
            let first = Int(indices[start])
            let second = Int(indices[start + 1])
            let third = Int(indices[start + 2])
            guard first < vertices.count,
                  second < vertices.count,
                  third < vertices.count,
                  first != second,
                  second != third,
                  first != third else {
                continue
            }

            let a = position(vertices[first])
            let b = position(vertices[second])
            let c = position(vertices[third])
            let doubleArea = simd_length(simd_cross(b - a, c - a))
            guard doubleArea.isFinite, doubleArea > 0.000_01 else {
                continue
            }
            result.append(contentsOf: [indices[start], indices[start + 1], indices[start + 2]])
        }
        return result
    }

    private static func fillSmallHoles(
        vertices sourceVertices: [PhotoPoint],
        triangleIndices: [UInt32]
    ) -> (vertices: [PhotoPoint], indices: [UInt32], holeCount: Int) {
        struct Edge: Hashable {
            let low: UInt32
            let high: UInt32

            init(_ first: UInt32, _ second: UInt32) {
                low = min(first, second)
                high = max(first, second)
            }
        }

        var edgeCounts: [Edge: Int] = [:]
        for start in stride(from: 0, to: max(0, triangleIndices.count - 2), by: 3) {
            let a = triangleIndices[start]
            let b = triangleIndices[start + 1]
            let c = triangleIndices[start + 2]
            edgeCounts[Edge(a, b), default: 0] += 1
            edgeCounts[Edge(b, c), default: 0] += 1
            edgeCounts[Edge(c, a), default: 0] += 1
        }

        let boundaryEdges = edgeCounts.keys.filter { edgeCounts[$0] == 1 }
        var adjacency: [UInt32: [UInt32]] = [:]
        for edge in boundaryEdges {
            adjacency[edge.low, default: []].append(edge.high)
            adjacency[edge.high, default: []].append(edge.low)
        }

        var unvisited = Set(boundaryEdges)
        var vertices = sourceVertices
        var indices = triangleIndices
        var holeCount = 0

        while let seed = unvisited.first {
            var loop: [UInt32] = [seed.low, seed.high]
            unvisited.remove(seed)
            var previous = seed.low
            var current = seed.high

            while loop.count <= maximumHoleVertices {
                guard let neighbors = adjacency[current],
                      let next = neighbors.first(where: {
                          $0 != previous && unvisited.contains(Edge(current, $0))
                      }) else {
                    break
                }
                unvisited.remove(Edge(current, next))
                if next == loop[0] {
                    break
                }
                loop.append(next)
                previous = current
                current = next
            }

            guard loop.count >= 3,
                  loop.count <= maximumHoleVertices,
                  current == loop.last,
                  adjacency[current]?.contains(loop[0]) == true else {
                continue
            }

            let positions = loop.compactMap { index -> SIMD3<Float>? in
                guard Int(index) < vertices.count else { return nil }
                return position(vertices[Int(index)])
            }
            guard positions.count == loop.count else { continue }
            let center = positions.reduce(.zero, +) / Float(positions.count)
            let radius = positions.map { simd_distance($0, center) }.max() ?? .infinity
            guard radius <= maximumHoleRadius else { continue }

            let colors = loop.map { vertices[Int($0)] }
            let count = max(colors.count, 1)
            let centerVertex = PhotoPoint(
                x: center.x,
                y: center.y,
                z: center.z,
                red: UInt8(colors.reduce(0) { $0 + Int($1.red) } / count),
                green: UInt8(colors.reduce(0) { $0 + Int($1.green) } / count),
                blue: UInt8(colors.reduce(0) { $0 + Int($1.blue) } / count)
            )
            let centerIndex = UInt32(vertices.count)
            vertices.append(centerVertex)
            for index in loop.indices {
                indices.append(contentsOf: [
                    loop[index],
                    loop[(index + 1) % loop.count],
                    centerIndex
                ])
            }
            holeCount += 1
        }

        return (vertices, indices, holeCount)
    }

    private static func position(_ vertex: PhotoPoint) -> SIMD3<Float> {
        SIMD3<Float>(vertex.x, vertex.y, vertex.z)
    }
}
