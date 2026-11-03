import UIKit

/// Renders the signed work-completion report (Arbeitsnachweis) as an A4 PDF in
/// the company's design: letterhead, job details, photo grid, signature block.
enum WorkProofPDF {
    /// Everything the report shows – built from a stored `WorkProof` or as a design sample.
    struct Content {
        struct Photo {
            var image: UIImage?
            var caption: String
            var roomName: String
            var takenAt: Date
        }

        var jobTitle: String
        var clientName: String
        var siteAddress: String
        var workDescription: String
        var photos: [Photo]
        var workerName: String
        var signature: UIImage?
        var signedAt: Date?
        var fingerprint: String?
        var photosErased: Bool
        var watermark: String?
    }

    static func defaultTitle() -> String { String(localized: "Work Completion Report") }

    static func title(settings: TenantSettings) -> String {
        let custom = settings.proofReportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? defaultTitle() : custom
    }

    static func render(proof: WorkProof, settings: TenantSettings) -> Data {
        let job = proof.job
        let content = Content(
            jobTitle: job?.title ?? "",
            clientName: job?.clientName ?? "",
            siteAddress: job?.siteAddress ?? "",
            workDescription: proof.workDescription,
            photos: proof.sortedPhotos.map {
                Content.Photo(image: WorkProofStore.image(of: $0), caption: $0.caption, roomName: $0.roomName, takenAt: $0.takenAt)
            },
            workerName: proof.workerName,
            signature: proof.signaturePNG.flatMap(UIImage.init(data:)),
            signedAt: proof.signedAt,
            fingerprint: proof.fingerprintSHA256,
            photosErased: job?.clientDataErasedAt != nil,
            watermark: proof.isSigned ? nil : String(localized: "DRAFT – NOT SIGNED"))
        return render(content, settings: settings)
    }

    /// A filled-in example so the company can check its design.
    static func renderSample(settings: TenantSettings) -> Data {
        let placeholder = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor(white: 0.88, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            let icon = UIImage(systemName: "photo")?.withTintColor(.gray, renderingMode: .alwaysOriginal)
            icon?.draw(in: CGRect(x: 160, y: 110, width: 80, height: 70))
        }
        let photos = (1...4).map {
            Content.Photo(image: placeholder, caption: String(localized: "Wall \($0) after the second coat"),
                          roomName: String(localized: "Living room"), takenAt: .now)
        }
        let content = Content(jobTitle: String(localized: "Sample project"), clientName: "Erika Mustermann",
                              siteAddress: "Musterstraße 1, 12345 Musterstadt",
                              workDescription: String(localized: "Walls primed and painted with two coats. Furniture covered and site cleaned."),
                              photos: photos, workerName: "Max Mustermann", signature: nil, signedAt: .now,
                              fingerprint: String(repeating: "0", count: 64), photosErased: false,
                              watermark: String(localized: "SAMPLE"))
        return render(content, settings: settings)
    }

    static func render(_ content: Content, settings: TenantSettings) -> Data {
        // Two passes: the first counts pages so every footer can say "Page x of y".
        let first = renderPass(content, settings: settings, totalPages: nil)
        return renderPass(content, settings: settings, totalPages: first.pages).data
    }

    private static func renderPass(_ content: Content, settings: TenantSettings, totalPages: Int?) -> (data: Data, pages: Int) {
        let brand = PDFBrand(settings: settings)
        let title = title(settings: settings)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "\(title) – \(content.jobTitle)",
                               kCGPDFContextCreator as String: "LiDAR Quote"]
        let renderer = UIGraphicsPDFRenderer(bounds: PDFGenerator.pageRect, format: format)
        let margin = PDFGenerator.margin
        let width = PDFGenerator.pageRect.width - 2 * margin
        var pages = 0

