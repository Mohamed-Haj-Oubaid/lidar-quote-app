import SwiftUI
import RoomPlan

/// Wraps Apple's `RoomCaptureView`, which provides the built-in step-by-step
/// coaching UI ("move closer", "slow down", …) while the worker walks the perimeter.
struct RoomCaptureRepresentable: UIViewRepresentable {
    /// Set to false to stop scanning; RoomPlan then post-processes and calls `onFinish`.
    var isScanning: Bool
    var onFinish: (Result<CapturedRoom, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = context.coordinator
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        context.coordinator.isRunning = true
        return view
    }

    func updateUIView(_ view: RoomCaptureView, context: Context) {
        context.coordinator.onFinish = onFinish
        if !isScanning, context.coordinator.isRunning {
            context.coordinator.isRunning = false
            view.captureSession.stop()
        }
    }

    static func dismantleUIView(_ view: RoomCaptureView, coordinator: Coordinator) {
        if coordinator.isRunning {
            view.captureSession.stop()
        }
    }

    @objc(RoomCaptureCoordinator)
    final class Coordinator: NSObject, RoomCaptureViewDelegate {
        var onFinish: (Result<CapturedRoom, Error>) -> Void
        var isRunning = false

        init(onFinish: @escaping (Result<CapturedRoom, Error>) -> Void) {
            self.onFinish = onFinish
        }

        // RoomCaptureViewDelegate inherits NSCoding; the coordinator is never archived.
        required init?(coder: NSCoder) { nil }
        func encode(with coder: NSCoder) {}

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
                onFinish(.success(processedResult))
            }
        }
    }
}
