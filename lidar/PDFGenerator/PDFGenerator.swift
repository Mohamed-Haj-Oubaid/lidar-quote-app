import UIKit

/// Money and quantity formatting shared by the PDF and the UI.
enum Formatters {
    static func money(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "EUR"))
    }

    static func quantity(_ hundredths: Int, unit: PricingUnit) -> String {
        let value = Double(hundredths) / 100
        let digits = unit == .piece ? 0 : 2
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(unit.symbol)"
    }

    static func meters(_ value: Double, suffix: String = "m") -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) \(suffix)"
    }
}

/// Renders an A4 quote PDF entirely on-device. The output is a pure function of
/// the frozen calculation plus the quote number, so it can be re-rendered when
/// the server replaces the provisional number with the official one.
/// Everything the PDF shows about the quote itself – built from a stored `Quote`
/// or, for the sample-price-book preview, from a calculation that is never issued.
struct QuoteDocument {
    var number: String
    var revision: Int
    var issuedAt: Date
    var isProvisional: Bool
    var snapshotSHA256: String
    var calculation: QuoteCalculation
    /// Large diagonal text on every page, e.g. "SAMPLE – NOT A VALID QUOTE".
    var watermark: String?
}

enum PDFGenerator {
    static let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4 @ 72 dpi
    static let margin: CGFloat = 48

    static func render(quote: Quote, job: Job, settings: TenantSettings) -> Data? {
        guard let calculation = quote.calculation else { return nil }
        return render(QuoteDocument(number: quote.displayNumber, revision: quote.revision, issuedAt: quote.issuedAt,
                                    isProvisional: quote.isProvisional, snapshotSHA256: quote.snapshotSHA256,
                                    calculation: calculation, watermark: nil),
                      job: job, settings: settings)
    }

    /// Watermarked preview for calculations from the local sample price book. Creates no quote.
    static func renderSamplePreview(calculation: QuoteCalculation, job: Job, settings: TenantSettings) -> Data? {
        render(QuoteDocument(number: String(localized: "SAMPLE"), revision: 0, issuedAt: .now, isProvisional: false,
                             snapshotSHA256: (try? calculation.sha256Hex()) ?? "",
                             calculation: calculation, watermark: String(localized: "SAMPLE – NOT A VALID QUOTE")),
               job: job, settings: settings)
    }

    static func render(_ quote: QuoteDocument, job: Job, settings: TenantSettings) -> Data? {
        // Two passes: the first counts pages so every footer can say "Page x of y".
        let first = renderPass(quote, job: job, settings: settings, totalPages: nil)
        return renderPass(quote, job: job, settings: settings, totalPages: first.pages).data
    }

    /// Number of pages a document needs (exposed for tests).
    static func pageCount(_ quote: QuoteDocument, job: Job, settings: TenantSettings) -> Int {
        renderPass(quote, job: job, settings: settings, totalPages: nil).pages
    }

    private static func renderPass(_ quote: QuoteDocument, job: Job, settings: TenantSettings, totalPages: Int?) -> (data: Data, pages: Int) {
        let calculation = quote.calculation
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format(for: quote))
        var pages = 0

