import SwiftUI
import SceneKit

enum RoomModelDisplayMode: String, CaseIterable, Identifiable {
    case photo
    case laser
    case color
    case white
    case rawMesh
    case points

    var id: String { rawValue }

    static let meshModes: [RoomModelDisplayMode] = [.color, .laser, .white, .rawMesh, .points]

    var title: LocalizedStringResource {
        switch self {
        case .photo: "Real 3D"
        case .laser: "Laser"
        case .color: "Color"
        case .white: "White"
        case .rawMesh: "Raw Mesh"
        case .points: "Points"
        }
    }

    var systemImage: String {
        switch self {
        case .photo: "cube.transparent"
        case .laser: "scope"
        case .color: "paintpalette"
        case .white: "square.fill"
        case .rawMesh: "triangle"
        case .points: "circle.grid.3x3.fill"
        }
    }
}

struct RoomModelViewerItem: Identifiable {
    let id = UUID()
    let url: URL
    let photoPointCloudURL: URL?
    let wallTextureURLs: [URL]
}

private enum ManualMeasurementMode: String, CaseIterable, Identifiable {
    case distance, horizontal, vertical
    var id: String { rawValue }
    var title: LocalizedStringResource { switch self { case .distance: "Distance"; case .horizontal: "Horizontal"; case .vertical: "Height" } }
    var icon: String { switch self { case .distance: "ruler"; case .horizontal: "arrow.left.and.right"; case .vertical: "arrow.up.and.down" } }
}

private struct ManualMeasurementResult: Identifiable, Equatable {
    let id: UUID
    let mode: ManualMeasurementMode
    let value: Double
}

struct RoomModelViewer: View {
    let modelURL: URL
    let photoPointCloudURL: URL?
    let wallTextureURLs: [URL]
    let roomName: String
    let measurement: RoomMeasurement
    let startsInMeasurementMode: Bool
    let measurementSaveTitle: LocalizedStringResource?
    let onSaveMeasurement: ((Double) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var displayMode: RoomModelDisplayMode = .laser
    @State private var isMeasuring = false
    @State private var manualDistance: Double?
    @State private var measurementMode = ManualMeasurementMode.distance
    @State private var measurementResults: [ManualMeasurementResult] = []
    @State private var measurementResetID = UUID()
    @State private var measurementUndoID = UUID()

    init(
        modelURL: URL,
        photoPointCloudURL: URL?,
        wallTextureURLs: [URL],
        roomName: String,
        measurement: RoomMeasurement,
        startsInMeasurementMode: Bool,
        measurementSaveTitle: LocalizedStringResource?,
        onSaveMeasurement: ((Double) -> Void)?
    ) {
        self.modelURL = modelURL
        self.photoPointCloudURL = photoPointCloudURL
        self.wallTextureURLs = wallTextureURLs
        self.roomName = roomName
        self.measurement = measurement
        self.startsInMeasurementMode = startsInMeasurementMode
        self.measurementSaveTitle = measurementSaveTitle
        self.onSaveMeasurement = onSaveMeasurement
        _displayMode = State(initialValue: .laser)
        _isMeasuring = State(initialValue: startsInMeasurementMode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    RoomSceneView(
                        modelURL: modelURL,
                        photoPointCloudURL: photoPointCloudURL,
                        wallTextureURLs: wallTextureURLs,
                        measurement: measurement,
                        displayMode: displayMode,
                        isMeasuring: isMeasuring,
                        measurementMode: measurementMode,
                        measurementResetID: measurementResetID,
                        measurementUndoID: measurementUndoID,
                        onManualDistanceChange: { manualDistance = $0 },
                        onMeasurementsChange: { measurementResults = $0 }
                    )
                    .ignoresSafeArea(edges: .horizontal)

                    if isMeasuring {
                        ManualMeasurementBanner(
                            mode: $measurementMode,
                            distance: manualDistance,
                            results: measurementResults,
                            onUndo: { measurementUndoID = UUID() },
                            onClear: {
                                measurementResetID = UUID()
                                manualDistance = nil
                            },
                            saveTitle: measurementSaveTitle,
                            onSave: saveMeasurement
                        )
                            .padding()
                    } else {
                        ModelColorLegend()
                            .padding()
                    }
                }

                ViewerControls(displayMode: $displayMode, includesPhoto: !wallTextureURLs.isEmpty || photoPointCloudURL != nil)
                    .disabled(isMeasuring)
            }
            .navigationTitle(roomName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isMeasuring.toggle()
                    } label: {
                        Label(
                            isMeasuring ? "Stop measuring" : "Measure",
                            systemImage: isMeasuring ? "ruler.fill" : "ruler"
                        )
                    }
                    .tint(isMeasuring ? .orange : .accentColor)
                }
                if isMeasuring {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear measurements", systemImage: "trash") {
                            measurementResetID = UUID()
                            manualDistance = nil
                        }
                    }
                }
            }
        }
    }

    private func saveMeasurement() {
        guard let manualDistance else { return }
        onSaveMeasurement?(manualDistance)
        dismiss()
    }
}

