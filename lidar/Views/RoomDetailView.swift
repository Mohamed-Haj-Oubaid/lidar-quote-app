import SwiftUI
import SwiftData
import QuickLook

struct RoomDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var survey: Survey

    /// Edited copy of the name; written back (with one outbox entry) only on commit.
    @State private var name = ""
    @State private var nameError: String?
    @FocusState private var isNameFocused: Bool
    /// Set to the USDZ file to present it in the system 3D viewer (Quick Look).
    @State private var modelPreviewURL: URL?
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
                    Text("Geometry only – no camera images are stored.")
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
        .quickLookPreview($modelPreviewURL)
        .alert("3D model not found", isPresented: $modelMissing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The model file is not on this device.")
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
        guard let fileName = survey.usdzFileName,
              let url = try? SurveyEngine.mediaURL(for: fileName),
              FileManager.default.fileExists(atPath: url.path) else {
            modelMissing = true
            return
        }
        modelPreviewURL = url
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
