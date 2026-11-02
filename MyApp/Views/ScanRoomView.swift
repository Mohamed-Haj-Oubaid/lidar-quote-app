import SwiftUI
import SwiftData
import RoomPlan

/// Full-screen LiDAR scan. RoomPlan's built-in coaching guides the worker while
/// walking the perimeter; on "Done" the result becomes a new room in the job.
struct ScanRoomView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let job: Job

    private enum Phase: Equatable {
        case scanning, processing, failed(String)
    }

    @State private var phase = Phase.scanning
    @State private var roomName = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureRepresentable(isScanning: phase == .scanning) { result in
                handle(result)
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                switch phase {
                case .scanning:
                    Text("Walk slowly along the walls. Point at every door and window.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    HStack {
                        Button("Cancel", role: .cancel) { dismiss() }
                            .buttonStyle(.bordered)
                        Button("Done") { phase = .processing }
                            .buttonStyle(.borderedProminent)
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
            roomName = String(localized: "Room \(job.surveys.count + 1)")
        }
    }

    private func handle(_ result: Result<CapturedRoom, Error>) {
        switch result {
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        case .success(let room):
            let survey = Survey(roomName: roomName, measurement: SurveyEngine.measurement(from: room), job: job)
            modelContext.insert(survey)
            // The parametric model holds geometry only (no camera imagery) and stays on the device
            // unless the firm allows media upload.
            survey.usdzFileName = try? SurveyEngine.storeModel(room, surveyID: survey.id)
            do {
                try LocalStore.save(survey: survey, in: modelContext)
                dismiss()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
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

    var body: some View {
        Form {
            Section("Room") {
                TextField("Name", text: $roomName)
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
            roomName = String(localized: "Room \(job.surveys.count + 1)")
        }
    }

    private func add() {
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
        let survey = Survey(roomName: roomName, measurement: measurement, job: job)
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
