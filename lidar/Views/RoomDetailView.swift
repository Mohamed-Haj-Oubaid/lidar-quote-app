import SwiftUI
import SwiftData
import SceneKit

struct RoomDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var survey: Survey

    /// Edited copy of the name; written back (with one outbox entry) only on commit.
    @State private var name = ""
    @State private var nameError: String?
    @FocusState private var isNameFocused: Bool
    /// Selected local model presented in the interactive measurement viewer.
    @State private var modelViewerItem: RoomModelViewerItem?
    @State private var depthMeasurementOpeningID: UUID?
    @State private var pendingWindowDepth: Double?
    @State private var isChoosingWindowDepthScope = false
    @State private var modelMissing = false
    @State private var isRescanning = false
    @State private var isConfirmingDelete = false
    /// Set once the room is deleted, so leaving the screen doesn't save it again.
    @State private var isDeleted = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let m = survey.measurement
        List {
            Section("Room") {
                TextField("Name", text: $name)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit(commitName)
                if let nameError {
                    Text(nameError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LabeledContent("Source", value: m.source == .roomPlan ? String(localized: "LiDAR scan") : String(localized: "Manual entry"))
                if m.manuallyAdjusted {
                    Label("Manually adjusted", systemImage: "pencil.and.ruler")
                        .foregroundStyle(.orange)
                }
            }

            Section("Dimensions") {
                LabeledContent("Floor area", value: Formatters.meters(m.floorArea, suffix: "m²"))
                LabeledContent("Perimeter", value: Formatters.meters(m.perimeter))
                LabeledContent("Average wall height", value: Formatters.meters(m.averageWallHeight))
                LabeledContent("Wall area (gross)", value: Formatters.meters(m.grossWallArea, suffix: "m²"))
                LabeledContent("Openings", value: Formatters.meters(m.totalOpeningArea, suffix: "m²"))
                LabeledContent("Wall area (net, all openings)", value: Formatters.meters(max(0, m.grossWallArea - m.totalOpeningArea), suffix: "m²"))
                LabeledContent("Doors / windows", value: "\(m.doorCount) / \(m.windowCount)")
            }

            Section("Walls, doors and windows") {
                ForEach(Array(m.walls.enumerated()), id: \.element.id) { index, wall in
                    WallDetailCard(
                        number: index + 1,
                        wallID: wall.id,
                        survey: survey,
                        onMeasureWindowDepth: openModelForWindowDepth
                    )
                }

                let unassignedOpenings = m.openings.filter { opening in
                    opening.wallID == nil || !m.walls.contains(where: { $0.id == opening.wallID })
                }
                if !unassignedOpenings.isEmpty {
                    UnassignedOpeningsCard(openings: unassignedOpenings)
                }
            }

            Section {
                NavigationLink {
                    PlanEditorView(survey: survey)
                } label: {
                    Label("Edit Floor Plan", systemImage: "square.on.square.dashed")
                }
                NavigationLink {
                    MaterialSelectionView(survey: survey)
                } label: {
                    Label("Services & Materials (\(survey.selections.count))", systemImage: "paintbrush")
                }
            }

            if survey.usdzFileName != nil {
                Section {
                    Button(action: openModel) {
                        Label("View 3D Model", systemImage: "cube.transparent")
                    }
                    Label(survey.mediaUploaded ? String(localized: "3D model uploaded") : String(localized: "3D model stored on this device"),
                          systemImage: survey.mediaUploaded ? "icloud" : "iphone")
                } footer: {
                    Text("Interactive mesh plus a local-only Photo mode built from camera color and LiDAR depth. Wall and opening measurements remain visible in every mode.")
                }
            }

            Section {
                if let job = survey.job {
                    Button("Rescan Room", systemImage: "arrow.triangle.2.circlepath.camera") { isRescanning = true }
                        .disabled(job.privacyNoticeConfirmedAt == nil || !SurveyEngine.isScanningSupported)
                }
                Button("Delete Room", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
            } footer: {
                Text("Rescanning replaces the measurements and 3D model. Name and selected services stay.")
            }
        }
        .navigationTitle(survey.roomName)
        .fullScreenCover(item: $modelViewerItem) { item in
            RoomModelViewer(
                modelURL: item.url,
                photoPointCloudURL: item.photoPointCloudURL,
                wallTextureURLs: item.wallTextureURLs,
                roomName: survey.roomName,
                measurement: survey.measurement,
                startsInMeasurementMode: depthMeasurementOpeningID != nil,
                measurementSaveTitle: depthMeasurementOpeningID == nil ? nil : "Save as window depth",
                onSaveMeasurement: saveMeasuredWindowDepth
            )
        }
        .onChange(of: modelViewerItem?.id) { _, itemID in
            if itemID == nil, pendingWindowDepth != nil {
                isChoosingWindowDepthScope = true
            }
        }
        .alert("3D model not found", isPresented: $modelMissing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The model file is not on this device.")
        }
        .confirmationDialog(
            "Where should this measured depth be saved?",
            isPresented: $isChoosingWindowDepthScope,
            titleVisibility: .visible
        ) {
            Button("Only this window") { applyPendingWindowDepth(to: .selectedWindow) }
            Button("All windows on this wall") { applyPendingWindowDepth(to: .windowsOnWall) }
            Button("All windows in this room") { applyPendingWindowDepth(to: .allWindows) }
            Button("Cancel", role: .cancel) { clearPendingWindowDepth() }
        } message: {
            if let pendingWindowDepth {
                Text("Measured depth: \(pendingWindowDepth, format: .number.precision(.fractionLength(2))) m")
            }
        }
        .confirmationDialog("Delete \(survey.roomName)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Room", role: .destructive, action: deleteRoom)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Measurements, selected services and the 3D model of this room are deleted. Issued quotes are not changed.")
        }
        .fullScreenCover(isPresented: $isRescanning) {
            if let job = survey.job {
                ScanRoomView(job: job, replacing: survey)
            }
        }
        .onAppear { name = survey.roomName }
        .onChange(of: isNameFocused) { _, focused in
            if !focused { commitName() }
        }
        .onDisappear(perform: commitName)
    }

    private func openModel() {
        openModel(measuringDepthFor: nil)
    }

    private func openModelForWindowDepth(_ openingID: UUID) {
        openModel(measuringDepthFor: openingID)
    }

    private func openModel(measuringDepthFor openingID: UUID?) {
        guard let fileName = survey.usdzFileName,
              let url = try? SurveyEngine.mediaURL(for: fileName),
              FileManager.default.fileExists(atPath: url.path) else {
            modelMissing = true
            return
        }
        depthMeasurementOpeningID = openingID
        let photoURL = survey.photoPointCloudFileName
            .flatMap { try? SurveyEngine.mediaURL(for: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let wallTextureURLs: [URL] = survey.wallTextureFileNames.compactMap { fileName -> URL? in
            guard let url = try? SurveyEngine.mediaURL(for: fileName),
                  FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return url
        }
        modelViewerItem = RoomModelViewerItem(
            url: url,
            photoPointCloudURL: photoURL,
            wallTextureURLs: wallTextureURLs
        )
    }

    private func saveMeasuredWindowDepth(_ depth: Double) {
        guard depthMeasurementOpeningID != nil else { return }
        pendingWindowDepth = depth
    }

    private func applyPendingWindowDepth(to scope: WindowDepthSaveScope) {
        guard let depth = pendingWindowDepth,
              let selectedID = depthMeasurementOpeningID,
              let selected = survey.measurement.openings.first(where: { $0.id == selectedID }) else {
            clearPendingWindowDepth()
            return
        }

        for index in survey.measurement.openings.indices {
            let opening = survey.measurement.openings[index]
            guard opening.kind == .window else { continue }
            let shouldUpdate = switch scope {
            case .selectedWindow:
                opening.id == selectedID
            case .windowsOnWall:
                opening.wallID == selected.wallID
            case .allWindows:
                true
            }
            if shouldUpdate {
                survey.measurement.openings[index].depth = depth
            }
        }
        survey.measurement.manuallyAdjusted = true
        try? LocalStore.save(survey: survey, in: modelContext)
        clearPendingWindowDepth()
    }

    private func clearPendingWindowDepth() {
        pendingWindowDepth = nil
        depthMeasurementOpeningID = nil
    }

    /// Leaves the screen first, then deletes – so this view never renders a deleted room.
    private func deleteRoom() {
        isDeleted = true
        let survey = survey
        let context = modelContext
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            try? LocalStore.delete(survey: survey, in: context)
        }
    }

    private func commitName() {
        guard !isDeleted else { return }
        do {
            try LocalStore.rename(survey: survey, to: name, in: modelContext)
            nameError = nil
            name = survey.roomName
        } catch {
            nameError = error.localizedDescription
        }
    }
}

private enum WindowDepthSaveScope {
    case selectedWindow
    case windowsOnWall
    case allWindows
}

private struct WallDetailCard: View {
    let number: Int
    let wallID: UUID
    @Bindable var survey: Survey
    let onMeasureWindowDepth: (UUID) -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var isExpanded = false

    private var wall: WallSegment? {
        survey.measurement.walls.first { $0.id == wallID }
    }

    private var openings: [RoomOpening] {
        survey.measurement.openings.filter { $0.wallID == wallID }
    }

    private var openingArea: Double {
        openings.reduce(0) { $0 + $1.area }
    }

    var body: some View {
        if let wall {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Wall name", text: wallNameBinding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                LabeledContent("Length", value: Formatters.meters(wall.length))
                LabeledContent("Height", value: Formatters.meters(wall.height))
                LabeledContent("Gross area", value: Formatters.meters(wall.grossArea, suffix: "m²"))
                LabeledContent("Openings area", value: Formatters.meters(openingArea, suffix: "m²"))
                LabeledContent("Net area", value: Formatters.meters(max(0, wall.grossArea - openingArea), suffix: "m²"))

                if openings.isEmpty {
                    Text("No doors or windows on this wall")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Divider()
                    ForEach(Array(openings.enumerated()), id: \.element.id) { index, opening in
                        OpeningDetailRow(
                            number: index + 1,
                            opening: opening,
                            name: openingNameBinding(opening.id),
                            depthMeters: openingDepthBinding(opening.id),
                            onRescan: { replacement in
                                guard let openingIndex = survey.measurement.openings.firstIndex(where: { $0.id == opening.id }) else { return }
                                survey.measurement.openings[openingIndex].width = replacement.width
                                survey.measurement.openings[openingIndex].height = replacement.height
                                survey.measurement.openings[openingIndex].depth = replacement.depth
                                survey.measurement.openings[openingIndex].centerHeight = replacement.centerHeight
                                save()
                            },
                            onDepthCommit: {
                                survey.measurement.manuallyAdjusted = true
                                save()
                            },
                            onMeasureWindowDepth: { onMeasureWindowDepth(opening.id) },
                            onCommit: save
                        )
                        if index < openings.count - 1 { Divider() }
                    }
                }
                NavigationLink {
                    WallOnly3DViewer(
                        title: wall.name?.nonEmpty ?? String(localized: "Wall \(number)"),
                        wall: wall,
                        openings: openings
                    )
                } label: {
                    Label("View this wall in 3D", systemImage: "cube.transparent")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label(wall.name?.nonEmpty ?? String(localized: "Wall \(number)"), systemImage: "rectangle.portrait")
                    .font(.headline)
                Spacer()
                Text(Formatters.meters(wall.length))
                    .foregroundStyle(.secondary)
            }
        }
        }
    }

    private var wallNameBinding: Binding<String> {
        Binding(
            get: { wall?.name ?? "" },
            set: { value in
                guard let index = survey.measurement.walls.firstIndex(where: { $0.id == wallID }) else { return }
                survey.measurement.walls[index].name = value.nonEmpty
            }
        )
    }

    private func openingNameBinding(_ openingID: UUID) -> Binding<String> {
        Binding(
            get: { survey.measurement.openings.first(where: { $0.id == openingID })?.name ?? "" },
            set: { value in
                guard let index = survey.measurement.openings.firstIndex(where: { $0.id == openingID }) else { return }
                survey.measurement.openings[index].name = value.nonEmpty
            }
        )
    }

    private func openingDepthBinding(_ openingID: UUID) -> Binding<Double> {
        Binding(
            get: { survey.measurement.openings.first(where: { $0.id == openingID })?.depth ?? 0 },
            set: { value in
                guard let index = survey.measurement.openings.firstIndex(where: { $0.id == openingID }) else { return }
                survey.measurement.openings[index].depth = max(0, value)
            }
        )
    }

    private func save() {
        try? LocalStore.save(survey: survey, in: modelContext)
    }
}