        let data = renderer.pdfData { context in
            let page = PageWriter(context: context, quote: quote, settings: settings, totalPages: totalPages)
            page.start()

            // Client & job
            page.text(String(localized: "Client"), font: .boldSystemFont(ofSize: 10))
            let clientLines = [job.clientName, job.siteAddress, job.clientEmail, job.clientPhone].filter { !$0.isEmpty }
            page.text(clientLines.joined(separator: "\n"), font: .systemFont(ofSize: 10))
            page.y += 6
            page.text(String(localized: "Project: \(job.title)"), font: .systemFont(ofSize: 10))
            page.y += 14

            // Room summary (Aufmaß)
            page.text(String(localized: "Measurements"), font: .boldSystemFont(ofSize: 11))
            for room in calculation.rooms {
                page.text(String(localized: "\(room.roomName): floor \(Formatters.quantity(room.floorAreaHundredths, unit: .squareMeter)), walls gross \(Formatters.quantity(room.grossWallAreaHundredths, unit: .squareMeter)), openings \(Formatters.quantity(room.openingAreaHundredths, unit: .squareMeter)), \(room.doorCount) doors, \(room.windowCount) windows"),
                          font: .systemFont(ofSize: 9))
            }
            page.y += 14

            // Line items – the header repeats on every page; rows never split.
            page.beginTable()
            for (index, line) in calculation.lines.enumerated() {
                var description = "\(line.roomName) – \(line.itemName) (\(line.itemCode))"
                if let note = line.note { description += "\n\(note)" }
                if line.wastePercent > 0 { description += "\n" + String(localized: "incl. \(line.wastePercent) % waste") }
                page.row([
                    "\(index + 1)",
                    description,
                    Formatters.quantity(line.billedQuantityHundredths, unit: line.unit),
                    Formatters.money(line.unitPriceCents),
                    Formatters.money(line.totalCents),
                ])
            }
            page.endTable()

            // Totals: net + VAT + gross for transparent B2C/B2B pricing.
            page.ensureSpace(60)
            let vatPercent = (Double(calculation.vatRateBasisPoints) / 100).formatted(.number.precision(.fractionLength(0...2)))
            page.y = drawTotal(String(localized: "Net total"), Formatters.money(calculation.netTotalCents), at: page.y, bold: false)
            page.y = drawTotal(String(localized: "VAT \(vatPercent) %"), Formatters.money(calculation.vatCents), at: page.y, bold: false)
            page.y = drawTotal(String(localized: "Gross total"), Formatters.money(calculation.grossTotalCents), at: page.y, bold: true)
            page.y += 14

            // Validity and payment terms.
            if quote.watermark == nil {
                let days = max(settings.quoteValidityDays, 1)
                let validUntil = (Calendar.current.date(byAdding: .day, value: days, to: quote.issuedAt) ?? quote.issuedAt)
                    .formatted(date: .long, time: .omitted)
                page.text(String(localized: "Valid until \(validUntil)"), font: .boldSystemFont(ofSize: 9))
            }
            if !settings.paymentTerms.isEmpty {
                page.text(String(localized: "Payment terms: \(settings.paymentTerms)"), font: .systemFont(ofSize: 9))
            }
            page.y += 10

            // Notes: reproducibility, machine-assisted measurement, privacy notice.
            var notes = [
                String(localized: "Price book “\(calculation.priceBookName)” v\(calculation.priceBookVersion) · calculation engine \(calculation.engineVersion) · SHA-256 fingerprint of the calculation \(quote.snapshotSHA256.prefix(16))"),
                String(localized: "Dimensions were captured with machine-assisted LiDAR measurement and checked by our staff. Final billing follows the actual measured quantities."),
                String(localized: "Privacy notice: \(settings.privacyNoticeText)"),
            ]
            // Only official numbers were checked by the server (unit prices, VAT, totals).
            if !quote.isProvisional && quote.watermark == nil {
                notes.insert(String(localized: "Unit prices, VAT and totals were checked by our server against this price book when the quote number was assigned."), at: 1)
            }
            for note in notes {
                page.text(note, font: .systemFont(ofSize: 7.5), color: .darkGray)
                page.y += 4
            }
            pages = page.number
        }
        return (data, pages)
    }

    // MARK: - Page layout

    private static let footerHeight: CGFloat = 34
    /// Lowest y content may reach; the footer lives below it.
    static var contentBottom: CGFloat { pageRect.height - margin - footerHeight }

    /// Tracks the current page, draws header/footer on every new page and moves
    /// content that does not fit to the next page.
    private final class PageWriter {
        let context: UIGraphicsPDFRendererContext
        let quote: QuoteDocument
        let settings: TenantSettings
        let totalPages: Int?
        var number = 0
        var y: CGFloat = 0
        private var inTable = false

        init(context: UIGraphicsPDFRendererContext, quote: QuoteDocument, settings: TenantSettings, totalPages: Int?) {
            self.context = context
            self.quote = quote
            self.settings = settings
            self.totalPages = totalPages
        }

        func start() {
            context.beginPage()
            number += 1
            if let watermark = quote.watermark {
                PDFGenerator.drawWatermark(watermark, in: context.cgContext)
            }
            PDFGenerator.drawFooter(settings: settings, page: number, of: totalPages)
            y = PDFGenerator.drawHeader(quote: quote, settings: settings, firstPage: number == 1)
            if inTable { tableHeader() }
        }

        func ensureSpace(_ needed: CGFloat) {
            if y + needed > PDFGenerator.contentBottom { start() }
        }

        /// Measures first, so a paragraph taller than the remaining space starts on the next page.
        func text(_ string: String, font: UIFont, color: UIColor = .black) {
            ensureSpace(PDFGenerator.height(of: string, font: font, width: PDFGenerator.pageRect.width - 2 * PDFGenerator.margin))
            y = PDFGenerator.draw(string, at: y, font: font, color: color)
        }

        func beginTable() {
            inTable = true
            ensureSpace(60)
            tableHeader()
        }

        func endTable() {
            inTable = false
            y = PDFGenerator.drawRule(at: y)
        }

        func row(_ cells: [String]) {
            let font = UIFont.systemFont(ofSize: 9)
            ensureSpace(PDFGenerator.rowHeight(cells, font: font))
            y = PDFGenerator.drawRow(cells, at: y, font: font)
        }

        private func tableHeader() {
            y = PDFGenerator.drawRow([String(localized: "Pos."), String(localized: "Description"), String(localized: "Quantity"),
                                      String(localized: "Unit price"), String(localized: "Total")],
                                     at: y, font: .boldSystemFont(ofSize: 9))
            y = PDFGenerator.drawRule(at: y)
        }
    }

    private static func format(for quote: QuoteDocument) -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: String(localized: "Quote \(quote.number)"),
            kCGPDFContextCreator as String: "LiDAR Quote",
        ]
        return format
    }

    /// Full letterhead on the first page, a compact one on continuation pages.
    private static func drawHeader(quote: QuoteDocument, settings: TenantSettings, firstPage: Bool) -> CGFloat {
        var y = margin
        guard firstPage else {
            y = draw(String(localized: "Quote \(quote.number) (continued)"), at: y, font: .boldSystemFont(ofSize: 10), color: .darkGray)
            return y + 10
        }
        let brand = PDFBrand(settings: settings)
        y = brand.drawLetterhead(settings: settings, at: y)
        y += 10
        y = draw(String(localized: "Quote \(quote.number)"), at: y, font: brand.font(18, bold: true), color: brand.color)
        let date = quote.issuedAt.formatted(date: .long, time: .omitted)
        y = draw(String(localized: "Revision \(quote.revision) · \(date)"), at: y, font: .systemFont(ofSize: 9), color: .darkGray)

        if quote.isProvisional {
            let banner = CGRect(x: margin, y: y + 6, width: pageRect.width - 2 * margin, height: 22)
            UIColor.systemOrange.withAlphaComponent(0.15).setFill()
            UIBezierPath(roundedRect: banner, cornerRadius: 4).fill()
            _ = draw(String(localized: "PROVISIONAL NUMBER – the official quote number is assigned on the next sync."),
                     at: banner.minY + 5, font: .boldSystemFont(ofSize: 9), color: .systemOrange, inset: 8)
            y = banner.maxY + 6
        }
        return y + 14
    }

    /// Company details (German letter footer) and the page number.
    static func drawFooter(settings: TenantSettings, page: Int, of total: Int?) {
        let top = pageRect.height - margin - footerHeight + 8
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: top - 4))
        path.addLine(to: CGPoint(x: pageRect.width - margin, y: top - 4))
        UIColor.lightGray.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let address = settings.firmAddress.split(whereSeparator: \.isNewline).joined(separator: ", ")
        let line1 = [settings.firmName, address, settings.phone, settings.email].filter { !$0.isEmpty }.joined(separator: " · ")
        let line2 = [
            settings.taxNumber.isEmpty ? nil : String(localized: "Tax no. \(settings.taxNumber)"),
            settings.vatID.isEmpty ? nil : String(localized: "VAT ID \(settings.vatID)"),
            settings.bankIBAN.isEmpty ? nil : String(localized: "IBAN \(settings.bankIBAN)"),
        ].compactMap { $0 }.joined(separator: " · ")
        let note = settings.pdfFooterNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageLabel = total.map { String(localized: "Page \(page) of \($0)") } ?? String(localized: "Page \(page)")
        let width = pageRect.width - 2 * margin
        _ = draw([note, line1, line2].filter { !$0.isEmpty }.joined(separator: "\n"),
                 in: CGRect(x: margin, y: top, width: width - 80, height: footerHeight), font: .systemFont(ofSize: 7), color: .darkGray)
        _ = draw(pageLabel, in: CGRect(x: pageRect.width - margin - 80, y: top, width: 80, height: 12),
                 font: .systemFont(ofSize: 7), color: .darkGray, alignment: .right)
    }

    /// Height a wrapped text needs at the given width (same metrics as `draw`).
    static func height(of text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(bounds.height) + 2
    }

    /// Height of a table row (tallest cell + row spacing), measured before drawing.
    private static func rowHeight(_ cells: [String], font: UIFont) -> CGFloat {
        zip(cells, columns).map { height(of: $0, font: font, width: $1.width) }.max().map { $0 + 4 } ?? 0
    }

    private static func drawWatermark(_ text: String, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: pageRect.midX, y: pageRect.midY)
        context.rotate(by: -.pi / 4)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 46),
            .foregroundColor: UIColor.systemRed.withAlphaComponent(0.18),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        context.restoreGState()
    }

    // MARK: - Drawing primitives

    /// Draws wrapped text across the content width and returns the next y position.
    @discardableResult
    static func draw(_ text: String, at y: CGFloat, font: UIFont, color: UIColor = .black, inset: CGFloat = 0) -> CGFloat {
        let width = pageRect.width - 2 * margin - 2 * inset
        return draw(text, in: CGRect(x: margin + inset, y: y, width: width, height: .greatestFiniteMagnitude), font: font, color: color)
    }

    static func draw(_ text: String, in rect: CGRect, font: UIFont, color: UIColor = .black, alignment: NSTextAlignment = .left) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        string.draw(with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ceil(bounds.height)), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return rect.minY + ceil(bounds.height) + 2
    }

    /// Column layout: Pos | Description | Quantity | Unit price | Total
    private static let columns: [(width: CGFloat, alignment: NSTextAlignment)] = [
        (28, .left), (233, .left), (70, .right), (84, .right), (84, .right),
    ]

    private static func drawRow(_ cells: [String], at y: CGFloat, font: UIFont) -> CGFloat {
        var x = margin
        var maxY = y
        for (cell, column) in zip(cells, columns) {
            let bottom = draw(cell, in: CGRect(x: x, y: y, width: column.width, height: .greatestFiniteMagnitude), font: font, alignment: column.alignment)
            maxY = max(maxY, bottom)
            x += column.width
        }
        return maxY + 4
    }

    private static func drawRule(at y: CGFloat) -> CGFloat {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: pageRect.width - margin, y: y))
        UIColor.lightGray.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        return y + 6
    }

    private static func drawTotal(_ label: String, _ value: String, at y: CGFloat, bold: Bool) -> CGFloat {
        let font: UIFont = bold ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 10)
        let valueX = pageRect.width - margin - 120
        _ = draw(label, in: CGRect(x: valueX - 160, y: y, width: 160, height: 20), font: font, alignment: .right)
        return draw(value, in: CGRect(x: valueX, y: y, width: 120, height: 20), font: font, alignment: .right)
    }
}
