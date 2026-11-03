import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Lets the company design its PDFs (quotes and work reports): logo, colour,
/// font, letterhead layout, texts and photo grid. Shows a live sample.
struct PDFDesignView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var settings: TenantSettings
    let canEdit: Bool

    @State private var logoItem: PhotosPickerItem?
    @State private var preview: PDFFile?

    private var brandColor: Binding<Color> {
        Binding {
            Color(uiColor: UIColor(hex: settings.brandColorHex) ?? .black)
        } set: { color in
            settings.brandColorHex = UIColor(color).hexString
        }
    }

    var body: some View {
        Form {
            Section {
                if let data = settings.logoData, let logo = UIImage(data: data) {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 80)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Company logo")
                }
                PhotosPicker(selection: $logoItem, matching: .images) {
                    Label(settings.logoData == nil ? "Choose Logo" : "Change Logo", systemImage: "photo.badge.plus")
                }
                if settings.logoData != nil {
                    Button("Remove Logo", systemImage: "trash", role: .destructive) { settings.logoData = nil }
                }
                Picker("Logo position", selection: $settings.logoAlignment) {
                    ForEach(PDFBrand.LogoAlignment.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Logo")
            } footer: {
                Text("A PNG with transparent background looks best.")
            }

            Section("Style") {
                ColorPicker("Brand colour", selection: brandColor, supportsOpacity: false)
                Picker("Font", selection: $settings.pdfFontStyle) {
                    ForEach(PDFBrand.FontStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Button("Reset Colour") { settings.brandColorHex = PDFBrand.defaultColorHex }
            }

            Section {
                TextField("Header note, e.g. slogan or master craftsman", text: $settings.pdfHeaderNote, axis: .vertical)
                TextField("Footer note, e.g. court of registration", text: $settings.pdfFooterNote, axis: .vertical)
            } header: {
                Text("Texts on every PDF")
            }

            Section("Work report") {
                TextField(WorkProofPDF.defaultTitle(), text: $settings.proofReportTitle)
                Picker("Photos per row", selection: $settings.proofPhotosPerRow) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button("Preview Work Report", systemImage: "doc.richtext") { showPreview() }
            } footer: {
                Text("The design applies to quotes and work reports created on this device.")
            }
        }
        .disabled(!canEdit)
        .navigationTitle("PDF Design")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    settings.logoData = Self.normalizedLogo(image)
                }
                logoItem = nil
            }
        }
        .onDisappear { try? modelContext.save() }
        .sheet(item: $preview) { file in
            NavigationStack {
                PDFKitView(data: file.data)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Sample")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { preview = nil }
                        }
                    }
            }
        }
    }

    private func showPreview() {
        let data = WorkProofPDF.renderSample(settings: settings)
        preview = PDFFile(data: data, url: FileManager.default.temporaryDirectory.appendingPathComponent("sample.pdf"))
    }

    /// PNG scaled to at most 800 px wide – sharp in print, small in the store.
    static func normalizedLogo(_ image: UIImage) -> Data? {
        let target = PDFBrand.fitted(image.size, into: CGSize(width: 800, height: 800))
        let size = image.size.width > target.width ? target : image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.pngData()
    }
}