private struct ModelColorLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            LegendItem(title: "Walls", color: .yellow)
            LegendItem(title: "Doors", color: .orange)
            LegendItem(title: "Windows", color: .cyan)
            LegendItem(title: "Openings", color: .purple)
        }
        .font(.caption.bold())
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: .capsule)
    }
}

private struct LegendItem: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title)
        }
    }
}

private struct ManualMeasurementBanner: View {
    @Binding var mode: ManualMeasurementMode
    let distance: Double?
    let results: [ManualMeasurementResult]
    let onUndo: () -> Void
    let onClear: () -> Void
    let saveTitle: LocalizedStringResource?
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Picker("Measurement type", selection: $mode) {
                ForEach(ManualMeasurementMode.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .pickerStyle(.segmented)
            if let distance {
                Text(
                    Measurement(value: distance, unit: UnitLength.meters),
                    format: .measurement(
                        width: .abbreviated,
                        usage: .asProvided,
                        numberFormatStyle: .number.precision(.fractionLength(2))
                    )
                )
                    .font(.title2.monospacedDigit())
                    .bold()
            } else {
                Text("Tap the first point")
                    .font(.headline)
            }
            Text("Tap two points. Horizontal and Height lock automatically to the correct axis.")
                .font(.callout)
                .multilineTextAlignment(.center)
            HStack {
                Label("\(results.count) measurements", systemImage: "list.number")
                Spacer()
                Button("Undo", systemImage: "arrow.uturn.backward", action: onUndo)
                    .disabled(results.isEmpty)
                Button("Clear", systemImage: "trash", role: .destructive, action: onClear)
                    .disabled(results.isEmpty)
                if let saveTitle {
                    Button(saveTitle, systemImage: "checkmark.circle.fill", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(distance == nil)
                }
            }
            .font(.callout)
            if !results.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Label {
                                Text("#\(index + 1) · \(result.value, format: .number.precision(.fractionLength(2))) m")
                            } icon: {
                                Image(systemName: result.mode.icon)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: .capsule)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}

private struct ViewerControls: View {
    @Binding var displayMode: RoomModelDisplayMode
    let includesPhoto: Bool

    var body: some View {
        Picker("3D model style", selection: $displayMode) {
                if includesPhoto {
                Label(RoomModelDisplayMode.photo.title, systemImage: RoomModelDisplayMode.photo.systemImage)
                    .tag(RoomModelDisplayMode.photo)
            }
            ForEach(RoomModelDisplayMode.meshModes) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding()
        .background(.bar)
    }
}

private struct RoomSceneView: UIViewRepresentable {
    let modelURL: URL
    let photoPointCloudURL: URL?
    let wallTextureURLs: [URL]
    let measurement: RoomMeasurement
    let displayMode: RoomModelDisplayMode
    let isMeasuring: Bool
    let measurementMode: ManualMeasurementMode
    let measurementResetID: UUID
    let measurementUndoID: UUID
    let onManualDistanceChange: (Double?) -> Void
    let onMeasurementsChange: ([ManualMeasurementResult]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onManualDistanceChange: onManualDistanceChange, onMeasurementsChange: onMeasurementsChange)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .systemBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        context.coordinator.installMeasurementGestures(on: view)
        context.coordinator.setMeasuring(isMeasuring, in: view)
        context.coordinator.setMeasurementMode(measurementMode)
        context.coordinator.applyReset(measurementResetID, in: view)
        context.coordinator.applyUndo(measurementUndoID, in: view)
        context.coordinator.render(
            in: view,
            modelURL: modelURL,
            photoPointCloudURL: photoPointCloudURL,
            wallTextureURLs: wallTextureURLs,
            measurement: measurement,
            mode: displayMode
        )
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onManualDistanceChange = onManualDistanceChange
        context.coordinator.setMeasuring(isMeasuring, in: view)
        context.coordinator.setMeasurementMode(measurementMode)
        context.coordinator.applyReset(measurementResetID, in: view)
        context.coordinator.applyUndo(measurementUndoID, in: view)
        context.coordinator.render(
            in: view,
            modelURL: modelURL,
            photoPointCloudURL: photoPointCloudURL,
            wallTextureURLs: wallTextureURLs,
            measurement: measurement,
            mode: displayMode
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var lastMode: RoomModelDisplayMode?
        private var lastURL: URL?
        private var isMeasuring = false
        private var measurementStart: SIMD3<Float>?
        private var measurementEnd: SIMD3<Float>?
        private var measurementMode = ManualMeasurementMode.distance
        private var completedMeasurements: [ManualMeasurementResult] = []
        private var lastResetID: UUID?
        private var lastUndoID: UUID?
        var onManualDistanceChange: (Double?) -> Void
        var onMeasurementsChange: ([ManualMeasurementResult]) -> Void

        init(
            onManualDistanceChange: @escaping (Double?) -> Void,
            onMeasurementsChange: @escaping ([ManualMeasurementResult]) -> Void
        ) {
            self.onManualDistanceChange = onManualDistanceChange
            self.onMeasurementsChange = onMeasurementsChange
        }

        func setMeasurementMode(_ mode: ManualMeasurementMode) {
            measurementMode = mode
        }

        func installMeasurementGestures(on view: SCNView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleMeasurementTap(_:)))
            tap.delegate = self
            view.addGestureRecognizer(tap)
        }

        func setMeasuring(_ enabled: Bool, in view: SCNView) {
            guard enabled != isMeasuring else { return }
            isMeasuring = enabled
            view.allowsCameraControl = true
            if enabled {
                clearManualMeasurement(in: view)
            }
        }

        func applyReset(_ resetID: UUID, in view: SCNView) {
            guard resetID != lastResetID else { return }
            lastResetID = resetID
            clearManualMeasurement(in: view)
        }

        func applyUndo(_ undoID: UUID, in view: SCNView) {
            guard undoID != lastUndoID else { return }
            lastUndoID = undoID
            guard !completedMeasurements.isEmpty else { return }
            completedMeasurements.removeLast()
            let root = view.scene?.rootNode.childNode(withName: "manual-measurements", recursively: false)
            root?.childNodes.last(where: { $0.name?.hasPrefix("manual-measurement-") == true })?.removeFromParentNode()
            onMeasurementsChange(completedMeasurements)
            onManualDistanceChange(completedMeasurements.last?.value)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isMeasuring
        }

        @objc private func handleMeasurementTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView,
                  let point = modelPoint(at: gesture.location(in: view), in: view) else {
                return
            }
            if measurementStart == nil {
                measurementStart = point
                drawManualMeasurement(in: view)
            } else {
                measurementEnd = constrained(point, from: measurementStart!, mode: measurementMode)
                drawManualMeasurement(in: view)
                measurementStart = nil
                measurementEnd = nil
            }
        }

        private func constrained(
            _ end: SIMD3<Float>,
            from start: SIMD3<Float>,
            mode: ManualMeasurementMode
        ) -> SIMD3<Float> {
            switch mode {
            case .distance: end
            case .horizontal: SIMD3<Float>(end.x, start.y, end.z)
            case .vertical: SIMD3<Float>(start.x, end.y, start.z)
            }
        }

        private func modelPoint(at location: CGPoint, in view: SCNView) -> SIMD3<Float>? {
            view.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .backFaceCulling: false
            ])
            .first(where: { result in
                var node: SCNNode? = result.node
                while let current = node {
                    if current.name?.hasPrefix("manual-measurement") == true { return false }
                    node = current.parent
                }
                return true
            })
            .map { SIMD3<Float>($0.worldCoordinates) }
        }

