import SwiftUI
import SwiftData
import RoomPlan

/// Full-screen LiDAR scan. RoomPlan's built-in coaching guides the worker while
/// walking the perimeter; on "Done" the result becomes a new room in the job –
/// or, when rescanning, replaces the geometry of an existing room.
struct ScanRoomView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let job: Job
    /// Room whose measurement and 3D model are replaced (name and selections stay).
    var replacing: Survey?

    private enum Phase: Equatable {
        case setup, scanning, processing, failed(String)
    }

    @State private var phase = Phase.setup
    @State private var captureMode = ScanCaptureMode.room
    @State private var roomName = ""
    @State private var scanCoverage = 0.0

    var body: some View {
        if phase == .setup {
            ScanModeSetupView(selection: $captureMode, onCancel: { dismiss() }) {
                scanCoverage = 0
                phase = .scanning
            }
        } else {
        ZStack(alignment: .bottom) {
            RoomCaptureRepresentable(
                isScanning: phase == .scanning,
                captureMode: captureMode,
                onCoverageChange: { scanCoverage = $0 },
                onFinish: handle
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                switch phase {
                case .setup:
                    EmptyView()
                case .scanning:
                    ScanCoveragePanel(coverage: scanCoverage)
                    Text("Move slowly and cover every wall, floor, ceiling, door, and window. Hold each surface in view so LiDAR can capture its shape and real color.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    HStack {
                        Button("Cancel", role: .cancel) { dismiss() }
                            .buttonStyle(.bordered)
                        Button("Done") { phase = .processing }
                            .buttonStyle(.borderedProminent)
                            .disabled(scanCoverage < 0.8)
                    }
                case .processing:
                    ProgressView("Processing scan…")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                case .failed(let message):
                    VStack(spacing: 8) {
                        Text("Scan failed")
                            .font(.headline)
                        Text(message)
                            .font(.footnote)
                        Button("Close") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .padding()
        }
        .onAppear {
            roomName = LocalStore.nextRoomName(for: job)
        }
        }
    }

    private func handle(_ result: Result<RoomCaptureOutput, Error>) {
        switch result {
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        case .success(let output):
            save(output, wallPhotos: [])
        }
    }

    private func save(_ output: RoomCaptureOutput, wallPhotos: [Data]) {
        let room = output.room
        if let survey = replacing {
            saveRescan(survey, output: output, wallPhotos: wallPhotos)
            return
        }

        let name = LocalStore.isRoomName(roomName, takenIn: job)
            ? LocalStore.nextRoomName(for: job)
            : roomName
        let survey = Survey(
            roomName: name,
            measurement: SurveyEngine.measurement(from: room, coloredSurface: output.coloredSurface),
            job: job
        )
        modelContext.insert(survey)
        storeMedia(output, wallPhotos: wallPhotos, for: survey)
        persist(survey)
    }

    private func saveRescan(_ survey: Survey, output: RoomCaptureOutput, wallPhotos: [Data]) {
        survey.measurement = SurveyEngine.measurement(
            from: output.room,
            coloredSurface: output.coloredSurface
        )
        survey.capturedAt = .now
        storeMedia(output, wallPhotos: wallPhotos, for: survey)
        survey.mediaUploaded = false
        survey.mediaUploadAttempts = 0
        survey.mediaNextAttemptAt = nil
        persist(survey)
    }

    private func storeMedia(_ output: RoomCaptureOutput, wallPhotos: [Data], for survey: Survey) {
        survey.usdzFileName = try? SurveyEngine.storeModel(output.room, surveyID: survey.id)
        let processedMesh = RoomMeshPostProcessor.process(
            coloredSurface: output.coloredSurface,
            texturedSurface: output.texturedSurface,
            measurement: survey.measurement
        )
        survey.photoPointCloudFileName = try? PhotoPointCloudStore.store(
            coloredSurface: processedMesh.coloredSurface,
            texturedSurface: processedMesh.texturedSurface,
            surveyID: survey.id
        )
        survey.wallTextureFileNames = (try? SurveyEngine.storeWallTextures(
            wallPhotos,
            surveyID: survey.id
        )) ?? []
    }

    private func persist(_ survey: Survey) {
        do {
            try LocalStore.save(survey: survey, in: modelContext)
            dismiss()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct ScanModeSetupView: View {
    @Binding var selection: ScanCaptureMode
    let onCancel: () -> Void
    let onStart: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose scan mode").font(.largeTitle.bold())
                    Text("Higher quality modes capture more points and photos. Move slowly for the best result.")
                        .foregroundStyle(.secondary)
                    ForEach(ScanCaptureMode.allCases) { mode in
                        Button { selection = mode } label: {
                            HStack(spacing: 16) {
                                Image(systemName: mode.systemImage).font(.title).frame(width: 44)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(mode.title).font(.headline)
                                    Text(mode.subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(selection == mode ? .blue : .secondary)
                            }
                            .padding()
                            .background(.background, in: .rect(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).stroke(selection == mode ? Color.blue : .secondary.opacity(0.2), lineWidth: selection == mode ? 2 : 1) }
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: onStart) {
                        Label("Start Scan", systemImage: "viewfinder.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
                .frame(maxWidth: 720, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel, action: onCancel) } }
        }
    }
}

private struct ScanCoveragePanel: View {
    let coverage: Double

    private var percentage: Int {
        Int((coverage * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scan coverage")
                    .font(.headline)
                Spacer()
                Text(coverage, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.monospacedDigit())
                    .bold()
            }
            Text(coverage >= 0.8
                 ? "Coverage is sufficient. Colored points show exactly what LiDAR captured."
                 : "Continue until at least 80%. Colored points show the surfaces already captured.")
                .font(.callout)
                .foregroundStyle(coverage >= 0.8 ? .green : .primary)
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(percentage) percent")
    }
}

/// Manual room entry for devices without LiDAR or when a scan is not possible.
struct ManualRoomView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let job: Job

    @State private var roomName = ""
    @State private var width = 4.0
    @State private var depth = 3.5
    @State private var height = 2.5
    @State private var doors = 1
    @State private var windows = 1
    @State private var nameError: String?

    var body: some View {
        Form {
            Section("Room") {
                TextField("Name", text: $roomName)
                if let nameError {
                    Text(nameError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                MeterField(title: "Width", value: $width)
                MeterField(title: "Depth", value: $depth)
                MeterField(title: "Ceiling height", value: $height)
            }
            Section {
                Stepper("Doors: \(doors)", value: $doors, in: 0...10)
                Stepper("Windows: \(windows)", value: $windows, in: 0...20)
            } footer: {
                Text("Standard sizes are used (door 0.885 × 2.01 m, window 1.20 × 1.30 m). Adjust them in the plan editor.")
            }
        }
        .navigationTitle("Add Room")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: add)
                    .disabled(width <= 0 || depth <= 0 || height <= 0)
            }
        }
        .onAppear {
            roomName = LocalStore.nextRoomName(for: job)
        }
    }

    private func add() {
        let name: String
        do {
            name = try LocalStore.validatedRoomName(roomName, in: job)
        } catch {
            nameError = error.localizedDescription
            return
        }
        var measurement = RoomMeasurement.rectangle(width: width, depth: depth, height: height)
        let walls = measurement.walls
        for index in 0..<doors {
            let wall = walls[index % walls.count]
            measurement.openings.append(RoomOpening(id: UUID(), kind: .door, width: 0.885, height: 2.01, wallID: wall.id, centerOffset: wall.length * 0.25))
        }
        for index in 0..<windows {
            let wall = walls[(index + 2) % walls.count]
            measurement.openings.append(RoomOpening(id: UUID(), kind: .window, width: 1.2, height: 1.3, wallID: wall.id, centerOffset: wall.length * 0.6))
        }
        let survey = Survey(roomName: name, measurement: measurement, job: job)
        modelContext.insert(survey)
        try? LocalStore.save(survey: survey, in: modelContext)
        dismiss()
    }
}

/// Numeric metre input used across the editors.
struct MeterField: View {
    let title: LocalizedStringKey
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
            Text("m")
                .foregroundStyle(.secondary)
        }
    }
}
