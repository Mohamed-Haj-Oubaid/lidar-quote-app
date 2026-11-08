import ARKit
import CoreImage
import Foundation
import RoomPlan
import UIKit

enum ScanCaptureMode: String, CaseIterable, Identifiable {
    case room, detail
    var id: String { rawValue }
    var title: String { switch self { case .room: String(localized: "Room LiDAR"); case .detail: String(localized: "High Detail") } }
    var subtitle: String { switch self {
        case .room: String(localized: "Fast architectural scan for walls, doors, windows, and measurements.")
        case .detail: String(localized: "Denser capture for objects, corners, furniture, and small surfaces.")
    } }
    var systemImage: String { switch self { case .room: "square.split.2x2"; case .detail: "viewfinder" } }
    var sampleInterval: TimeInterval { switch self { case .room: 0.65; case .detail: 0.32 } }
    var pixelStride: Int { switch self { case .room: 6; case .detail: 3 } }
    var maximumPointCount: Int { switch self { case .room: 180_000; case .detail: 350_000 } }
    var maximumTextureFrames: Int { switch self { case .room: 4; case .detail: 5 } }
    var minimumTextureCoverage: Float { switch self { case .room: 0.18; case .detail: 0.12 } }
    var jpegCompressionQuality: CGFloat { switch self { case .room: 0.82; case .detail: 0.9 } }
}

