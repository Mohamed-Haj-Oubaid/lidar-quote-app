import SwiftUI
import SwiftData

/// Which value the next laser-meter reading fills in.
enum MeasureTarget: Hashable {
    case length(UUID)
    case height(UUID)
    case roomHeight
    case openingWidth(UUID, UUID)
    case openingHeight(UUID, UUID)
    case openingDepth(UUID, UUID)
}

/// Draw the floor outline by hand, then tap each wall and measure it with a
/// Bluetooth laser meter (Bosch GLM / Leica DISTO) or by typing the value.
struct SketchRoomView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let job: Job

    @State private var stroke: [CGPoint] = []
    @State private var sketch: FloorSketch?
    @State private var drawHint: String?
    @State private var selectedWallID: UUID?
    @State private var target: MeasureTarget?
    @State private var laser = LaserMeterManager()
    @State private var isConnectingLaser = false
    @State private var roomName = ""
    @State private var nameError: String?
    @State private var isFacade = false

    var body: some View {
        VStack(spacing: 0) {
            if let sketch {
                PlanCanvas(sketch: sketch, selectedWallID: selectedWallID) { wallID in
                    selectedWallID = wallID
                    if let wallID { target = .length(wallID) }
                }
                summary(sketch)
            } else {
                drawingCanvas
            }
        }
        .navigationTitle("Draw Floor Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { roomName = LocalStore.nextRoomName(for: job) }
        .onChange(of: isFacade) { _, facade in
            // Swap the suggested name only while the worker has not typed their own.
            let roomDefault = LocalStore.nextRoomName(for: job)
            let facadeDefault = LocalStore.nextFacadeName(for: job)
            if facade, roomName == roomDefault { roomName = facadeDefault }
            if !facade, roomName == facadeDefault { roomName = roomDefault }
        }
        .onDisappear { laser.disconnect() }
        .onChange(of: laser.lastReading) { _, reading in
            if let reading { apply(reading.meters) }
        }
        .sheet(isPresented: $isConnectingLaser) {
            NavigationStack { LaserConnectView(laser: laser) }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(
            get: { selectedWallID.map(SelectedWall.init) },
            set: { selectedWallID = $0?.id }
        )) { selection in
            if let binding = sketchBinding {
                NavigationStack {
                    WallMeasureSheet(
                        sketch: binding,
                        wallID: selection.id,
                        target: $target,
                        laser: laser,
                        onConnect: { isConnectingLaser = true }
                    )
                }
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
    }

    // MARK: Drawing

    private var drawingCanvas: some View {
        ZStack(alignment: .top) {
            Canvas { context, _ in
                guard stroke.count > 1 else { return }
                var path = Path()
                path.addLines(stroke)
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            .background(Color(.secondarySystemBackground))
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in stroke.append(value.location) }
                    .onEnded { _ in finishStroke() }
            )

            VStack(spacing: 8) {
                Picker("Type", selection: $isFacade) {
                    Label("Room", systemImage: "square.split.bottomrightquarter").tag(false)
                    Label("Facade", systemImage: "building.2").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Text(isFacade
                     ? LocalizedStringKey("Draw the outline of the building in one stroke. Each side becomes one facade wall.")
                     : LocalizedStringKey("Draw the outline of the room or floor in one stroke with your finger or Apple Pencil."))
                if let drawHint {
                    Text(drawHint).foregroundStyle(.red)
                }
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding()
        }
    }

    private func finishStroke() {
        let points = stroke.map { PlanPoint(x: Double($0.x), y: Double($0.y)) }
        if var result = FloorSketch.fromStroke(points) {
            result.isFacade = isFacade
            if isFacade { result.roomHeight = 6 }
            sketch = result
            drawHint = nil
        } else {
            drawHint = String(localized: "The drawing is too small. Draw a larger outline with at least three walls.")
        }
        stroke = []
    }

    // MARK: Summary & toolbar

    private func summary(_ sketch: FloorSketch) -> some View {
        let measurement = sketch.measurement()
        let measured = sketch.walls.filter { $0.measuredLength != nil }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Room name", text: $roomName)
                    .textFieldStyle(.roundedBorder)
                LaserStatusButton(laser: laser) { isConnectingLaser = true }
            }
            if let nameError {
                Text(nameError).font(.caption).foregroundStyle(.red)
            }
            MeasureRow(
                title: sketch.isFacade ? "Facade height" : "Room height",
                value: Binding(
                    get: { self.sketch?.roomHeight },
                    set: { if let value = $0 { self.sketch?.roomHeight = value } }
                ),
                isTarget: target == .roomHeight,
                laserConnected: laser.isConnected,
                onLaser: { toggle(.roomHeight) }
            )
            Group {
                if sketch.isFacade {
                    Text("Walls measured: \(measured) of \(sketch.walls.count) · Facade \(Formatters.meters(measurement.grossWallArea, suffix: "m²")) · Scaffold \(Formatters.meters(measurement.scaffoldArea, suffix: "m²"))")
                } else {
                    Text("Walls measured: \(measured) of \(sketch.walls.count) · Floor \(Formatters.meters(measurement.floorArea, suffix: "m²")) · Walls \(Formatters.meters(measurement.grossWallArea, suffix: "m²"))")
                }
            }
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Tap a wall to measure it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) { dismiss() }
        }
        if sketch != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button("Redraw", systemImage: "arrow.counterclockwise") {
                    sketch = nil
                    selectedWallID = nil
                    target = nil
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!(sketch?.allWallsMeasured ?? false))
            }
        }
    }

    // MARK: Laser readings

    private var sketchBinding: Binding<FloorSketch>? {
        guard sketch != nil else { return nil }
        return Binding(get: { sketch ?? FloorSketch(walls: []) }, set: { sketch = $0 })
    }

    private func toggle(_ newTarget: MeasureTarget) {
        if !laser.isConnected {
            isConnectingLaser = true
        }
        target = target == newTarget ? nil : newTarget
    }

    /// Writes a laser reading into the current target and moves on to the next value.
    private func apply(_ meters: Double) {
        guard var current = sketch, let target else { return }
        func wallIndex(_ id: UUID) -> Int? { current.walls.firstIndex { $0.id == id } }
        func openingIndex(_ wall: Int, _ id: UUID) -> Int? { current.walls[wall].openings.firstIndex { $0.id == id } }

        var next: MeasureTarget?
        switch target {
        case .length(let id):
            guard let w = wallIndex(id) else { return }
            current.walls[w].measuredLength = meters
            next = .height(id)
        case .height(let id):
            guard let w = wallIndex(id) else { return }
            current.walls[w].measuredHeight = meters
        case .roomHeight:
            current.roomHeight = meters
        case .openingWidth(let wallID, let id):
            guard let w = wallIndex(wallID), let o = openingIndex(w, id) else { return }
            current.walls[w].openings[o].width = meters
            next = .openingHeight(wallID, id)
        case .openingHeight(let wallID, let id):
            guard let w = wallIndex(wallID), let o = openingIndex(w, id) else { return }
            current.walls[w].openings[o].height = meters
            next = .openingDepth(wallID, id)
        case .openingDepth(let wallID, let id):
            guard let w = wallIndex(wallID), let o = openingIndex(w, id) else { return }
            current.walls[w].openings[o].depth = meters
        }
        sketch = current
        self.target = next
    }

    private func save() {
        guard let sketch else { return }
        let name: String
        do {
            name = try LocalStore.validatedRoomName(roomName, in: job)
        } catch {
            nameError = error.localizedDescription
            return
        }
        let survey = Survey(roomName: name, measurement: sketch.measurement(), job: job)
        modelContext.insert(survey)
        try? LocalStore.save(survey: survey, in: modelContext)
        dismiss()
    }
}