private struct OpeningDetailRow: View {
    let number: Int
    let opening: RoomOpening
    @Binding var name: String
    @Binding var depthMeters: Double
    let onRescan: (RoomOpening) -> Void
    let onDepthCommit: () -> Void
    let onMeasureWindowDepth: () -> Void
    let onCommit: () -> Void
    @State private var isMeasuringDepth = false

    private var icon: String {
        switch opening.kind {
        case .door: "door.left.hand.open"
        case .window: "window.vertical.open"
        case .opening: "rectangle.dashed"
        }
    }

    private var rescanTitle: LocalizedStringResource {
        switch opening.kind {
        case .door: "Rescan Door"
        case .window: "Rescan Window"
        case .opening: "Rescan Opening"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name.nonEmpty ?? "\(opening.kind.title) \(number)", systemImage: icon)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCommit)
            LabeledContent("Width", value: Formatters.meters(opening.width))
            LabeledContent("Height", value: Formatters.meters(opening.height))
            LabeledContent("Area", value: Formatters.meters(opening.area, suffix: "m²"))
            if opening.kind == .window {
                HStack(spacing: 12) {
                    Text("Manual depth")
                    Spacer(minLength: 12)
                    HStack(spacing: 5) {
                    TextField(
                        "Depth",
                        value: $depthMeters,
                        format: .number.precision(.fractionLength(0...3))
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("m")
                        .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                Button("Save manual depth", systemImage: "square.and.arrow.down") {
                    onDepthCommit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(depthMeters < 0.01 || depthMeters > 1)
            }
            Button(
                opening.kind == .window ? "Measure Window Depth" : rescanTitle,
                systemImage: opening.kind == .window ? "ruler" : "arrow.triangle.2.circlepath.camera"
            ) {
                if opening.kind == .window {
                    onMeasureWindowDepth()
                } else {
                    isMeasuringDepth = true
                }
            }
            .buttonStyle(.bordered)
            if let centerHeight = opening.centerHeight {
                LabeledContent("Center height", value: Formatters.meters(centerHeight))
            }
            if let centerOffset = opening.centerOffset {
                LabeledContent("Position from wall start", value: Formatters.meters(centerOffset))
            }
            LabeledContent("Reveal length", value: Formatters.meters(opening.revealLength))
        }
        .fullScreenCover(isPresented: $isMeasuringDepth) {
            OpeningRescanView(
                opening: opening,
                onSave: onRescan
            )
        }
    }
}

private struct UnassignedOpeningsCard: View {
    let openings: [RoomOpening]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Unassigned openings (\(openings.count))", isExpanded: $isExpanded) {
            ForEach(Array(openings.enumerated()), id: \.element.id) { index, opening in
                VStack(alignment: .leading) {
                    Text(opening.name?.nonEmpty ?? "\(opening.kind.title) \(index + 1)")
                        .font(.headline)
                    LabeledContent("Width", value: Formatters.meters(opening.width))
                    LabeledContent("Height", value: Formatters.meters(opening.height))
                }.padding(.top, 8)
            }
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct WallOnly3DViewer: View {
    let title: String
    let wall: WallSegment
    let openings: [RoomOpening]

    var body: some View {
        ZStack(alignment: .top) {
            WallOnlySceneView(wall: wall, openings: openings)
                .ignoresSafeArea(edges: .bottom)
            Wall3DSummaryPanel(title: title, wall: wall, openings: openings)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Wall3DSummaryPanel: View {
    let title: String
    let wall: WallSegment
    let openings: [RoomOpening]

    private var openingArea: Double { openings.reduce(0) { $0 + $1.area } }
    private var doorCount: Int { openings.filter { $0.kind == .door }.count }
    private var windowCount: Int { openings.filter { $0.kind == .window }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: "rectangle.portrait")
                .font(.headline)
            HStack(spacing: 16) {
                DetailValue(title: "Length", value: Formatters.meters(wall.length))
                DetailValue(title: "Height", value: Formatters.meters(wall.height))
                DetailValue(title: "Gross", value: Formatters.meters(wall.grossArea, suffix: "m²"))
                DetailValue(title: "Net", value: Formatters.meters(max(0, wall.grossArea - openingArea), suffix: "m²"))
            }
            HStack(spacing: 16) {
                Label("\(doorCount) doors", systemImage: "door.left.hand.open")
                    .foregroundStyle(.orange)
                Label("\(windowCount) windows", systemImage: "window.vertical.open")
                    .foregroundStyle(.cyan)
                Text("Openings: \(Formatters.meters(openingArea, suffix: "m²"))")
            }
            .font(.caption)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
    }
}

private struct DetailValue: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit()).bold()
        }
    }
}

private struct WallOnlySceneView: UIViewRepresentable {
    let wall: WallSegment
    let openings: [RoomOpening]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .secondarySystemBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.scene = makeScene()
        view.pointOfView = view.scene?.rootNode.childNode(withName: "wall-camera", recursively: true)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.scene = makeScene()
        view.pointOfView = view.scene?.rootNode.childNode(withName: "wall-camera", recursively: true)
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let wallBox = SCNBox(
            width: CGFloat(max(wall.length, 0.01)),
            height: CGFloat(max(wall.height, 0.01)),
            length: 0.08,
            chamferRadius: 0.01
        )
        let wallMaterial = SCNMaterial()
        wallMaterial.diffuse.contents = UIColor.systemGray5
        wallMaterial.roughness.contents = 0.9
        wallMaterial.isDoubleSided = true
        wallBox.materials = [wallMaterial]
        let wallNode = SCNNode(geometry: wallBox)
        wallNode.simdPosition = SIMD3<Float>(0, Float(wall.height / 2), 0)
        scene.rootNode.addChildNode(wallNode)