nonisolated struct PhotoPoint: Codable, Hashable {
    let x: Float
    let y: Float
    let z: Float
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

/// A camera-colored triangle surface reconstructed from consecutive LiDAR depth frames.
nonisolated struct ColoredSurfaceMesh: Codable {
    let vertices: [PhotoPoint]
    let triangleIndices: [UInt32]

    static let empty = ColoredSurfaceMesh(vertices: [], triangleIndices: [])
}

nonisolated struct TextureCoordinate: Codable {
    let u: Float
    let v: Float
}

nonisolated struct TexturedSurfaceChunk: Codable {
    let vertices: [PhotoPoint]
    let textureCoordinates: [TextureCoordinate]
    let triangleIndices: [UInt32]
    let jpegData: Data
}

nonisolated struct TexturedSurfaceMesh: Codable {
    let chunks: [TexturedSurfaceChunk]

    static let empty = TexturedSurfaceMesh(chunks: [])
}

nonisolated struct RealityMeshArchive: Codable {
    let coloredSurface: ColoredSurfaceMesh
    let texturedSurface: TexturedSurfaceMesh
}

nonisolated struct RoomCaptureOutput {
    let room: CapturedRoom
    let photoPoints: [PhotoPoint]
    let coloredSurface: ColoredSurfaceMesh
    let texturedSurface: TexturedSurfaceMesh
}

struct LiveScanFrame {
    let points: [LiveScanPoint]
    let triangleIndices: [UInt32]
    let camera: ARCamera
}

struct LiveScanPoint {
    let position: SIMD3<Float>
    let quality: Float
}

/// Samples aligned LiDAR depth and camera color from RoomPlan's AR session.
/// Neighboring depth samples become triangles, producing a solid camera-colored surface.
@MainActor
final class PhotoPointCloudRecorder: NSObject {
    private struct TextureFrame {
        let jpegData: Data
        let cameraFromWorld: simd_float4x4
        let intrinsics: simd_float3x3
        let imageWidth: Int
        let imageHeight: Int
        let score: Float
    }

    private weak var session: ARSession?
    private var timer: Timer?
    private(set) var points: [PhotoPoint] = []
    private(set) var triangleIndices: [UInt32] = []
    private var anchorSurfaces: [UUID: ColoredSurfaceMesh] = [:]
    private var anchorColorScores: [UUID: [Float]] = [:]
    private var anchorTextureFrames: [UUID: [TextureFrame]] = [:]
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var scanStartedAt = Date()
    private var visitedViewSectors: Set<Int> = []
    private var highestCoverage: Double = 0

    var onCoverageChange: ((Double) -> Void)?
    var onLiveScanChange: ((LiveScanFrame) -> Void)?

    private var captureMode = ScanCaptureMode.room

    var coloredSurface: ColoredSurfaceMesh {
        guard !anchorSurfaces.isEmpty else {
            return ColoredSurfaceMesh(vertices: points, triangleIndices: triangleIndices)
        }

        var combinedVertices: [PhotoPoint] = []
        var combinedIndices: [UInt32] = []
        for surface in anchorSurfaces.values {
            let offset = UInt32(combinedVertices.count)
            combinedVertices.append(contentsOf: surface.vertices)
            combinedIndices.append(contentsOf: surface.triangleIndices.map { $0 + offset })
        }
        return ColoredSurfaceMesh(vertices: combinedVertices, triangleIndices: combinedIndices)
    }



    var texturedSurface: TexturedSurfaceMesh {
        var chunks: [TexturedSurfaceChunk] = []

        for (identifier, surface) in anchorSurfaces {
            guard let frames = anchorTextureFrames[identifier], !frames.isEmpty else { continue }
            var remainingTriangles = Set(stride(
                from: 0,
                to: max(0, surface.triangleIndices.count - 2),
                by: 3
            ))

            for frame in frames.sorted(by: { $0.score > $1.score }) {
                var validCoordinates = Array(repeating: false, count: surface.vertices.count)
                let coordinates = surface.vertices.enumerated().map { index, vertex in
                let world = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
                let cameraPoint = frame.cameraFromWorld * world
                let depth = -cameraPoint.z
                guard depth > 0 else {
                    return TextureCoordinate(u: 0, v: 0)
                }

                let pixelX = frame.intrinsics.columns.0.x * cameraPoint.x / depth
                    + frame.intrinsics.columns.2.x
                let pixelY = frame.intrinsics.columns.2.y
                    - frame.intrinsics.columns.1.y * cameraPoint.y / depth
                guard pixelX >= 0, pixelY >= 0,
                      pixelX < Float(frame.imageWidth),
                      pixelY < Float(frame.imageHeight) else {
                    return TextureCoordinate(u: 0, v: 0)
                }

                validCoordinates[index] = true
                return TextureCoordinate(
                    u: pixelX / Float(frame.imageWidth),
                    v: 1 - pixelY / Float(frame.imageHeight)
                )
                }

                var texturedIndices: [UInt32] = []
                var assignedTriangles: [Int] = []
                for start in remainingTriangles.sorted() {
                let first = Int(surface.triangleIndices[start])
                let second = Int(surface.triangleIndices[start + 1])
                let third = Int(surface.triangleIndices[start + 2])
                guard first < validCoordinates.count,
                      second < validCoordinates.count,
                      third < validCoordinates.count,
                      validCoordinates[first],
                      validCoordinates[second],
                      validCoordinates[third] else {
                        continue
                    }
                    texturedIndices.append(contentsOf: [
                        surface.triangleIndices[start],
                        surface.triangleIndices[start + 1],
                        surface.triangleIndices[start + 2]
                    ])
                    assignedTriangles.append(start)
                }

                guard !texturedIndices.isEmpty else { continue }
                assignedTriangles.forEach { remainingTriangles.remove($0) }
                chunks.append(TexturedSurfaceChunk(
                    vertices: surface.vertices,
                    textureCoordinates: coordinates,
                    triangleIndices: texturedIndices,
                    jpegData: frame.jpegData
                ))
                if remainingTriangles.isEmpty { break }
            }
        }

        return TexturedSurfaceMesh(chunks: chunks)
    }

    func start(session: ARSession, mode: ScanCaptureMode) {
        self.session = session
        captureMode = mode
        points.removeAll(keepingCapacity: true)
        triangleIndices.removeAll(keepingCapacity: true)
        anchorSurfaces.removeAll(keepingCapacity: true)
        anchorColorScores.removeAll(keepingCapacity: true)
        anchorTextureFrames.removeAll(keepingCapacity: true)
        scanStartedAt = .now
        visitedViewSectors.removeAll(keepingCapacity: true)
        highestCoverage = 0
        onCoverageChange?(0)
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: captureMode.sampleInterval,
            target: self,
            selector: #selector(sampleTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sampleCurrentFrame()
        session = nil
    }

    @objc private func sampleTimerFired() {
        sampleCurrentFrame()
    }

    private func sampleCurrentFrame() {
        guard let frame = session?.currentFrame else { return }
        if captureSceneMesh(from: frame) {
            return
        }
        guard points.count < captureMode.maximumPointCount,
              let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return
        }

        let depthMap = depthData.depthMap
        guard let confidenceMap = depthData.confidenceMap else { return }
        let image = frame.capturedImage

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap),
              let luminanceBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else {
            return
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)

        let imageWidth = CVPixelBufferGetWidthOfPlane(image, 0)
        let imageHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let luminanceRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(image, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(image, 1)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1)

        let imageResolution = frame.camera.imageResolution
        let scaleX = Float(depthWidth) / Float(imageResolution.width)
        let scaleY = Float(depthHeight) / Float(imageResolution.height)
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x * scaleX
        let fy = intrinsics.columns.1.y * scaleY
        let cx = intrinsics.columns.2.x * scaleX
        let cy = intrinsics.columns.2.y * scaleY
        let cameraTransform = frame.camera.transform

        let columns = Array(Swift.stride(from: 0, to: depthWidth, by: captureMode.pixelStride))
        let rows = Array(Swift.stride(from: 0, to: depthHeight, by: captureMode.pixelStride))
        var vertexGrid = Array<UInt32?>(repeating: nil, count: columns.count * rows.count)
        var depthGrid = Array<Float>(repeating: .nan, count: columns.count * rows.count)

        for (rowIndex, y) in rows.enumerated() {
            let depthRow = depthBase.advanced(by: y * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase.advanced(by: y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)

            for (columnIndex, x) in columns.enumerated() {
                guard points.count < captureMode.maximumPointCount else { break }
                let depth = depthRow[x]
                guard depth.isFinite, depth >= 0.15, depth <= 8, confidenceRow[x] >= 1 else {
                    continue
                }

                let cameraPoint = SIMD4<Float>(
                    (Float(x) - cx) * depth / fx,
                    -(Float(y) - cy) * depth / fy,
                    -depth,
                    1
                )
                let world = cameraTransform * cameraPoint
                let imageX = min(imageWidth - 1, max(0, x * imageWidth / max(depthWidth, 1)))
                let imageY = min(imageHeight - 1, max(0, y * imageHeight / max(depthHeight, 1)))
                let yValue = luminanceBase
                    .advanced(by: imageY * luminanceRowBytes)
                    .assumingMemoryBound(to: UInt8.self)[imageX]

                let chromaX = min(chromaWidth - 1, imageX * chromaWidth / max(imageWidth, 1))
                let chromaY = min(chromaHeight - 1, imageY * chromaHeight / max(imageHeight, 1))
                let chromaPixel = chromaBase
                    .advanced(by: chromaY * chromaRowBytes)
                    .assumingMemoryBound(to: UInt8.self)
                    .advanced(by: chromaX * 2)
                let color = Self.rgb(y: yValue, cb: chromaPixel[0], cr: chromaPixel[1])

                let gridIndex = rowIndex * columns.count + columnIndex
                vertexGrid[gridIndex] = UInt32(points.count)
                depthGrid[gridIndex] = depth
                points.append(PhotoPoint(
                    x: world.x,
                    y: world.y,
                    z: world.z,
                    red: color.0,
                    green: color.1,
                    blue: color.2
                ))
            }
        }

        guard rows.count > 1, columns.count > 1 else { return }
        for row in 0..<(rows.count - 1) {
            for column in 0..<(columns.count - 1) {
                let topLeft = row * columns.count + column
                let topRight = topLeft + 1
                let bottomLeft = topLeft + columns.count
                let bottomRight = bottomLeft + 1

                appendTriangle(
                    vertexGrid[topLeft], vertexGrid[bottomLeft], vertexGrid[topRight],
                    depths: (depthGrid[topLeft], depthGrid[bottomLeft], depthGrid[topRight])
                )
                appendTriangle(
                    vertexGrid[topRight], vertexGrid[bottomLeft], vertexGrid[bottomRight],
                    depths: (depthGrid[topRight], depthGrid[bottomLeft], depthGrid[bottomRight])
                )
            }
        }
    }

    private func captureSceneMesh(from frame: ARFrame) -> Bool {
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return false }

        let image = frame.capturedImage
        let depthMap = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap
        CVPixelBufferLockBaseAddress(image, .readOnly)
        if let depthMap {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        }
        defer {
            if let depthMap {
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }

        guard let luminanceBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else {
            return false
        }

        let imageWidth = CVPixelBufferGetWidthOfPlane(image, 0)
        let imageHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let luminanceRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(image, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(image, 1)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let depthBase = depthMap.flatMap(CVPixelBufferGetBaseAddress)
        let depthWidth = depthMap.map(CVPixelBufferGetWidth) ?? 0
        let depthHeight = depthMap.map(CVPixelBufferGetHeight) ?? 0
        let depthRowBytes = depthMap.map(CVPixelBufferGetBytesPerRow) ?? 0
        let cameraFromWorld = frame.camera.transform.inverse
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        var encodedJPEG: Data?

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let previousSurface = anchorSurfaces[anchor.identifier]
            let previousScores = anchorColorScores[anchor.identifier] ?? []
            var scores = Array<Float>(repeating: 0, count: geometry.vertices.count)
            var visibleVertexCount = 0
            var visibleScoreTotal: Float = 0
            var vertices: [PhotoPoint] = []
            vertices.reserveCapacity(geometry.vertices.count)

            for vertexIndex in 0..<geometry.vertices.count {
                let local = geometry.vertices.buffer.contents()
                    .advanced(by: geometry.vertices.offset + vertexIndex * geometry.vertices.stride)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                    .pointee
                let world = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let cameraPoint = cameraFromWorld * world
                let cameraDepth = -cameraPoint.z
                let pixelX = fx * cameraPoint.x / cameraDepth + cx
                let pixelY = cy - fy * cameraPoint.y / cameraDepth

                let projectsIntoImage = cameraDepth > 0
                    && pixelX.isFinite && pixelY.isFinite
                    && pixelX >= 0 && pixelY >= 0
                    && pixelX < Float(imageWidth) && pixelY < Float(imageHeight)
                let imageX = projectsIntoImage
                    ? min(imageWidth - 1, max(0, Int(pixelX.rounded())))
                    : 0
                let imageY = projectsIntoImage
                    ? min(imageHeight - 1, max(0, Int(pixelY.rounded())))
                    : 0
                var canSampleColor = projectsIntoImage

                if canSampleColor, let depthBase, depthWidth > 0, depthHeight > 0 {
                    let depthX = min(depthWidth - 1, imageX * depthWidth / max(imageWidth, 1))
                    let depthY = min(depthHeight - 1, imageY * depthHeight / max(imageHeight, 1))
                    let depthRow = depthBase
                        .advanced(by: depthY * depthRowBytes)
                        .assumingMemoryBound(to: Float32.self)
                    let sensorDepth = depthRow[depthX]
                    let tolerance = max(0.10, sensorDepth * 0.04)
                    canSampleColor = sensorDepth.isFinite && abs(sensorDepth - cameraDepth) <= tolerance
                }

                var observationScore: Float = 0
                if canSampleColor, vertexIndex < geometry.normals.count {
                    let localNormal = geometry.normals.buffer.contents()
                        .advanced(by: geometry.normals.offset + vertexIndex * geometry.normals.stride)
                        .assumingMemoryBound(to: SIMD3<Float>.self)
                        .pointee
                    let transformedNormal = anchor.transform * SIMD4<Float>(
                        localNormal.x,
                        localNormal.y,
                        localNormal.z,
                        0
                    )
                    let worldNormal = simd_normalize(SIMD3<Float>(
                        transformedNormal.x,
                        transformedNormal.y,
                        transformedNormal.z
                    ))
                    let worldPosition = SIMD3<Float>(world.x, world.y, world.z)
                    let viewDirection = simd_normalize(cameraPosition - worldPosition)
                    let facing = abs(simd_dot(worldNormal, viewDirection))
                    observationScore = facing * facing / max(cameraDepth, 0.4)
                    canSampleColor = facing >= 0.25
                    if canSampleColor {
                        visibleVertexCount += 1
                        visibleScoreTotal += observationScore
                    }
                }

                let color: (UInt8, UInt8, UInt8)
                if canSampleColor {
                    let yValue = luminanceBase
                        .advanced(by: imageY * luminanceRowBytes)
                        .assumingMemoryBound(to: UInt8.self)[imageX]
                    let chromaX = min(chromaWidth - 1, imageX * chromaWidth / max(imageWidth, 1))
                    let chromaY = min(chromaHeight - 1, imageY * chromaHeight / max(imageHeight, 1))
                    let chromaPixel = chromaBase
                        .advanced(by: chromaY * chromaRowBytes)
                        .assumingMemoryBound(to: UInt8.self)
                        .advanced(by: chromaX * 2)
                    let sampled = Self.rgb(y: yValue, cb: chromaPixel[0], cr: chromaPixel[1])
                    let previousScore = vertexIndex < previousScores.count ? previousScores[vertexIndex] : 0
                    if observationScore >= previousScore {
                        color = sampled
                        scores[vertexIndex] = observationScore
                    } else if let previousSurface, vertexIndex < previousSurface.vertices.count {
                        let previous = previousSurface.vertices[vertexIndex]
                        color = (previous.red, previous.green, previous.blue)
                        scores[vertexIndex] = previousScore
                    } else {
                        color = sampled
                        scores[vertexIndex] = observationScore
                    }
                } else if let previousSurface,
                          vertexIndex < previousSurface.vertices.count {
                    let vertex = previousSurface.vertices[vertexIndex]
                    color = (vertex.red, vertex.green, vertex.blue)
                    if vertexIndex < previousScores.count {
                        scores[vertexIndex] = previousScores[vertexIndex]
                    }
                } else {
                    color = (145, 145, 145)
                }

                vertices.append(PhotoPoint(
                    x: world.x,
                    y: world.y,
                    z: world.z,
                    red: color.0,
                    green: color.1,
                    blue: color.2
                ))
            }

            let faces = geometry.faces
            var indices: [UInt32] = []
            indices.reserveCapacity(faces.count * faces.indexCountPerPrimitive)
            let indexCount = faces.count * faces.indexCountPerPrimitive
            for index in 0..<indexCount {
                let address = faces.buffer.contents().advanced(by: index * faces.bytesPerIndex)
                if faces.bytesPerIndex == MemoryLayout<UInt32>.size {
                    indices.append(address.assumingMemoryBound(to: UInt32.self).pointee)
                } else {
                    indices.append(UInt32(address.assumingMemoryBound(to: UInt16.self).pointee))
                }
            }

            anchorSurfaces[anchor.identifier] = ColoredSurfaceMesh(
                vertices: vertices,
                triangleIndices: indices
            )
            anchorColorScores[anchor.identifier] = scores

            let coverage = Float(visibleVertexCount) / Float(max(geometry.vertices.count, 1))
            let frameScore = visibleScoreTotal / Float(max(geometry.vertices.count, 1))
            if coverage >= captureMode.minimumTextureCoverage {
                if encodedJPEG == nil {
                    encodedJPEG = cameraJPEGData(from: image)
                }
                if let encodedJPEG {
                    let candidate = TextureFrame(
                        jpegData: encodedJPEG,
                        cameraFromWorld: cameraFromWorld,
                        intrinsics: intrinsics,
                        imageWidth: imageWidth,
                        imageHeight: imageHeight,
                        score: frameScore
                    )
                    retainUsefulTextureFrame(candidate, for: anchor.identifier)
                }
            }
        }
        updateCoverage(using: frame)
        publishLiveScan(using: frame.camera)
        return true
    }

    private func publishLiveScan(using camera: ARCamera) {
        var points: [LiveScanPoint] = []
        var triangleIndices: [UInt32] = []
        for (identifier, surface) in anchorSurfaces {
            let scores = anchorColorScores[identifier] ?? []
            let offset = UInt32(points.count)
            points.append(contentsOf: surface.vertices.enumerated().map { index, vertex in
                let score = index < scores.count ? scores[index] : 0
                return LiveScanPoint(
                    position: SIMD3<Float>(vertex.x, vertex.y, vertex.z),
                    quality: min(max(score / 0.9, 0), 1)
                )
            })
            triangleIndices.append(contentsOf: surface.triangleIndices.map { $0 + offset })
        }
        onLiveScanChange?(LiveScanFrame(
            points: points,
            triangleIndices: triangleIndices,
            camera: camera
        ))
    }

    private func updateCoverage(using frame: ARFrame) {
        let cameraForward = -SIMD3<Float>(
            frame.camera.transform.columns.2.x,
            frame.camera.transform.columns.2.y,
            frame.camera.transform.columns.2.z
        )
        let angle = atan2(cameraForward.x, cameraForward.z) + .pi
        let sector = min(11, max(0, Int(angle / (2 * .pi) * 12)))
        visitedViewSectors.insert(sector)

        let scores = anchorColorScores.values.flatMap { $0 }
        let coloredRatio = scores.isEmpty
            ? 0
            : Double(scores.lazy.filter { $0 > 0 }.count) / Double(scores.count)
        let viewpointRatio = Double(visitedViewSectors.count) / 12
        let elapsedRatio = min(Date().timeIntervalSince(scanStartedAt) / 45, 1)
        let triangleCount = anchorSurfaces.values.reduce(0) {
            $0 + $1.triangleIndices.count / 3
        }
        let meshRatio = min(Double(triangleCount) / 6_000, 1)
        let measuredCoverage = 0.35 * coloredRatio
            + 0.25 * viewpointRatio
            + 0.20 * elapsedRatio
            + 0.20 * meshRatio
        highestCoverage = max(highestCoverage, min(measuredCoverage, 1))
        onCoverageChange?(highestCoverage)
    }

    private func retainUsefulTextureFrame(_ candidate: TextureFrame, for identifier: UUID) {
        var frames = anchorTextureFrames[identifier] ?? []
        let candidateTransform = candidate.cameraFromWorld.inverse
        let candidatePosition = SIMD3<Float>(
            candidateTransform.columns.3.x,
            candidateTransform.columns.3.y,
            candidateTransform.columns.3.z
        )

        if let similarIndex = frames.firstIndex(where: { frame in
            let transform = frame.cameraFromWorld.inverse
            let position = SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
            return simd_distance(position, candidatePosition) < 0.22
        }) {
            if candidate.score > frames[similarIndex].score {
                frames[similarIndex] = candidate
            }
        } else {
            frames.append(candidate)
        }

        frames.sort { $0.score > $1.score }
        anchorTextureFrames[identifier] = Array(frames.prefix(captureMode.maximumTextureFrames))
    }

    private func cameraJPEGData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: captureMode.jpegCompressionQuality)
    }

    private func appendTriangle(
        _ first: UInt32?,
        _ second: UInt32?,
        _ third: UInt32?,
        depths: (Float, Float, Float)
    ) {
        guard let first, let second, let third else { return }
        let minimum = min(depths.0, depths.1, depths.2)
        let maximum = max(depths.0, depths.1, depths.2)
        let allowedJump = max(0.10, minimum * 0.035)
        guard maximum - minimum <= allowedJump else { return }
        triangleIndices.append(contentsOf: [first, second, third])
    }

    private static func blend(_ previous: UInt8, _ new: UInt8) -> UInt8 {
        UInt8(clamping: Int((Float(previous) * 0.7 + Float(new) * 0.3).rounded()))
    }

    private static func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> (UInt8, UInt8, UInt8) {
        let luminance = Float(y)
        let blueDifference = Float(cb) - 128
        let redDifference = Float(cr) - 128
        return (
            channel(luminance + 1.402 * redDifference),
            channel(luminance - 0.344_136 * blueDifference - 0.714_136 * redDifference),
            channel(luminance + 1.772 * blueDifference)
        )
    }

    private static func channel(_ value: Float) -> UInt8 {
        UInt8(clamping: Int(value.rounded()))
    }
}