        private func clearManualMeasurement(in view: SCNView) {
            view.scene?.rootNode.childNode(withName: "manual-measurements", recursively: false)?.removeFromParentNode()
            measurementStart = nil
            measurementEnd = nil
            completedMeasurements.removeAll()
            onManualDistanceChange(nil)
            onMeasurementsChange([])
        }

        private func drawManualMeasurement(in view: SCNView) {
            guard let scene = view.scene, let start = measurementStart else { return }
            let measurementsRoot: SCNNode
            if let existing = scene.rootNode.childNode(withName: "manual-measurements", recursively: false) {
                measurementsRoot = existing
            } else {
                let node = SCNNode()
                node.name = "manual-measurements"
                scene.rootNode.addChildNode(node)
                measurementsRoot = node
            }
            measurementsRoot.childNode(
                withName: "manual-measurement-current",
                recursively: false
            )?.removeFromParentNode()

            let container = SCNNode()
            container.name = measurementEnd == nil
                ? "manual-measurement-current"
                : "manual-measurement-\(UUID().uuidString)"
            container.renderingOrder = 2_000
            container.addChildNode(measurementPointNode(at: start))

            if let end = measurementEnd {
                container.addChildNode(measurementPointNode(at: end))
                let delta = end - start
                let distance = simd_length(delta)
                if distance > 0.001 {
                    let line = SCNCylinder(radius: 0.003, height: CGFloat(distance))
                    let material = SCNMaterial()
                    material.lightingModel = .constant
                    material.diffuse.contents = UIColor.systemOrange
                    material.emission.contents = UIColor.systemOrange
                    material.readsFromDepthBuffer = true
                    material.writesToDepthBuffer = false
                    line.materials = [material]
                    let lineNode = SCNNode(geometry: line)
                    lineNode.simdPosition = (start + end) / 2
                    lineNode.simdOrientation = simd_quatf(
                        from: SIMD3<Float>(0, 1, 0),
                        to: simd_normalize(delta)
                    )
                    container.addChildNode(lineNode)

                    let labelText = Measurement(
                        value: Double(distance),
                        unit: UnitLength.meters
                    ).formatted(
                        .measurement(
                            width: .abbreviated,
                            usage: .asProvided,
                            numberFormatStyle: .number.precision(.fractionLength(2))
                        )
                    )
                    container.addChildNode(labelNode(
                        text: labelText,
                        position: (start + end) / 2 + SIMD3<Float>(0, 0.08, 0),
                        color: .systemOrange
                    ))
                    onManualDistanceChange(Double(distance))
                    completedMeasurements.append(ManualMeasurementResult(
                        id: UUID(),
                        mode: measurementMode,
                        value: Double(distance)
                    ))
                    onMeasurementsChange(completedMeasurements)
                }
            }
            measurementsRoot.addChildNode(container)
        }