        for (index, opening) in openings.enumerated() {
            let color: UIColor = switch opening.kind {
            case .door: .systemOrange
            case .window: .systemCyan
            case .opening: .systemPurple
            }
            let box = SCNBox(
                width: CGFloat(max(opening.width, 0.01)),
                height: CGFloat(max(opening.height, 0.01)),
                length: 0.12,
                chamferRadius: 0.01
            )
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color.withAlphaComponent(0.3)
            material.emission.contents = color.withAlphaComponent(0.75)
            material.fillMode = .lines
            material.isDoubleSided = true
            box.materials = [material]
            let node = SCNNode(geometry: box)
            let center = opening.centerOffset ?? wall.length / 2
            let x = center - wall.length / 2
            let y = opening.centerHeight ?? (opening.kind == .door ? opening.height / 2 : 1.1)
            node.simdPosition = SIMD3<Float>(Float(x), Float(y), 0.07)
            scene.rootNode.addChildNode(node)

            let text = SCNText(
                string: opening.name?.nonEmpty ?? "\(opening.kind.title) \(index + 1)",
                extrusionDepth: 0.002
            )
            text.font = .preferredFont(forTextStyle: .caption1)
            text.firstMaterial?.diffuse.contents = color
            text.firstMaterial?.emission.contents = color
            let label = SCNNode(geometry: text)
            label.scale = SCNVector3(0.006, 0.006, 0.006)
            label.simdPosition = SIMD3<Float>(Float(x - opening.width / 2), Float(y + opening.height / 2 + 0.08), 0.1)
            scene.rootNode.addChildNode(label)
        }

