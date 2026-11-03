import Foundation
import SwiftData
import UIKit
import CryptoKit

/// Creating, editing and signing work proofs. Photos are JPEG files in the
/// protected media directory (excluded from backups, wiped on sign-out).
enum WorkProofStore {
    enum ProofError: LocalizedError {
        case alreadySigned, noPhotos, missingWorkerName, missingSignature, imageEncodingFailed

        var errorDescription: String? {
            switch self {
            case .alreadySigned: String(localized: "This report is signed and can no longer be changed.")
            case .noPhotos: String(localized: "Take at least one photo of the finished work.")
            case .missingWorkerName: String(localized: "Enter the worker's name.")
            case .missingSignature: String(localized: "The worker must sign.")
            case .imageEncodingFailed: String(localized: "The photo could not be saved.")
            }
        }
    }

    /// Longest photo edge in pixels – sharp on A4, small enough for e-mail.
    static let maxPhotoDimension: CGFloat = 2000

    static func createProof(for job: Job, in context: ModelContext) throws -> WorkProof {
        let proof = WorkProof(job: job)
        context.insert(proof)
        try context.save()
        return proof
    }

    static func addPhoto(_ image: UIImage, roomName: String = "", to proof: WorkProof, in context: ModelContext) throws {
        guard !proof.isSigned else { throw ProofError.alreadySigned }
        guard let data = downscaled(image).jpegData(compressionQuality: 0.75) else { throw ProofError.imageEncodingFailed }
        let fileName = "proof-\(UUID().uuidString).jpg"
        try data.write(to: try SurveyEngine.mediaURL(for: fileName), options: [.atomic, .completeFileProtection])
        context.insert(ProofPhoto(fileName: fileName, roomName: roomName, proof: proof))
        try context.save()
    }

    static func delete(photo: ProofPhoto, in context: ModelContext) throws {
        guard photo.proof?.isSigned != true else { throw ProofError.alreadySigned }
        removeFile(of: photo)
        context.delete(photo)
        try context.save()
    }

    /// Only drafts can be deleted; signed reports stay with the job.
    static func delete(proof: WorkProof, in context: ModelContext) throws {
        guard !proof.isSigned else { throw ProofError.alreadySigned }
        removeFiles(of: proof)
        context.delete(proof)
        try context.save()
    }

    /// Locks the report: stores name, signature and time plus a fingerprint of everything.
    static func sign(_ proof: WorkProof, workerName: String, signature: UIImage, in context: ModelContext) throws {
        guard !proof.isSigned else { throw ProofError.alreadySigned }
        let name = workerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProofError.missingWorkerName }
        guard !proof.photos.isEmpty else { throw ProofError.noPhotos }
        guard let png = signature.pngData() else { throw ProofError.missingSignature }

        proof.workerName = name
        proof.signaturePNG = png
        proof.signedAt = .now
        proof.fingerprintSHA256 = fingerprint(of: proof)
        try context.save()
    }

    /// SHA-256 over texts, signature and every photo file, in a fixed order.
    static func fingerprint(of proof: WorkProof) -> String {
        var hasher = SHA256()
        func add(_ string: String) { hasher.update(data: Data((string + "\u{1F}").utf8)) }
        add(proof.id.uuidString)
        add(proof.job?.id.uuidString ?? "")
        add(proof.workDescription)
        add(proof.workerName)
        add(proof.signedAt.map { String($0.timeIntervalSince1970) } ?? "")
        hasher.update(data: proof.signaturePNG ?? Data())
        for photo in proof.sortedPhotos {
            add(photo.caption)
            add(photo.roomName)
            add(String(photo.takenAt.timeIntervalSince1970))
            hasher.update(data: imageData(of: photo) ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func imageData(of photo: ProofPhoto) -> Data? {
        guard let url = try? SurveyEngine.mediaURL(for: photo.fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func image(of photo: ProofPhoto) -> UIImage? {
        imageData(of: photo).flatMap(UIImage.init(data:))
    }

    /// Deletes the photo files of all proofs of a job (job deletion, client erasure).
    static func removeFiles(of proof: WorkProof) {
        for photo in proof.photos { removeFile(of: photo) }
    }

    /// Client erasure (GDPR Art. 17): photos of the client's home are personal data.
    static func erasePhotos(of job: Job, in context: ModelContext) {
        for proof in job.workProofs {
            for photo in proof.photos {
                removeFile(of: photo)
                context.delete(photo)
            }
        }
    }

    private static func removeFile(of photo: ProofPhoto) {
        if let url = try? SurveyEngine.mediaURL(for: photo.fileName) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxPhotoDimension else { return image }
        let scale = maxPhotoDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
