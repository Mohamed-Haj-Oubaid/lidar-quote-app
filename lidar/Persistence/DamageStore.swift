import Foundation
import SwiftData
import UIKit

/// Kind of damage found on site, documented before work starts.
enum DamageCategory: String, CaseIterable, Identifiable {
    case crack, moisture, mould, flaking, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .crack: String(localized: "Crack")
        case .moisture: String(localized: "Moisture")
        case .mould: String(localized: "Mould")
        case .flaking: String(localized: "Flaking plaster / paint")
        case .other: String(localized: "Other damage")
        }
    }

    var systemImage: String {
        switch self {
        case .crack: "bolt.horizontal"
        case .moisture: "drop"
        case .mould: "allergens"
        case .flaking: "square.stack.3d.down.right"
        case .other: "exclamationmark.triangle"
        }
    }
}

/// A documented damage in a room or on a facade: photo, category, note and the
/// wall it is on. Protects the company in later disputes. Device-local.
@Model
final class DamageNote {
    @Attribute(.unique) var id: UUID
    var categoryRaw: String
    var note: String
    var wallID: UUID?
    var photoFileName: String?
    var createdAt: Date
    var survey: Survey?

    init(id: UUID = UUID(), category: DamageCategory, survey: Survey) {
        self.id = id
        self.categoryRaw = category.rawValue
        self.note = ""
        self.createdAt = .now
        self.survey = survey
    }

    var category: DamageCategory {
        get { DamageCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }
}

/// Creating and deleting damage notes; photos are JPEGs in the protected media directory.
enum DamageStore {
    static func add(_ category: DamageCategory, photo: UIImage?, wallID: UUID?, to survey: Survey, in context: ModelContext) throws -> DamageNote {
        let damage = DamageNote(category: category, survey: survey)
        damage.wallID = wallID
        if let photo { damage.photoFileName = try storePhoto(photo) }
        context.insert(damage)
        try context.save()
        return damage
    }

    static func setPhoto(_ photo: UIImage, of damage: DamageNote, in context: ModelContext) throws {
        removeFile(of: damage)
        damage.photoFileName = try storePhoto(photo)
        try context.save()
    }

    static func delete(_ damage: DamageNote, in context: ModelContext) throws {
        removeFile(of: damage)
        context.delete(damage)
        try context.save()
    }

    static func image(of damage: DamageNote) -> UIImage? {
        guard let name = damage.photoFileName, let url = try? SurveyEngine.mediaURL(for: name),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Room deletion: photo files go with the room.
    static func removeFiles(of survey: Survey) {
        for damage in survey.damages { removeFile(of: damage) }
    }

    /// Client erasure (GDPR Art. 17): photos of the client's home are personal data.
    static func erasePhotos(of job: Job) {
        for survey in job.surveys {
            for damage in survey.damages {
                removeFile(of: damage)
                damage.photoFileName = nil
            }
        }
    }

    private static func storePhoto(_ image: UIImage) throws -> String {
        guard let data = downscaled(image).jpegData(compressionQuality: 0.75) else {
            throw WorkProofStore.ProofError.imageEncodingFailed
        }
        let fileName = "damage-\(UUID().uuidString).jpg"
        try data.write(to: try SurveyEngine.mediaURL(for: fileName), options: [.atomic, .completeFileProtection])
        return fileName
    }

    private static func removeFile(of damage: DamageNote) {
        if let name = damage.photoFileName, let url = try? SurveyEngine.mediaURL(for: name) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > WorkProofStore.maxPhotoDimension else { return image }
        let scale = WorkProofStore.maxPhotoDimension / longest
        let target = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