        let camera = SCNNode()
        camera.name = "wall-camera"
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.simdPosition = SIMD3<Float>(0, Float(wall.height * 0.55), Float(max(wall.length, wall.height) * 1.35))
        camera.look(at: SCNVector3(0, Float(wall.height / 2), 0))
        scene.rootNode.addChildNode(camera)
        return scene
    }
}

// MARK: - 2D plan editor

struct PlanEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let survey: Survey

    @State private var measurement = RoomMeasurement.empty
    @State private var selectedWallID: UUID?
    @State private var overridesFloorArea = false
    @State private var floorWarning: String?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let geometry = PlanGeometry(measurement: measurement, size: proxy.size)
                Canvas { context, _ in
                    draw(in: &context, geometry: geometry)
                }
                .contentShape(.rect)
                .gesture(SpatialTapGesture().onEnded { value in
                    let point = geometry.planPoint(for: value.location)
                    let wall = SurveyEngine.nearestWall(to: point, in: measurement.walls)
                    if let wall, SurveyEngine.distance(from: point, to: wall) * geometry.scale < 30 {
                        selectedWallID = wall.id
                    } else {
                        selectedWallID = nil
                    }
                })
                .accessibilityLabel("Floor plan")
                .accessibilityHint("Tap a wall to edit it")
            }
            .frame(minHeight: 260)
            .background(Color(.secondarySystemBackground))

            Form {
                if survey.measurement.source == .manual, let size = measurement.rectangleSize {
                    Section("Rectangular room") {
                        MeterField(title: "Width", value: Binding(
                            get: { size.width },
                            set: { measurement = measurement.resizedRectangle(width: $0, depth: size.depth) }
                        ))
                        MeterField(title: "Depth", value: Binding(
                            get: { size.depth },
                            set: { measurement = measurement.resizedRectangle(width: size.width, depth: $0) }
                        ))
                    }
                }
                if let index = measurement.walls.firstIndex(where: { $0.id == selectedWallID }) {
                    wallEditor(index: index)
                } else {
                    Section {
                        Text("Tap a wall in the plan to edit its length, height and openings.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Floor") {
                    if let floorWarning {
                        Label(floorWarning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Calculated area", value: Formatters.meters(measurement.floorArea, suffix: "m²"))
                    Toggle("Override floor area", isOn: $overridesFloorArea)
                    if overridesFloorArea {
                        MeterField(title: "Floor area (m²)", value: Binding(
                            get: { measurement.floorAreaOverride ?? measurement.floorArea },
                            set: { measurement.floorAreaOverride = $0 }
                        ))
                    }
                }
            }
        }
        .navigationTitle("Floor Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onAppear {
            measurement = survey.measurement
            overridesFloorArea = measurement.floorAreaOverride != nil
        }
        .onChange(of: overridesFloorArea) { _, overrides in
            if !overrides { measurement.floorAreaOverride = nil }
        }
    }

    @ViewBuilder
    private func wallEditor(index: Int) -> some View {
        let wallID = measurement.walls[index].id
        Section("Wall") {
            MeterField(title: "Length", value: Binding(
                get: { measurement.walls[index].length },
                set: { setLength($0, ofWallAt: index) }
            ))
            MeterField(title: "Height", value: $measurement.walls[index].height)
        }
        Section("Openings in this wall") {
            ForEach($measurement.openings) { $opening in
                if opening.wallID == wallID {
                    VStack(alignment: .leading) {
                        Picker("Type", selection: $opening.kind) {
                            ForEach(RoomOpening.Kind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        MeterField(title: "Width", value: $opening.width)
                        MeterField(title: "Height", value: $opening.height)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            measurement.openings.removeAll { $0.id == opening.id }
                        }
                    }
                }
            }
            Button("Add Opening", systemImage: "plus") {
                let wall = measurement.walls[index]
                measurement.openings.append(RoomOpening(id: UUID(), kind: .window, width: 1.2, height: 1.3,
                                                        wallID: wall.id, centerOffset: wall.length / 2))
            }
        }
    }

    /// Changes a wall's length and keeps connected walls and the floor consistent.
    private func setLength(_ newLength: Double, ofWallAt index: Int) {
        let edit = measurement.settingLength(newLength, ofWall: measurement.walls[index].id)
        measurement = edit.measurement
        if edit.floorRecalculated {
            floorWarning = nil
        } else {
            floorWarning = String(localized: "Floor area could not be recalculated – please enter it manually.")
            overridesFloorArea = true
        }
    }

    private func save() {
        measurement.manuallyAdjusted = true
        survey.measurement = measurement
        try? LocalStore.save(survey: survey, in: modelContext)
        dismiss()
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, geometry: PlanGeometry) {
        if measurement.floorPolygon.count >= 3 {
            var floor = Path()
            floor.addLines(measurement.floorPolygon.map(geometry.viewPoint))
            floor.closeSubpath()
            context.fill(floor, with: .color(.accentColor.opacity(0.08)))
        }

        for wall in measurement.walls {
            var path = Path()
            path.move(to: geometry.viewPoint(wall.start))
            path.addLine(to: geometry.viewPoint(wall.end))
            let isSelected = wall.id == selectedWallID
            context.stroke(path, with: .color(isSelected ? .accentColor : .primary), lineWidth: isSelected ? 6 : 4)

            let mid = geometry.viewPoint(PlanPoint(x: (wall.start.x + wall.end.x) / 2, y: (wall.start.y + wall.end.y) / 2))
            context.draw(Text(Formatters.meters(wall.length)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: mid.x, y: mid.y - 10))
        }

        for opening in measurement.openings {
            guard let wall = measurement.walls.first(where: { $0.id == opening.wallID }), wall.length > 0 else { continue }
            let center = opening.centerOffset ?? wall.length / 2
            let from = max(0, center - opening.width / 2) / wall.length
            let to = min(wall.length, center + opening.width / 2) / wall.length
            func point(_ t: Double) -> CGPoint {
                geometry.viewPoint(PlanPoint(x: wall.start.x + (wall.end.x - wall.start.x) * t,
                                             y: wall.start.y + (wall.end.y - wall.start.y) * t))
            }
            var path = Path()
            path.move(to: point(from))
            path.addLine(to: point(to))
            context.stroke(path, with: .color(opening.kind == .window ? .blue : .orange), lineWidth: 8)
        }
    }
}

/// Maps plan coordinates (metres) to view coordinates, fitting the room into the view.
private struct PlanGeometry {
    var minX = 0.0
    var minY = 0.0
    var scale = 1.0
    var offset = CGPoint.zero

    init(measurement: RoomMeasurement, size: CGSize) {
        let points = measurement.walls.flatMap { [$0.start, $0.end] } + measurement.floorPolygon
        guard let first = points.first else { return }
        var maxX = first.x, maxY = first.y
        minX = first.x
        minY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let padding = 32.0
        let width = max(maxX - minX, 0.1)
        let height = max(maxY - minY, 0.1)
        scale = min((size.width - 2 * padding) / width, (size.height - 2 * padding) / height)
        offset = CGPoint(x: (size.width - width * scale) / 2, y: (size.height - height * scale) / 2)
    }

    func viewPoint(_ p: PlanPoint) -> CGPoint {
        CGPoint(x: offset.x + (p.x - minX) * scale, y: offset.y + (p.y - minY) * scale)
    }

    func planPoint(for point: CGPoint) -> PlanPoint {
        PlanPoint(x: (point.x - offset.x) / scale + minX, y: (point.y - offset.y) / scale + minY)
    }
}

// MARK: - Material selection

struct MaterialSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var survey: Survey
    @Query(filter: #Predicate<PriceBookVersion> { $0.isActive }, sort: \PriceBookVersion.version, order: .reverse)
    private var priceBooks: [PriceBookVersion]

    private static let wasteOptions = [0, 5, 10, 15]

    var body: some View {
        let measurement = survey.measurement
        List {
            if let book = priceBooks.first {
                Section {
                    ForEach(book.items) { item in
                        row(for: item, measurement: measurement)
                    }
                } header: {
                    Text("\(book.name) · v\(book.version)")
                } footer: {
                    if book.isLocalSample {
                        Text("Sample price book. Your firm's price book replaces it after the first sync.")
                    }
                }
            } else {
                ContentUnavailableView("No Price Book", systemImage: "list.bullet.rectangle",
                                       description: Text("Sync to download your firm's price book."))
            }
        }
        .navigationTitle("Services & Materials")
    }

    private func row(for item: PriceItem, measurement: RoomMeasurement) -> some View {
        let selection = survey.selections.first { $0.itemID == item.id }
        let (quantity, note) = EstimationEngine.quantity(for: item, in: measurement)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { selection != nil },
                set: { isOn in update(item: item, selected: isOn, waste: item.defaultWastePercent) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text("\(Formatters.money(item.unitPriceCents)) / \(item.unit.symbol) · \(item.basis.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Formatters.quantity(EstimationEngine.hundredths(quantity), unit: item.unit))\(note.map { " · \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let selection {
                Picker("Waste", selection: Binding(
                    get: { selection.wastePercent },
                    set: { update(item: item, selected: true, waste: $0) }
                )) {
                    ForEach(Self.wasteOptions, id: \.self) { option in
                        Text("+\(option) %").tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func update(item: PriceItem, selected: Bool, waste: Int) {
        var selections = survey.selections.filter { $0.itemID != item.id }
        if selected {
            selections.append(ItemSelection(itemID: item.id, wastePercent: waste))
        }
        survey.selections = selections
        try? LocalStore.save(survey: survey, in: modelContext)
    }
}