        let data = renderer.pdfData { context in
            var y: CGFloat = 0

            func newPage() {
                context.beginPage()
                pages += 1
                if let watermark = content.watermark { drawWatermark(watermark, in: context.cgContext) }
                PDFGenerator.drawFooter(settings: settings, page: pages, of: totalPages)
                if pages == 1 {
                    y = brand.drawLetterhead(settings: settings, at: margin) + 10
                } else {
                    y = PDFGenerator.draw(String(localized: "\(title) – \(content.jobTitle) (continued)"), at: margin,
                                          font: brand.font(10, bold: true), color: .darkGray) + 10
                }
            }
            func ensureSpace(_ needed: CGFloat) {
                if y + needed > PDFGenerator.contentBottom { newPage() }
            }
            func text(_ string: String, font: UIFont, color: UIColor = .black) {
                ensureSpace(PDFGenerator.height(of: string, font: font, width: width))
                y = PDFGenerator.draw(string, at: y, font: font, color: color)
            }
            func heading(_ string: String) {
                ensureSpace(40)
                y += 8
                text(string, font: brand.font(12, bold: true), color: brand.color)
                y += 2
            }

            newPage()
            text(title, font: brand.font(18, bold: true), color: brand.color)
            y += 6

            // Job details
            let details: [(String, String)] = [
                (String(localized: "Project"), content.jobTitle),
                (String(localized: "Client"), content.clientName),
                (String(localized: "Site"), content.siteAddress),
                (String(localized: "Completed"), content.signedAt?.formatted(date: .long, time: .shortened) ?? "–"),
            ].filter { !$0.1.isEmpty }
            for (label, value) in details {
                let labelFont = brand.font(10, bold: true)
                let rowHeight = PDFGenerator.height(of: value, font: brand.font(10), width: width - 90)
                ensureSpace(rowHeight)
                _ = PDFGenerator.draw(label, in: CGRect(x: margin, y: y, width: 90, height: rowHeight), font: labelFont)
                y = PDFGenerator.draw(value, in: CGRect(x: margin + 90, y: y, width: width - 90, height: .greatestFiniteMagnitude), font: brand.font(10))
            }

            let description = content.workDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty {
                heading(String(localized: "Work carried out"))
                text(description, font: brand.font(10))
            }

            // Photo grid – a row of photos never splits across pages.
            heading(String(localized: "Photo documentation (\(content.photos.count))"))
            if content.photosErased && content.photos.isEmpty {
                text(String(localized: "The photos were erased at the client's request."), font: brand.font(9), color: .darkGray)
            }
            let columns = CGFloat(min(max(settings.proofPhotosPerRow, 1), 3))
            let spacing: CGFloat = 12
            let cellWidth = (width - spacing * (columns - 1)) / columns
            let imageHeight = cellWidth * 0.75
            let captionFont = brand.font(8.5, bold: true)
            let metaFont = brand.font(7.5)
            for rowStart in stride(from: 0, to: content.photos.count, by: Int(columns)) {
                let row = Array(content.photos[rowStart..<min(rowStart + Int(columns), content.photos.count)])
                let captionHeights = row.enumerated().map { offset, photo in
                    (photo.caption.isEmpty ? 0 : PDFGenerator.height(of: photo.caption, font: captionFont, width: cellWidth))
                        + PDFGenerator.height(of: meta(of: photo, index: rowStart + offset + 1), font: metaFont, width: cellWidth)
                }
                let rowHeight = imageHeight + 4 + (captionHeights.max() ?? 0) + spacing
                ensureSpace(rowHeight)
                for (offset, photo) in row.enumerated() {
                    let x = margin + CGFloat(offset) * (cellWidth + spacing)
                    let box = CGRect(x: x, y: y, width: cellWidth, height: imageHeight)
                    UIColor(white: 0.95, alpha: 1).setFill()
                    UIBezierPath(rect: box).fill()
                    if let image = photo.image {
                        let size = PDFBrand.fitted(image.size, into: box.size)
                        image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
                    }
                    var textY = box.maxY + 4
                    if !photo.caption.isEmpty {
                        textY = PDFGenerator.draw(photo.caption, in: CGRect(x: x, y: textY, width: cellWidth, height: .greatestFiniteMagnitude), font: captionFont)
                    }
                    _ = PDFGenerator.draw(meta(of: photo, index: rowStart + offset + 1),
                                          in: CGRect(x: x, y: textY, width: cellWidth, height: .greatestFiniteMagnitude),
                                          font: metaFont, color: .darkGray)
                }
                y += rowHeight
            }

            // Signature block
            ensureSpace(150)
            heading(String(localized: "Confirmation"))
            text(String(localized: "I confirm that the work described above has been carried out and documented with the photos shown."),
                 font: brand.font(9.5))
            y += 8
            let signatureBox = CGRect(x: margin, y: y, width: 220, height: 70)
            if let signature = content.signature {
                let size = PDFBrand.fitted(signature.size, into: signatureBox.size)
                signature.draw(in: CGRect(x: signatureBox.minX, y: signatureBox.maxY - size.height, width: size.width, height: size.height))
            }
            let line = UIBezierPath()
            line.move(to: CGPoint(x: signatureBox.minX, y: signatureBox.maxY + 2))
            line.addLine(to: CGPoint(x: signatureBox.maxX, y: signatureBox.maxY + 2))
            UIColor.darkGray.setStroke()
            line.lineWidth = 0.75
            line.stroke()
            y = signatureBox.maxY + 6
            let signedLine = [content.workerName,
                              content.signedAt.map { $0.formatted(date: .long, time: .shortened) }].compactMap { $0 }.filter { !$0.isEmpty }
            text(signedLine.joined(separator: " · "), font: brand.font(10, bold: true))
            text(String(localized: "Worker – signed on the device"), font: brand.font(8), color: .darkGray)

            if let fingerprint = content.fingerprint {
                y += 10
                text(String(localized: "SHA-256 fingerprint of photos, texts and signature at signing: \(fingerprint)"),
                     font: brand.font(7), color: .darkGray)
            }
        }
        return (data, pages)
    }

    private static func meta(of photo: Content.Photo, index: Int) -> String {
        var parts = [String(localized: "Photo \(index)")]
        if !photo.roomName.isEmpty { parts.append(photo.roomName) }
        parts.append(photo.takenAt.formatted(date: .numeric, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private static func drawWatermark(_ text: String, in context: CGContext) {
        let page = PDFGenerator.pageRect
        context.saveGState()
        context.translateBy(x: page.midX, y: page.midY)
        context.rotate(by: -.pi / 4)
        let string = NSAttributedString(string: text, attributes: [
            .font: UIFont.boldSystemFont(ofSize: 46),
            .foregroundColor: UIColor.systemRed.withAlphaComponent(0.18),
        ])
        let size = string.size()
        string.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        context.restoreGState()
    }
}
