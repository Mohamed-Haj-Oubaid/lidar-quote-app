import SwiftUI
import SwiftData
import PhotosUI

/// Damage documentation of a room or facade: photo, category, wall and note.
struct DamageSection: View {
    @Environment(\.modelContext) private var modelContext
    let survey: Survey

    @State private var newCategory: DamageCategory?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            ForEach(survey.sortedDamages) { damage in
                NavigationLink {
                    DamageDetailView(damage: damage, walls: survey.measurement.walls)
                } label: {
                    DamageRow(damage: damage, walls: survey.measurement.walls)
                }
            }
            .onDelete { offsets in
                let damages = survey.sortedDamages
                for index in offsets { try? DamageStore.delete(damages[index], in: modelContext) }
            }
            Menu {
                ForEach(DamageCategory.allCases) { category in
                    Button(category.title, systemImage: category.systemImage) { add(category) }
                }
            } label: {
                Label("Document Damage", systemImage: "exclamationmark.triangle")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        } header: {
            Text("Damage (\(survey.damages.count))")
        } footer: {
            Text("Photograph cracks, moisture or mould before work starts. The photos appear in the measurement report.")
        }
    }

    private func add(_ category: DamageCategory) {
        do {
            _ = try DamageStore.add(category, photo: nil, wallID: nil, to: survey, in: modelContext)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DamageRow: View {
    let damage: DamageNote
    let walls: [WallSegment]

    var body: some View {
        HStack(spacing: 12) {
            if let image = DamageStore.image(of: damage) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                Image(systemName: damage.category.systemImage)
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(damage.category.title).font(.headline)
                if let index = walls.firstIndex(where: { $0.id == damage.wallID }) {
                    Text(AufmassPDF.wallName(walls[index], index: index)).font(.caption).foregroundStyle(.secondary)
                }
                if !damage.note.isEmpty {
                    Text(damage.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

private struct DamageDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var damage: DamageNote
    let walls: [WallSegment]

    @State private var isTakingPhoto = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var errorMessage: String?

    private var isCameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        Form {
            Section {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 320)
                        .frame(maxWidth: .infinity)
                }
                if isCameraAvailable {
                    Button(photo == nil ? "Take Photo" : "Retake Photo", systemImage: "camera") { isTakingPhoto = true }
                }
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
            }
            Section {
                Picker("Type", selection: $damage.category) {
                    ForEach(DamageCategory.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                Picker("Wall", selection: $damage.wallID) {
                    Text("Not assigned").tag(UUID?.none)
                    ForEach(Array(walls.enumerated()), id: \.element.id) { index, wall in
                        Text(AufmassPDF.wallName(wall, index: index)).tag(Optional(wall.id))
                    }
                }
                TextField("Description, e.g. crack 40 cm above window", text: $damage.note, axis: .vertical)
                    .lineLimit(2...6)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle(damage.category.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { photo = DamageStore.image(of: damage) }
        .onDisappear { try? modelContext.save() }
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPicker { image in store(image) }
                .ignoresSafeArea()
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    store(image)
                }
                libraryItem = nil
            }
        }
    }

    private func store(_ image: UIImage) {
        do {
            try DamageStore.setPhoto(image, of: damage, in: modelContext)
            photo = DamageStore.image(of: damage)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
