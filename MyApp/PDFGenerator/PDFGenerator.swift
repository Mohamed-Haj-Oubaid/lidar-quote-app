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
enum PDFGenerator {
    private static let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4 @ 72 dpi
    private static let margin: CGFloat = 48

    static func render(quote: Quote, job: Job, settings: TenantSettings) -> Data? {
        guard let calculation = quote.calculation else { return nil }
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format(for: quote))

        return renderer.pdfData { context in
            var y = startPage(context, quote: quote, settings: settings)

            // Client & job
            y = draw(String(localized: "Client"), at: y, font: .boldSystemFont(ofSize: 10))
            let clientLines = [job.clientName, job.siteAddress, job.clientEmail, job.clientPhone].filter { !$0.isEmpty }
            y = draw(clientLines.joined(separator: "\n"), at: y, font: .systemFont(ofSize: 10))
            y = draw(String(localized: "Project: \(job.title)"), at: y + 6, font: .systemFont(ofSize: 10))
            y += 14

            // Room summary (Aufmaß)
            y = draw(String(localized: "Measurements"), at: y, font: .boldSystemFont(ofSize: 11))
            for room in calculation.rooms {
                let text = String(localized: "\(room.roomName): floor \(Formatters.quantity(room.floorAreaHundredths, unit: .squareMeter)), walls gross \(Formatters.quantity(room.grossWallAreaHundredths, unit: .squareMeter)), openings \(Formatters.quantity(room.openingAreaHundredths, unit: .squareMeter)), \(room.doorCount) doors, \(room.windowCount) windows")
                y = ensureSpace(context, y: y, needed: 16, quote: quote, settings: settings)
                y = draw(text, at: y, font: .systemFont(ofSize: 9))
            }
            y += 14

            // Line items
            y = drawRow([String(localized: "Pos."), String(localized: "Description"), String(localized: "Quantity"), String(localized: "Unit price"), String(localized: "Total")],
                        at: y, font: .boldSystemFont(ofSize: 9))
            y = drawRule(at: y)
            for (index, line) in calculation.lines.enumerated() {
                y = ensureSpace(context, y: y, needed: 34, quote: quote, settings: settings)
                var description = "\(line.roomName) – \(line.itemName) (\(line.itemCode))"
                if let note = line.note { description += "\n\(note)" }
                if line.wastePercent > 0 { description += "\n" + String(localized: "incl. \(line.wastePercent) % waste") }
                y = drawRow([
                    "\(index + 1)",
                    description,
                    Formatters.quantity(line.billedQuantityHundredths, unit: line.unit),
                    Formatters.money(line.unitPriceCents),
                    Formatters.money(line.totalCents),
                ], at: y, font: .systemFont(ofSize: 9))
            }
            y = drawRule(at: y)

            // Totals: net + VAT + gross for transparent B2C/B2B pricing.
            y = ensureSpace(context, y: y, needed: 60, quote: quote, settings: settings)
            let vatPercent = (Double(calculation.vatRateBasisPoints) / 100).formatted(.number.precision(.fractionLength(0...2)))
            y = drawTotal(String(localized: "Net total"), Formatters.money(calculation.netTotalCents), at: y, bold: false)
            y = drawTotal(String(localized: "VAT \(vatPercent) %"), Formatters.money(calculation.vatCents), at: y, bold: false)
            y = drawTotal(String(localized: "Gross total"), Formatters.money(calculation.grossTotalCents), at: y, bold: true)
            y += 20

            // Notes: reproducibility, machine-assisted measurement, privacy notice.
            let notes = [
                String(localized: "Price book “\(calculation.priceBookName)” v\(calculation.priceBookVersion) · calculation engine \(calculation.engineVersion) · integrity \(quote.snapshotSHA256.prefix(16))"),
                String(localized: "Dimensions were captured with machine-assisted LiDAR measurement and checked by our staff. Final billing follows the actual measured quantities."),
                String(localized: "Privacy notice: \(settings.privacyNoticeText)"),
            ]
            for note in notes {
                y = ensureSpace(context, y: y, needed: 50, quote: quote, settings: settings)
                y = draw(note, at: y, font: .systemFont(ofSize: 7.5), color: .darkGray) + 4
            }
        }
    }

    // MARK: - Page layout

    private static func format(for quote: Quote) -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: String(localized: "Quote \(quote.displayNumber)"),
            kCGPDFContextCreator as String: "LiDAR Quote",
        ]
        return format
    }

    private static func startPage(_ context: UIGraphicsPDFRendererContext, quote: Quote, settings: TenantSettings) -> CGFloat {
        context.beginPage()
        var y = margin
        y = draw(settings.firmName, at: y, font: .boldSystemFont(ofSize: 16))
        if !settings.firmAddress.isEmpty {
            y = draw(settings.firmAddress, at: y, font: .systemFont(ofSize: 9), color: .darkGray)
        }
        y += 16
        y = draw(String(localized: "Quote \(quote.displayNumber)"), at: y, font: .boldSystemFont(ofSize: 18))
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

    private static func ensureSpace(_ context: UIGraphicsPDFRendererContext, y: CGFloat, needed: CGFloat, quote: Quote, settings: TenantSettings) -> CGFloat {
        y + needed > pageRect.height - margin ? startPage(context, quote: quote, settings: settings) : y
    }

    // MARK: - Drawing primitives

    /// Draws wrapped text across the content width and returns the next y position.
    @discardableResult
    private static func draw(_ text: String, at y: CGFloat, font: UIFont, color: UIColor = .black, inset: CGFloat = 0) -> CGFloat {
        let width = pageRect.width - 2 * margin - 2 * inset
        return draw(text, in: CGRect(x: margin + inset, y: y, width: width, height: .greatestFiniteMagnitude), font: font, color: color)
    }

    private static func draw(_ text: String, in rect: CGRect, font: UIFont, color: UIColor = .black, alignment: NSTextAlignment = .left) -> CGFloat {
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