        private func measurementPointNode(at position: SIMD3<Float>) -> SCNNode {
            let marker = SCNNode()
            marker.simdPosition = position
            marker.renderingOrder = 2_100

            let sphere = SCNSphere(radius: 0.012)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.systemOrange
            material.emission.contents = UIColor.systemOrange
            material.readsFromDepthBuffer = true
            material.writesToDepthBuffer = false
            sphere.materials = [material]
            marker.addChildNode(SCNNode(geometry: sphere))

            for delay in [0.0, 0.55] {
                let ring = SCNTorus(ringRadius: 0.045, pipeRadius: 0.004)
                let ringMaterial = SCNMaterial()
                ringMaterial.lightingModel = .constant
                ringMaterial.diffuse.contents = UIColor.systemOrange
                ringMaterial.emission.contents = UIColor.systemOrange
                ringMaterial.readsFromDepthBuffer = true
                ringMaterial.writesToDepthBuffer = false
                ring.materials = [ringMaterial]

                let ringNode = SCNNode(geometry: ring)
                ringNode.eulerAngles.x = .pi / 2
                ringNode.opacity = 0
                let wait = SCNAction.wait(duration: delay)
                let appear = SCNAction.fadeOpacity(to: 0.95, duration: 0.08)
                let wave = SCNAction.group([
                    .scale(to: 2.8, duration: 1.1),
                    .fadeOut(duration: 1.1)
                ])
                let reset = SCNAction.run { node in
                    node.scale = SCNVector3(1, 1, 1)
                    node.opacity = 0
                }
                ringNode.runAction(.repeatForever(.sequence([wait, appear, wave, reset])))
                marker.addChildNode(ringNode)
            }
            return marker
        }

