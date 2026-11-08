import SwiftUI
import UIKit

struct WallPhotoCaptureFlow: View {
    let wallCount: Int
    let onComplete: ([Data]) -> Void

    @State private var wallIndex = 0
    @State private var photos: [Data] = []
    @State private var isShowingCamera = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "camera.viewfinder")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Photograph Wall \(min(wallIndex + 1, wallCount)) of \(wallCount)")
                    .font(.title2.bold())

                Text("Stand facing the wall, keep the iPad level, and include the complete wall, doors, and windows. The photo becomes the wall surface in the 3D model.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                ProgressView(value: Double(wallIndex), total: Double(max(wallCount, 1)))

                Button("Take Wall Photo", systemImage: "camera") {
                    isShowingCamera = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Finish Without More Photos") {
                    onComplete(photos)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding()
            .navigationTitle("3D Photo Capture")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraImagePicker { image in
                    guard let data = image.jpegData(compressionQuality: 0.82) else {
                        isShowingCamera = false
                        return
                    }
                    photos.append(data)
                    wallIndex += 1
                    isShowingCamera = false
                    if wallIndex >= wallCount {
                        onComplete(photos)
                    }
                } onCancel: {
                    isShowingCamera = false
                }
            }
        }
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
