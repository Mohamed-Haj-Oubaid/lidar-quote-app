import SwiftUI
import SwiftData
import PhotosUI
import PencilKit
import UIKit

/// "Proof of work" section on the job screen.
struct WorkProofSection: View {
    @Environment(\.modelContext) private var modelContext
    let job: Job
    @State private var errorMessage: String?

    var body: some View {
        Section {
            ForEach(job.sortedWorkProofs) { proof in
                NavigationLink(value: proof) {
                    WorkProofRow(proof: proof)
                }
                .deleteDisabled(proof.isSigned)
            }
            .onDelete(perform: deleteDrafts)

            Button("New Work Report", systemImage: "checkmark.seal") {
                do {
                    _ = try WorkProofStore.createProof(for: job, in: modelContext)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        } header: {
            Text("Proof of Work")
        } footer: {
            Text("Photograph the finished work, then the worker signs. The signed report is sent as a PDF with your company design.")
        }
    }

    private func deleteDrafts(at offsets: IndexSet) {
        let proofs = job.sortedWorkProofs
        for index in offsets where !proofs[index].isSigned {
            try? WorkProofStore.delete(proof: proofs[index], in: modelContext)
        }
    }
}

private struct WorkProofRow: View {
    let proof: WorkProof

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(proof.isSigned ? proof.workerName : String(localized: "Draft"))
                    .font(.headline)
                Text("\(proof.photos.count) photos · \((proof.signedAt ?? proof.createdAt).formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(proof.isSigned ? String(localized: "Signed") : String(localized: "Open"),
                  systemImage: proof.isSigned ? "checkmark.seal.fill" : "pencil")
                .font(.caption.bold())
                .foregroundStyle(proof.isSigned ? .green : .orange)
        }
    }
}

/// One work report: description, photos, signature and the PDF.
struct WorkProofView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var proof: WorkProof

    @State private var isTakingPhoto = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var isSigning = false
    @State private var pdf: PDFFile?
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    private var isCameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        Form {
            statusSection
            Section("Work carried out") {
                TextField("Describe what was done", text: $proof.workDescription, axis: .vertical)
                    .lineLimit(3...10)
                    .disabled(proof.isSigned)
            }
            photosSection
            actionSections
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle(WorkProofPDF.title(settings: LocalStore.settings(in: modelContext)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !proof.isSigned {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete Draft", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                }
            }
        }
        .confirmationDialog("Delete this draft and its photos?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? WorkProofStore.delete(proof: proof, in: modelContext)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPicker { image in addPhoto(image) }
                .ignoresSafeArea()
        }
        .onChange(of: libraryItem) { _, item in loadLibraryPhoto(item) }
        .sheet(isPresented: $isSigning) {
            NavigationStack { SignWorkProofView(proof: proof) }
        }
        .sheet(item: $pdf) { file in
            PDFSheet(file: file) { pdf = nil }
        }
    }

    @ViewBuilder private var statusSection: some View {
        if proof.isSigned, let signedAt = proof.signedAt {
            Section {
                Label("Signed by \(proof.workerName) · \(signedAt.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } footer: {
                Text("Signed reports are locked and can no longer be changed.")
            }
        }
    }

    private var photosSection: some View {
        Section {
            ForEach(proof.sortedPhotos) { photo in
                ProofPhotoRow(photo: photo, rooms: roomNames, isLocked: proof.isSigned)
            }
            .onDelete(perform: deletePhotos)
            .deleteDisabled(proof.isSigned)

            if !proof.isSigned {
                if isCameraAvailable {
                    Button("Take Photo", systemImage: "camera") { isTakingPhoto = true }
                } else {
                    PhotosPicker(selection: $libraryItem, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }
                }
            }
        } header: {
            Text("Photos (\(proof.photos.count))")
        } footer: {
            if !proof.isSigned {
                Text("Photograph each wall or area you worked on and add a short caption.")
            }
        }
    }

    @ViewBuilder private var actionSections: some View {
        if !proof.isSigned {
            Section {
                Button("Sign & Complete", systemImage: "signature") { isSigning = true }
                    .disabled(proof.photos.isEmpty)
            } footer: {
                if proof.photos.isEmpty {
                    Text("Take at least one photo first.")
                }
            }
        }

        Section {
            Button(proof.isSigned ? "View & Send PDF" : "Preview PDF", systemImage: "doc.richtext") { showPDF() }
        }
    }

    private var roomNames: [String] { proof.job?.sortedSurveys.map(\.roomName) ?? [] }

    private func loadLibraryPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                addPhoto(image)
            }
            libraryItem = nil
        }
    }

    private func addPhoto(_ image: UIImage) {
        do {
            try WorkProofStore.addPhoto(image, to: proof, in: modelContext)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePhotos(at offsets: IndexSet) {
        let photos = proof.sortedPhotos
        for index in offsets {
            try? WorkProofStore.delete(photo: photos[index], in: modelContext)
        }
    }

    /// Renders with the current company design and writes a share file.
    private func showPDF() {
        try? modelContext.save()
        let settings = LocalStore.settings(in: modelContext)
        let data = WorkProofPDF.render(proof: proof, settings: settings)
        let title = WorkProofPDF.title(settings: settings)
        let name = QuotePreviewView.fileName(for: "\(title) \(proof.job?.title ?? "")")
        LocalStore.removeSharedPDFs()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).pdf")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            pdf = PDFFile(data: data, url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PDFFile: Identifiable {
    let id = UUID()
    let data: Data
    let url: URL
}

/// PDF preview with a share button (Mail, AirDrop, Messages, …).
struct PDFSheet: View {
    let file: PDFFile
    let done: () -> Void

    var body: some View {
        NavigationStack {
            PDFKitView(data: file.data)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(file.url.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: done)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: file.url)
                    }
                }
        }
    }
}

