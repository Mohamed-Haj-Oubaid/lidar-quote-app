import SwiftUI

struct OpeningRescanView: View {
    let opening: RoomOpening
    let onSave: (RoomOpening) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isScanning = true
    @State private var coverage = 0.0
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureRepresentable(
                isScanning: isScanning,
                captureMode: .detail,
                onCoverageChange: { coverage = $0 },
                onFinish: handle
            )
            .ignoresSafeArea()

            OpeningRescanPanel(
                title: scanTitle,
                coverage: coverage,
                isScanning: isScanning,
                errorMessage: errorMessage,
                onCancel: { dismiss() },
                onDone: { isScanning = false }
            )
            .padding()
        }
    }

    private var scanTitle: LocalizedStringResource {
        switch opening.kind {
        case .door: "Rescan this door"
        case .window: "Rescan this window"
        case .opening: "Rescan this opening"
        }
    }

    private func handle(_ result: Result<RoomCaptureOutput, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let output):
            let scanned = SurveyEngine.measurement(
                from: output.room,
                coloredSurface: output.coloredSurface
            )
            let candidates = scanned.openings.filter { $0.kind == opening.kind }
            guard let replacement = candidates.min(by: { matchScore($0) < matchScore($1) }) else {
                errorMessage = String(localized: "No matching door or window was detected. Scan the complete frame and both sides, then try again.")
                return
            }
            guard replacement.depth != nil else {
                errorMessage = String(localized: "The scan saw through the glass and could not isolate a solid reveal. The previous measurement was not changed. Scan both side surfaces more slowly and try again.")
                return
            }
            onSave(replacement)
            dismiss()
        }
    }

    private func matchScore(_ candidate: RoomOpening) -> Double {
        abs(candidate.width - opening.width)
            + abs(candidate.height - opening.height)
            + abs((candidate.depth ?? 0.12) - (opening.depth ?? 0.12)) * 0.5
    }
}

private struct OpeningRescanPanel: View {
    let title: LocalizedStringResource
    let coverage: Double
    let isScanning: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if isScanning {
                ProgressView(value: coverage)
                Text(coverage, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.monospacedDigit().bold())
                Text("Use the same movement as the main scanner. Capture the complete frame, the surrounding wall, and both solid sides. Avoid aiming only at glass.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView("Processing opening…")
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                if isScanning {
                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .disabled(coverage < 0.15)
                } else if errorMessage != nil {
                    Button("Close", action: onCancel)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }
}