private struct SelectedWall: Identifiable {
    let id: UUID
}

// MARK: - Plan canvas

/// Shows the outline at its real (measured) proportions; tap a wall to select it.
private struct PlanCanvas: View {
    let sketch: FloorSketch
    let selectedWallID: UUID?
    let onSelect: (UUID?) -> Void

    var body: some View {
        GeometryReader { proxy in
            let points = screenPoints(in: proxy.size)
            ZStack {
                Color(.secondarySystemBackground)
                Canvas { context, _ in
                    guard points.count == sketch.walls.count, points.count > 1 else { return }
                    var floor = Path()
                    floor.addLines(points)
                    floor.closeSubpath()
                    context.fill(floor, with: .color(.accentColor.opacity(0.08)))
                    for (index, wall) in sketch.walls.enumerated() {
                        var line = Path()
                        line.move(to: points[index])
                        line.addLine(to: points[(index + 1) % points.count])
                        let color: Color = wall.id == selectedWallID ? .orange
                            : (wall.measuredLength == nil ? .red : .green)
                        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: wall.id == selectedWallID ? 8 : 5, lineCap: .round))
                    }
                    for point in points {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(.primary))
                    }
                }
                ForEach(Array(sketch.walls.enumerated()), id: \.element.id) { index, wall in
                    if points.count == sketch.walls.count {
                        let a = points[index]
                        let b = points[(index + 1) % points.count]
                        Text(label(for: wall, index: index))
                            .font(.caption.bold().monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: .capsule)
                            .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(.rect)
            .onTapGesture { location in
                onSelect(nearestWall(to: location, points: points))
            }
        }
    }

