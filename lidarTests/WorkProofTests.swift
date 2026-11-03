import Foundation
import PDFKit
import SwiftData
import Testing
import UIKit
@testable import lidar

/// Proof of work: photos, signing lock, fingerprint, branded PDF, cleanup.
@MainActor
@Suite(.serialized)
struct WorkProofTests {
    private func photo(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }

    private func makeProof(_ context: ModelContext) throws -> (Job, WorkProof) {
        let job = Job(title: "Malerarbeiten", clientName: "Frau Müller", siteAddress: "Hauptstr. 1")
        context.insert(job)
        let proof = try WorkProofStore.createProof(for: job, in: context)
        return (job, proof)
    }

    private func fileExists(_ photo: ProofPhoto) throws -> Bool {
        FileManager.default.fileExists(atPath: try SurveyEngine.mediaURL(for: photo.fileName).path)
    }

    @Test func signingNeedsPhotoAndNameThenLocks() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let (_, proof) = try makeProof(context)
        let signature = photo(.black)

        #expect(throws: WorkProofStore.ProofError.noPhotos) {
            try WorkProofStore.sign(proof, workerName: "Max", signature: signature, in: context)
        }
        try WorkProofStore.addPhoto(photo(.red), to: proof, in: context)
        #expect(throws: WorkProofStore.ProofError.missingWorkerName) {
            try WorkProofStore.sign(proof, workerName: "  ", signature: signature, in: context)
        }

        try WorkProofStore.sign(proof, workerName: " Max Mustermann ", signature: signature, in: context)
        #expect(proof.isSigned)
        #expect(proof.workerName == "Max Mustermann")
        #expect(proof.fingerprintSHA256?.count == 64)

        #expect(throws: WorkProofStore.ProofError.alreadySigned) {
            try WorkProofStore.addPhoto(photo(.blue), to: proof, in: context)
        }
        let first = try #require(proof.photos.first)
        #expect(throws: WorkProofStore.ProofError.alreadySigned) {
            try WorkProofStore.delete(photo: first, in: context)
        }
        #expect(throws: WorkProofStore.ProofError.alreadySigned) {
            try WorkProofStore.delete(proof: proof, in: context)
        }
    }

    @Test func fingerprintDetectsChanges() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let (_, proof) = try makeProof(context)
        try WorkProofStore.addPhoto(photo(.red), to: proof, in: context)
        try WorkProofStore.sign(proof, workerName: "Max", signature: photo(.black), in: context)
        let stored = try #require(proof.fingerprintSHA256)

        #expect(WorkProofStore.fingerprint(of: proof) == stored)
        proof.photos.first?.caption = "changed later"
        #expect(WorkProofStore.fingerprint(of: proof) != stored)
    }

    @Test func pdfShowsCompanyJobPhotosAndWorker() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let settings = LocalStore.settings(in: context)
        settings.firmName = "Malerbetrieb Muster"
        settings.proofReportTitle = "Arbeitsnachweis"
        settings.pdfFooterNote = "Amtsgericht Musterstadt"
        settings.logoData = photo(.green).pngData()
        let (_, proof) = try makeProof(context)
        for _ in 0..<7 { try WorkProofStore.addPhoto(photo(.red), to: proof, in: context) }
        proof.sortedPhotos.first?.caption = "Nordwand"
        try WorkProofStore.sign(proof, workerName: "Max Mustermann", signature: photo(.black), in: context)

        let pdf = try #require(PDFDocument(data: WorkProofPDF.render(proof: proof, settings: settings)))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        #expect(text.contains("Malerbetrieb Muster"))
        #expect(text.contains("Arbeitsnachweis"))
        #expect(text.contains("Amtsgericht Musterstadt"))
        #expect(text.contains("Frau Müller"))
        #expect(text.contains("Nordwand"))
        #expect(text.contains("Max Mustermann"))
        #expect(text.contains(try #require(proof.fingerprintSHA256)))
        #expect(!text.contains("DRAFT"))
        #expect(text.contains("Page 1 of \(pdf.pageCount)"))
    }

    @Test func clientErasureAndJobDeletionRemovePhotoFiles() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let (job, proof) = try makeProof(context)
        try WorkProofStore.addPhoto(photo(.red), to: proof, in: context)
        let photo = try #require(proof.photos.first)
        let fileName = photo.fileName
        #expect(try fileExists(photo))

        try LocalStore.applyClientErasure(to: job, in: context)
        #expect(proof.photos.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try SurveyEngine.mediaURL(for: fileName).path))

        try WorkProofStore.addPhoto(self.photo(.blue), to: proof, in: context)
        let second = try #require(proof.photos.first)
        let secondName = second.fileName
        try LocalStore.delete(job: job, in: context)
        #expect(!FileManager.default.fileExists(atPath: try SurveyEngine.mediaURL(for: secondName).path))
        #expect(try context.fetchCount(FetchDescriptor<WorkProof>()) == 0)
    }

    @Test func brandParsesColourAndFallsBack() {
        #expect(UIColor(hex: "#FF0000")?.hexString == "#FF0000")
        #expect(UIColor(hex: "00ff7f")?.hexString == "#00FF7F")
        #expect(UIColor(hex: "red") == nil)
    }
}