/// Thumbnail, caption and room of one photo.
private struct ProofPhotoRow: View {
    @Bindable var photo: ProofPhoto
    let rooms: [String]
    let isLocked: Bool
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .frame(width: 96, height: 72)
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Caption, e.g. North wall", text: $photo.caption, axis: .vertical)
                    .disabled(isLocked)
                if !rooms.isEmpty {
                    Picker("Room", selection: $photo.roomName) {
                        Text("No room").tag("")
                        ForEach(rooms, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .disabled(isLocked)
                }
                Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: photo.fileName) {
            thumbnail = await WorkProofStore.image(of: photo)?.byPreparingThumbnail(ofSize: CGSize(width: 288, height: 216))
        }
    }
}

/// Worker name + handwritten signature; signing locks the report.
private struct SignWorkProofView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let proof: WorkProof

    @AppStorage("lastWorkerName") private var workerName = ""
    @State private var drawing = PKDrawing()
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Worker") {
                TextField("Full name", text: $workerName)
                    .textContentType(.name)
            }
            Section {
                SignaturePad(drawing: $drawing)
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                Button("Clear Signature", systemImage: "eraser", role: .destructive) { drawing = PKDrawing() }
                    .disabled(drawing.strokes.isEmpty)
            } header: {
                Text("Signature")
            } footer: {
                Text("By signing you confirm the work was carried out as documented. The report can no longer be changed afterwards.")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Sign Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Sign") { sign() }
                    .disabled(drawing.strokes.isEmpty || workerName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func sign() {
        do {
            try WorkProofStore.sign(proof, workerName: workerName, signature: SignaturePad.image(of: drawing), in: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// PencilKit canvas for a finger or Apple Pencil signature (always black on white).
struct SignaturePad: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>
        init(drawing: Binding<PKDrawing>) { self.drawing = drawing }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }

    /// Renders in light mode so the ink stays black in the PDF.
    static func image(of drawing: PKDrawing) -> UIImage {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: drawing.bounds.insetBy(dx: -8, dy: -8), scale: 3)
        }
        return image
    }
}

/// System camera for site photos.
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