    private func label(for wall: FloorSketch.Wall, index: Int) -> String {
        let name = wall.name ?? String(localized: "Wall \(index + 1)")
        if let length = wall.measuredLength {
            return "\(name): \(Formatters.meters(length))"
        }
        return "\(name): ?"
    }

    /// Plan corners (metres) fitted into the view.
    private func screenPoints(in size: CGSize) -> [CGPoint] {
        let corners = sketch.corners()
        guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max() else { return [] }
        let padding = 60.0
        let width = max(maxX - minX, 0.01)
        let height = max(maxY - minY, 0.01)
        let scale = min((size.width - 2 * padding) / width, (size.height - 2 * padding) / height)
        let offsetX = (size.width - width * scale) / 2
        let offsetY = (size.height - height * scale) / 2
        return corners.map { CGPoint(x: offsetX + ($0.x - minX) * scale, y: offsetY + ($0.y - minY) * scale) }
    }

    private func nearestWall(to location: CGPoint, points: [CGPoint]) -> UUID? {
        guard points.count == sketch.walls.count else { return nil }
        var best: (id: UUID, distance: CGFloat)?
        for (index, wall) in sketch.walls.enumerated() {
            let d = distance(from: location, toSegment: points[index], points[(index + 1) % points.count])
            if d < 40, d < (best?.distance ?? .infinity) { best = (wall.id, d) }
        }
        return best?.id
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - Wall sheet

private struct WallMeasureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var sketch: FloorSketch
    let wallID: UUID
    @Binding var target: MeasureTarget?
    let laser: LaserMeterManager
    let onConnect: () -> Void

    private var wallIndex: Int? { sketch.walls.firstIndex { $0.id == wallID } }

    var body: some View {
        Form {
            if let index = wallIndex {
                let wall = $sketch.walls[index]
                Section {
                    TextField("Name", text: Binding(
                        get: { wall.wrappedValue.name ?? "" },
                        set: { wall.wrappedValue.name = $0.isEmpty ? nil : $0 }
                    ))
                    row("Length", wall.measuredLength, .length(wallID))
                    row("Height", wall.measuredHeight, .height(wallID))
                } footer: {
                    Text("Tap the laser button, then press the measure button on the device. Without height, the room height is used.")
                }

                Section("Doors & windows") {
                    ForEach(wall.openings) { $opening in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(opening.name ?? opening.kind.title).font(.headline)
                            row("Width", optional($opening.width), .openingWidth(wallID, opening.id))
                            row("Height", optional($opening.height), .openingHeight(wallID, opening.id))
                            row("Depth", $opening.depth, .openingDepth(wallID, opening.id))
                        }
                    }
                    .onDelete { wall.wrappedValue.openings.remove(atOffsets: $0) }

                    Button("Add Door", systemImage: "door.left.hand.closed") {
                        add(.door, width: 0.885, height: 2.01, to: index)
                    }
                    Button("Add Window", systemImage: "window.casement") {
                        add(.window, width: 1.2, height: 1.3, to: index)
                    }
                }
            }
        }
        .navigationTitle(sketch.walls.first { $0.id == wallID }?.name ?? String(localized: "Wall \((wallIndex ?? 0) + 1)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarLeading) {
                LaserStatusButton(laser: laser, action: onConnect)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: Binding<Double?>, _ field: MeasureTarget) -> some View {
        MeasureRow(title: title, value: value, isTarget: target == field, laserConnected: laser.isConnected) {
            if !laser.isConnected { onConnect() }
            target = target == field ? nil : field
        }
    }

    private func optional(_ value: Binding<Double>) -> Binding<Double?> {
        Binding(get: { value.wrappedValue }, set: { if let new = $0 { value.wrappedValue = new } })
    }

    private func add(_ kind: RoomOpening.Kind, width: Double, height: Double, to index: Int) {
        let opening = RoomOpening(id: UUID(), kind: kind, width: width, height: height, wallID: wallID, centerOffset: nil)
        sketch.walls[index].openings.append(opening)
        target = .openingWidth(wallID, opening.id)
    }
}

// MARK: - Shared rows

/// One measured value: typed in, or filled by the next laser reading when targeted.
private struct MeasureRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double?
    let isTarget: Bool
    let laserConnected: Bool
    let onLaser: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("m").foregroundStyle(.secondary)
                Button(action: onLaser) {
                    Image(systemName: isTarget ? "dot.radiowaves.left.and.right" : "ruler")
                        .symbolEffect(.pulse, isActive: isTarget && laserConnected)
                }
                .buttonStyle(.bordered)
                .tint(isTarget ? .orange : .accentColor)
                .accessibilityLabel(isTarget ? Text("Waiting for laser meter") : Text("Measure with laser meter"))
            }
            .fixedSize()
        }
    }
}