enum PhotoPointCloudStore {
    static func store(
        coloredSurface: ColoredSurfaceMesh,
        texturedSurface: TexturedSurfaceMesh,
        surveyID: UUID
    ) throws -> String? {
        guard !coloredSurface.vertices.isEmpty || !texturedSurface.chunks.isEmpty else {
            return nil
        }
        let fileName = "\(surveyID.uuidString)-reality.lpc"
        let url = try SurveyEngine.mediaURL(for: fileName)
        let archive = RealityMeshArchive(
            coloredSurface: coloredSurface,
            texturedSurface: texturedSurface
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(archive)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return fileName
    }

    static func loadArchive(from url: URL) -> RealityMeshArchive {
        guard let data = try? Data(contentsOf: url) else {
            return RealityMeshArchive(coloredSurface: .empty, texturedSurface: .empty)
        }
        if let archive = try? PropertyListDecoder().decode(RealityMeshArchive.self, from: data) {
            return archive
        }
        if let mesh = try? PropertyListDecoder().decode(ColoredSurfaceMesh.self, from: data) {
            return RealityMeshArchive(coloredSurface: mesh, texturedSurface: .empty)
        }
        let legacyPoints = (try? PropertyListDecoder().decode([PhotoPoint].self, from: data)) ?? []
        let legacyMesh = ColoredSurfaceMesh(vertices: legacyPoints, triangleIndices: [])
        return RealityMeshArchive(coloredSurface: legacyMesh, texturedSurface: .empty)
    }

    static func loadMesh(from url: URL) -> ColoredSurfaceMesh {
        loadArchive(from: url).coloredSurface
    }

    static func load(from url: URL) -> [PhotoPoint] {
        loadMesh(from: url).vertices
    }
}
