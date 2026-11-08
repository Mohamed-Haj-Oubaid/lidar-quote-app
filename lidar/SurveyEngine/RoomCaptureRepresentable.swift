import SwiftUI
import RoomPlan
import ARKit
import SceneKit

/// Wraps Apple's `RoomCaptureView`, which provides the built-in step-by-step
/// coaching UI ("move closer", "slow down", …) while the worker walks the perimeter.
struct RoomCaptureRepresentable: UIViewRepresentable {
    /// Set to false to stop scanning; RoomPlan then post-processes and calls `onFinish`.
    var isScanning: Bool
    let captureMode: ScanCaptureMode
    var onCoverageChange: (Double) -> Void
    var onFinish: (Result<RoomCaptureOutput, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCoverageChange: onCoverageChange, onFinish: onFinish)
    }

    func makeUIView(context: Context) -> RoomCaptureView {
        let arSession = ARSession()
        let worldConfiguration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            worldConfiguration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            worldConfiguration.sceneReconstruction = .mesh
        }
        worldConfiguration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth]) {
            worldConfiguration.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        }
        arSession.run(worldConfiguration)

        let view = RoomCaptureView(frame: .zero, arSession: arSession)
        view.delegate = context.coordinator
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        context.coordinator.recorder.start(session: arSession, mode: captureMode)
        context.coordinator.recorder.onCoverageChange = context.coordinator.onCoverageChange
        context.coordinator.installLivePointOverlay(on: view, session: arSession)
        context.coordinator.recorder.onLiveScanChange = { [weak coordinator = context.coordinator] frame in
            coordinator?.displayLiveScan(frame)
        }
        context.coordinator.isRunning = true
        return view
    }

    func updateUIView(_ view: RoomCaptureView, context: Context) {
        context.coordinator.onFinish = onFinish
        context.coordinator.onCoverageChange = onCoverageChange
        context.coordinator.recorder.onCoverageChange = onCoverageChange
        if !isScanning, context.coordinator.isRunning {
            context.coordinator.isRunning = false
            context.coordinator.recorder.stop()
            view.captureSession.stop()
        }
    }

    static func dismantleUIView(_ view: RoomCaptureView, coordinator: Coordinator) {
        if coordinator.isRunning {
            coordinator.recorder.stop()
            view.captureSession.stop()
        }
    }

    @objc(RoomCaptureCoordinator)
    final class Coordinator: NSObject, RoomCaptureViewDelegate {
        var onFinish: (Result<RoomCaptureOutput, Error>) -> Void
        var onCoverageChange: (Double) -> Void
        var isRunning = false
        let recorder = PhotoPointCloudRecorder()
        private weak var livePointView: ARSCNView?

        init(
            onCoverageChange: @escaping (Double) -> Void,
            onFinish: @escaping (Result<RoomCaptureOutput, Error>) -> Void
        ) {
            self.onCoverageChange = onCoverageChange
            self.onFinish = onFinish
        }

        // RoomCaptureViewDelegate inherits NSCoding; the coordinator is never archived.
        required init?(coder: NSCoder) { nil }
        func encode(with coder: NSCoder) {}

        func installLivePointOverlay(on captureView: RoomCaptureView, session: ARSession) {
            let pointView = ARSCNView()
            pointView.translatesAutoresizingMaskIntoConstraints = false
            pointView.backgroundColor = .clear
            pointView.isOpaque = false
            pointView.isUserInteractionEnabled = false
            pointView.antialiasingMode = .multisampling4X
            pointView.layer.zPosition = 10_000
            pointView.session = session
            pointView.scene = SCNScene()
            pointView.scene.background.contents = UIColor.clear
            pointView.automaticallyUpdatesLighting = false
            pointView.rendersMotionBlur = false
            captureView.addSubview(pointView)
            NSLayoutConstraint.activate([
                pointView.leadingAnchor.constraint(equalTo: captureView.leadingAnchor),
                pointView.trailingAnchor.constraint(equalTo: captureView.trailingAnchor),
                pointView.topAnchor.constraint(equalTo: captureView.topAnchor),
                pointView.bottomAnchor.constraint(equalTo: captureView.bottomAnchor)
            ])
            livePointView = pointView
        }

        func displayLiveScan(_ frame: LiveScanFrame) {
            guard let pointView = livePointView,
                  !frame.points.isEmpty,
                  pointView.bounds.width > 0,
                  pointView.bounds.height > 0 else {
                return
            }
            pointView.superview?.bringSubviewToFront(pointView)

            let scene = SCNScene()
            let positions = frame.points.map { SCNVector3($0.position) }
            let colors = frame.points.flatMap { Self.scanColor(for: $0.quality) }
            let colorData = colors.withUnsafeBytes { Data($0) }
            let positionSource = SCNGeometrySource(vertices: positions)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: frame.points.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            )
            guard !frame.triangleIndices.isEmpty else { return }
            let element = SCNGeometryElement(
                indices: frame.triangleIndices,
                primitiveType: .triangles
            )

            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            material.emission.contents = UIColor(white: 0.16, alpha: 1)
            material.isDoubleSided = true
            material.transparency = 0.46
            material.blendMode = .alpha
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            let geometry = SCNGeometry(
                sources: [positionSource, colorSource],
                elements: [element]
            )
            geometry.materials = [material]
            let scanNode = SCNNode(geometry: geometry)
            scanNode.renderingOrder = 10_000
            scene.rootNode.addChildNode(scanNode)

            // 3D Scanner-style live triangular grid. The translucent fill shows coverage,
            // while this fine wire layer makes the reconstructed shape readable in motion.
            let wireMaterial = SCNMaterial()
            wireMaterial.lightingModel = .constant
            wireMaterial.diffuse.contents = UIColor(white: 0.92, alpha: 0.72)
            wireMaterial.emission.contents = UIColor(red: 0.28, green: 0.95, blue: 0.72, alpha: 1)
            wireMaterial.fillMode = .lines
            wireMaterial.isDoubleSided = true
            wireMaterial.transparency = 0.62
            wireMaterial.blendMode = .add
            wireMaterial.readsFromDepthBuffer = false
            wireMaterial.writesToDepthBuffer = false

            let wireGeometry = geometry.copy() as? SCNGeometry ?? geometry
            wireGeometry.materials = [wireMaterial]
            let wireNode = SCNNode(geometry: wireGeometry)
            wireNode.renderingOrder = 10_001
            scene.rootNode.addChildNode(wireNode)

            pointView.scene = scene
        }

        /// Continuous heat-map color avoids the harsh red/orange/green bands used before.
        private static func scanColor(for rawQuality: Float) -> [Float] {
            let quality = min(max(rawQuality, 0), 1)
            let red = SIMD3<Float>(1.0, 0.16, 0.10)
            let orange = SIMD3<Float>(1.0, 0.64, 0.08)
            let green = SIMD3<Float>(0.12, 0.95, 0.32)
            let color: SIMD3<Float>

            if quality < 0.5 {
                let progress = smoothStep(quality * 2)
                color = simd_mix(red, orange, SIMD3<Float>(repeating: progress))
            } else {
                let progress = smoothStep((quality - 0.5) * 2)
                color = simd_mix(orange, green, SIMD3<Float>(repeating: progress))
            }

            return [color.x, color.y, color.z, 0.9]
        }

        private static func smoothStep(_ value: Float) -> Float {
            let clamped = min(max(value, 0), 1)
            return clamped * clamped * (3 - 2 * clamped)
        }

        func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
            if let error {
                onFinish(.failure(error))
                return false
            }
            return true
        }

        func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
            if let error {
                onFinish(.failure(error))
            } else {
                recorder.stop()
                onFinish(.success(RoomCaptureOutput(
                    room: processedResult,
                    photoPoints: recorder.points,
                    coloredSurface: recorder.coloredSurface,
                    texturedSurface: recorder.texturedSurface
                )))
            }
        }
    }
}