private struct LaserStatusButton: View {
    let laser: LaserMeterManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(laser.isConnected ? "Laser" : "Connect Laser",
                  systemImage: laser.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
        }
        .buttonStyle(.bordered)
        .tint(laser.isConnected ? .green : .accentColor)
    }
}

// MARK: - Connect

struct LaserConnectView: View {
    @Environment(\.dismiss) private var dismiss
    let laser: LaserMeterManager

    var body: some View {
        List {
            Section {
                switch laser.state {
                case .bluetoothOff:
                    Label("Bluetooth is off. Turn it on in Control Center.", systemImage: "exclamationmark.triangle")
                case .unauthorized:
                    Label("Bluetooth access denied. Allow it in Settings.", systemImage: "exclamationmark.triangle")
                case .connected(let name):
                    Label("Connected: \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Disconnect", role: .destructive) { laser.disconnect() }
                case .connecting(let name):
                    Label("Connecting to \(name)…", systemImage: "hourglass")
                case .scanning, .idle:
                    if laser.discovered.isEmpty {
                        Label("Searching… Switch the laser meter on and enable its Bluetooth.", systemImage: "magnifyingglass")
                    }
                }
            } footer: {
                Text("Supported: Bosch GLM (e.g. GLM 50 C, 100 C, 120 C) and Leica DISTO with Bluetooth.")
            }

            if !laser.isConnected, !laser.discovered.isEmpty {
                Section("Devices") {
                    ForEach(laser.discovered.sorted { $0.value < $1.value }, id: \.key) { id, name in
                        Button(name) { laser.connect(to: id) }
                    }
                }
            }
        }
        .navigationTitle("Laser Meter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { if !laser.isConnected { laser.startScan() } }
        .onDisappear { laser.stopScan() }
        .onChange(of: laser.isConnected) { _, connected in
            if connected { dismiss() }
        }
    }
}