        func render(
            in view: SCNView,
            modelURL: URL,
            photoPointCloudURL: URL?,
            wallTextureURLs: [URL],
            measurement: RoomMeasurement,
            mode: RoomModelDisplayMode
        ) {
            guard mode != lastMode || modelURL != lastURL else {
                return
            }

            let scene: SCNScene
            if mode == .laser, let photoPointCloudURL {
                scene = laserScene(from: photoPointCloudURL, measurement: measurement)
            } else if mode == .photo, !wallTextureURLs.isEmpty {
                scene = texturedRoomScene(measurement: measurement, textureURLs: wallTextureURLs)
            } else if mode == .photo, let photoPointCloudURL {
                scene = photoScene(from: photoPointCloudURL)
            } else {
                scene = (try? SCNScene(url: modelURL, options: nil)) ?? SCNScene()
                apply(mode: mode, to: scene.rootNode)
            }
            addMeasurements(measurement, to: scene.rootNode, showBorders: mode != .laser)
            addStudioLighting(to: scene)
            addCameraIfNeeded(to: scene, measurement: measurement)
            switch mode {
            case .photo:
                view.backgroundColor = .black
            case .color:
                view.backgroundColor = .secondarySystemBackground
            default:
                view.backgroundColor = .systemBackground
            }
            view.scene = scene
            view.pointOfView = scene.rootNode.childNode(withName: "viewer-camera", recursively: true)

            lastMode = mode
            lastURL = modelURL
        }

        private func apply(mode: RoomModelDisplayMode, to root: SCNNode) {
            root.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry else { return }

                if mode == .points {
                    node.geometry = pointGeometry(from: geometry)
                    return
                }

                for material in geometry.materials {
                    material.lightingModel = mode == .laser ? .constant : .physicallyBased
                    material.fillMode = (mode == .laser || mode == .rawMesh) ? .lines : .fill

                    switch mode {
                    case .photo:
                        break
                    case .laser:
                        material.diffuse.contents = UIColor.clear
                        material.emission.contents = UIColor.clear
                        material.transparency = 0
                    case .color:
                        break
                    case .white:
                        material.diffuse.contents = UIColor.white
                        material.emission.contents = UIColor.black
                        material.roughness.contents = 0.8
                    case .rawMesh:
                        material.diffuse.contents = UIColor.secondaryLabel
                        material.emission.contents = UIColor.clear
                        material.transparency = 1
                    case .points:
                        break
                    }
                }
            }
        }

        private func texturedRoomScene(
            measurement: RoomMeasurement,
            textureURLs: [URL]
        ) -> SCNScene {
            let scene = SCNScene()

            for (index, wall) in measurement.walls.enumerated() {
                guard index < textureURLs.count,
                      let image = UIImage(contentsOfFile: textureURLs[index].path) else {
                    continue
                }

                let plane = SCNPlane(
                    width: CGFloat(max(wall.length, 0.01)),
                    height: CGFloat(max(wall.height, 0.01))
                )
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                material.diffuse.contents = image
                material.roughness.contents = 0.85
                material.metalness.contents = 0
                material.isDoubleSided = true
                plane.materials = [material]

                let node = SCNNode(geometry: plane)
                let dx = wall.end.x - wall.start.x
                let dz = wall.end.y - wall.start.y
                node.eulerAngles.y = Float(-atan2(dz, dx))
                node.simdPosition = SIMD3(
                    Float((wall.start.x + wall.end.x) / 2),
                    Float(wall.height / 2),
                    Float((wall.start.y + wall.end.y) / 2)
                )
                scene.rootNode.addChildNode(node)
            }

            return scene
        }

        private func photoScene(from url: URL) -> SCNScene {
            let scene = SCNScene()
            let archive = PhotoPointCloudStore.loadArchive(from: url)
            let mesh = archive.coloredSurface
            guard !mesh.vertices.isEmpty else { return scene }

            let vertices = mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
            let colorValues = mesh.vertices.flatMap {
                [
                    Float($0.red) / 255,
                    Float($0.green) / 255,
                    Float($0.blue) / 255,
                    Float(1)
                ]
            }
            let colorData = colorValues.withUnsafeBytes { Data($0) }
            let vertexSource = SCNGeometrySource(vertices: vertices)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: mesh.vertices.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            )

            let element: SCNGeometryElement
            if mesh.triangleIndices.isEmpty {
                let pointIndices = (0..<mesh.vertices.count).map(UInt32.init)
                element = SCNGeometryElement(indices: pointIndices, primitiveType: .point)
                element.pointSize = 5
                element.minimumPointScreenSpaceRadius = 2
                element.maximumPointScreenSpaceRadius = 8
            } else {
                element = SCNGeometryElement(indices: mesh.triangleIndices, primitiveType: .triangles)
            }

            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            material.isDoubleSided = true
            material.readsFromDepthBuffer = true
            material.writesToDepthBuffer = true

            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            geometry.materials = [material]
            let fallbackNode = SCNNode(geometry: geometry)
            fallbackNode.renderingOrder = -1
            scene.rootNode.addChildNode(fallbackNode)
            if !archive.texturedSurface.chunks.isEmpty {
                addTexturedChunks(archive.texturedSurface.chunks, to: scene)
            }
            return scene
        }

        private func laserScene(from url: URL, measurement: RoomMeasurement) -> SCNScene {
            let scene = SCNScene()
            let mesh = PhotoPointCloudStore.loadArchive(from: url).coloredSurface
            guard !mesh.vertices.isEmpty else { return scene }

            let vertices = mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
            let colors = mesh.vertices.flatMap { vertex -> [Float] in
                let color = laserColor(
                    at: SIMD3<Float>(vertex.x, vertex.y, vertex.z),
                    measurement: measurement
                )
                var red: CGFloat = 1
                var green: CGFloat = 1
                var blue: CGFloat = 1
                var alpha: CGFloat = 1
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                return [Float(red), Float(green), Float(blue), Float(alpha)]
            }
            let colorData = colors.withUnsafeBytes { Data($0) }
            let vertexSource = SCNGeometrySource(vertices: vertices)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: vertices.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            )
            let indices = mesh.triangleIndices.isEmpty
                ? (0..<vertices.count).map(UInt32.init)
                : mesh.triangleIndices
            let primitive: SCNGeometryPrimitiveType = mesh.triangleIndices.isEmpty ? .point : .triangles
            let element = SCNGeometryElement(indices: indices, primitiveType: primitive)
            if primitive == .point {
                element.pointSize = 4
                element.minimumPointScreenSpaceRadius = 1
                element.maximumPointScreenSpaceRadius = 5
            }
            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            material.emission.contents = UIColor(white: 0.12, alpha: 1)
            material.fillMode = mesh.triangleIndices.isEmpty ? .fill : .lines
            material.isDoubleSided = true
            geometry.materials = [material]
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
            return scene
        }

        private func laserColor(
            at point: SIMD3<Float>,
            measurement: RoomMeasurement
        ) -> UIColor {
            guard let match = measurement.walls.enumerated().map({ index, wall in
                (index, wall, wallProjection(point, onto: wall))
            }).min(by: { $0.2.distance < $1.2.distance }) else {
                return .white
            }

            if let opening = measurement.openings.first(where: { opening in
                guard opening.wallID == match.1.id else { return false }
                let center = opening.centerOffset ?? match.1.length / 2
                let centerHeight = opening.centerHeight
                    ?? (opening.kind == .door ? opening.height / 2 : 1.1)
                return abs(match.2.offset - center) <= opening.width / 2
                    && abs(Double(point.y) - centerHeight) <= opening.height / 2
                    && match.2.distance < 0.35
            }) {
                return openingColor(for: opening.kind)
            }
            return wallColor(at: match.0)
        }

        private func wallProjection(
            _ point: SIMD3<Float>,
            onto wall: WallSegment
        ) -> (distance: Double, offset: Double) {
            let dx = wall.end.x - wall.start.x
            let dz = wall.end.y - wall.start.y
            let lengthSquared = max(dx * dx + dz * dz, .ulpOfOne)
            let ratio = min(max(
                ((Double(point.x) - wall.start.x) * dx + (Double(point.z) - wall.start.y) * dz)
                    / lengthSquared,
                0
            ), 1)
            let nearestX = wall.start.x + dx * ratio
            let nearestZ = wall.start.y + dz * ratio
            return (
                hypot(Double(point.x) - nearestX, Double(point.z) - nearestZ),
                sqrt(lengthSquared) * ratio
            )
        }

        private func addTexturedChunks(
            _ chunks: [TexturedSurfaceChunk],
            to scene: SCNScene
        ) {
            for chunk in chunks {
                guard let image = UIImage(data: chunk.jpegData),
                      chunk.vertices.count == chunk.textureCoordinates.count else {
                    continue
                }

                let vertices = chunk.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
                let textureCoordinates = chunk.textureCoordinates.map {
                    CGPoint(x: CGFloat($0.u), y: CGFloat($0.v))
                }
                let vertexSource = SCNGeometrySource(vertices: vertices)
                let textureSource = SCNGeometrySource(textureCoordinates: textureCoordinates)
                let element = SCNGeometryElement(
                    indices: chunk.triangleIndices,
                    primitiveType: .triangles
                )

                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = image
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                material.isDoubleSided = true
                material.readsFromDepthBuffer = true
                material.writesToDepthBuffer = true

                let geometry = SCNGeometry(
                    sources: [vertexSource, textureSource],
                    elements: [element]
                )
                geometry.materials = [material]
                let node = SCNNode(geometry: geometry)
                node.renderingOrder = 1
                scene.rootNode.addChildNode(node)
            }
        }

        private func pointGeometry(from geometry: SCNGeometry) -> SCNGeometry {
            guard let vertexSource = geometry.sources(for: .vertex).first else {
                return geometry
            }
            let indices = (0..<vertexSource.vectorCount).map(Int32.init)
            let points = SCNGeometryElement(indices: indices, primitiveType: .point)
            points.pointSize = 5
            points.minimumPointScreenSpaceRadius = 2
            points.maximumPointScreenSpaceRadius = 7

            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.systemCyan
            material.emission.contents = UIColor.systemCyan

            let result = SCNGeometry(sources: [vertexSource], elements: [points])
            result.materials = [material]
            return result
        }

        private func addMeasurements(
            _ measurement: RoomMeasurement,
            to root: SCNNode,
            showBorders: Bool
        ) {
            for (index, wall) in measurement.walls.enumerated() {
                let wallColor = wallColor(at: index)
                let labelPosition = surfacePosition(for: wall, height: wall.height * 0.62, offset: 0)
                let text = String(
                    localized: "Wall \(index + 1) · \(wall.length.formatted(.number.precision(.fractionLength(2)))) m × \(wall.height.formatted(.number.precision(.fractionLength(2)))) m"
                )
                if showBorders {
                    root.addChildNode(wallBorderNode(wall: wall, color: wallColor))
                }
                root.addChildNode(labelNode(text: text, position: labelPosition, color: wallColor))
            }

            for opening in measurement.openings {
                guard let wall = measurement.walls.first(where: { $0.id == opening.wallID }) else {
                    continue
                }
                let offset = min(max(opening.centerOffset ?? wall.length / 2, 0), wall.length)
                let fraction = Float(offset / max(wall.length, .ulpOfOne))
                let start = SIMD3<Float>(Float(wall.start.x), 0, Float(wall.start.y))
                let end = SIMD3<Float>(Float(wall.end.x), 0, Float(wall.end.y))
                let height = opening.centerHeight ?? (opening.kind == .door ? opening.height / 2 : 1.1)
                let basePosition = start + (end - start) * fraction + SIMD3<Float>(0, Float(height), 0)
                let position = basePosition
                let depthText = opening.depth.map {
                    " × \($0.formatted(.number.precision(.fractionLength(2)))) m deep"
                } ?? ""
                let text = String(localized: "\(opening.kind.title): \(opening.width.formatted(.number.precision(.fractionLength(2)))) × \(opening.height.formatted(.number.precision(.fractionLength(2)))) m\(depthText)")
                if showBorders {
                    root.addChildNode(openingDepthNode(opening: opening, wall: wall, position: position))
                }
                let color = openingColor(for: opening.kind)
                root.addChildNode(labelNode(text: text, position: position, color: color))
            }
        }

        private func wallNormal(_ wall: WallSegment) -> SIMD3<Float> {
            let dx = Float(wall.end.x - wall.start.x)
            let dz = Float(wall.end.y - wall.start.y)
            let length = max(hypot(dx, dz), 0.001)
            return SIMD3<Float>(-dz / length, 0, dx / length)
        }

        private func surfacePosition(
            for wall: WallSegment,
            height: Double,
            offset: Float
        ) -> SIMD3<Float> {
            SIMD3<Float>(
                Float((wall.start.x + wall.end.x) / 2),
                Float(height),
                Float((wall.start.y + wall.end.y) / 2)
            ) + wallNormal(wall) * offset
        }

        private func wallColor(at index: Int) -> UIColor {
            let colors: [UIColor] = [
                .systemYellow, .systemPink, .systemBlue, .systemGreen,
                .systemPurple, .systemTeal, .systemRed, .systemIndigo
            ]
            return colors[index % colors.count]
        }

        private func openingColor(for kind: RoomOpening.Kind) -> UIColor {
            switch kind {
            case .door: .systemOrange
            case .window: .systemCyan
            case .opening: .systemPurple
            }
        }

        private func wallBorderNode(wall: WallSegment, color: UIColor) -> SCNNode {
            let start = SIMD3<Float>(Float(wall.start.x), 0, Float(wall.start.y))
            let end = SIMD3<Float>(Float(wall.end.x), 0, Float(wall.end.y))
            return rectangleBorderNode(
                corners: [
                    start,
                    end,
                    end + SIMD3<Float>(0, Float(wall.height), 0),
                    start + SIMD3<Float>(0, Float(wall.height), 0)
                ],
                color: color
            )
        }

        private func openingDepthNode(
            opening: RoomOpening,
            wall: WallSegment,
            position: SIMD3<Float>
        ) -> SCNNode {
            let color = openingColor(for: opening.kind)
            let wallDirection = simd_normalize(SIMD3<Float>(
                Float(wall.end.x - wall.start.x), 0, Float(wall.end.y - wall.start.y)
            ))
            let halfWidth = wallDirection * Float(opening.width / 2)
            let halfHeight = SIMD3<Float>(0, Float(opening.height / 2), 0)
            return rectangleBorderNode(
                corners: [
                    position - halfWidth - halfHeight,
                    position + halfWidth - halfHeight,
                    position + halfWidth + halfHeight,
                    position - halfWidth + halfHeight
                ],
                color: color
            )
        }

        private func rectangleBorderNode(
            corners: [SIMD3<Float>],
            color: UIColor
        ) -> SCNNode {
            let vertices = corners.map(SCNVector3.init)
            let source = SCNGeometrySource(vertices: vertices)
            let indices: [UInt32] = [0, 1, 1, 2, 2, 3, 3, 0]
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.emission.contents = color.withAlphaComponent(0.18)
            material.readsFromDepthBuffer = true
            material.writesToDepthBuffer = true
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.renderingOrder = 0
            return node
        }

        private func labelNode(text: String, position: SIMD3<Float>, color: UIColor) -> SCNNode {
            let label = SCNText(string: text, extrusionDepth: 0.004)
            label.font = .preferredFont(forTextStyle: .caption1)
            label.flatness = 0.2
            label.firstMaterial?.diffuse.contents = color
            label.firstMaterial?.emission.contents = color
            label.firstMaterial?.readsFromDepthBuffer = true
            label.firstMaterial?.writesToDepthBuffer = false
            label.firstMaterial?.isDoubleSided = true

            let node = SCNNode(geometry: label)
            let bounds = label.boundingBox
            let width = bounds.max.x - bounds.min.x
            node.pivot = SCNMatrix4MakeTranslation(width / 2, bounds.min.y, 0)
            node.scale = SCNVector3(0.008, 0.008, 0.008)
            node.simdPosition = position
            node.renderingOrder = 2

            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .Y
            node.constraints = [billboard]
            return node
        }

        private func addStudioLighting(to scene: SCNScene) {
            scene.lightingEnvironment.intensity = 1.4

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.color = UIColor(white: 0.72, alpha: 1)
            ambient.light?.intensity = 650
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.color = UIColor.white
            key.light?.intensity = 1_200
            key.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .directional
            fill.light?.color = UIColor(red: 0.72, green: 0.84, blue: 1, alpha: 1)
            fill.light?.intensity = 500
            fill.eulerAngles = SCNVector3(-Float.pi / 4, -Float.pi / 2, 0)
            scene.rootNode.addChildNode(fill)
        }

        private func addCameraIfNeeded(to scene: SCNScene, measurement: RoomMeasurement) {
            let points = measurement.walls.flatMap { [$0.start, $0.end] }
            let centerX = points.isEmpty ? 0 : points.map(\.x).reduce(0, +) / Double(points.count)
            let centerZ = points.isEmpty ? 0 : points.map(\.y).reduce(0, +) / Double(points.count)
            let span = max(
                points.map { abs($0.x - centerX) }.max() ?? 2,
                points.map { abs($0.y - centerZ) }.max() ?? 2,
                2
            )

            let cameraNode = SCNNode()
            cameraNode.name = "viewer-camera"
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.zNear = 0.01
            cameraNode.camera?.zFar = 1_000
            cameraNode.simdPosition = SIMD3(Float(centerX + span * 1.7), Float(span * 1.2), Float(centerZ + span * 1.7))
            cameraNode.look(at: SCNVector3(Float(centerX), Float(measurement.averageWallHeight / 2), Float(centerZ)))
            scene.rootNode.addChildNode(cameraNode)
        }
    }
}
