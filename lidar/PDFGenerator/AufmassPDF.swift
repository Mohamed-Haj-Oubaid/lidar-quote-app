import UIKit

/// Measurement report (Aufmaß) for a job: per room or facade a scaled plan with
/// wall labels, a wall table, an opening table and the area summary – sent with
/// the quote so the client can follow every quantity.
enum AufmassPDF {
    struct Room {
        var name: String
        var measurement: RoomMeasurement
        var damages: [DamageItem] = []
    }

    struct DamageItem {
        var category: String
        var note: String
        var wallName: String?
        var image: UIImage?
    }

    struct Content {
        var jobTitle: String
        var clientName: String
        var siteAddress: String
        var date: Date
        var rooms: [Room]
    }

    static func content(for job: Job) -> Content {
        Content(jobTitle: job.title, clientName: job.clientName, siteAddress: job.siteAddress, date: .now,
                rooms: job.sortedSurveys.map { survey in
                    let measurement = survey.measurement
                    return Room(name: survey.roomName, measurement: measurement,
                                damages: survey.sortedDamages.map { damage in
                                    DamageItem(category: damage.category.title, note: damage.note,
                                               wallName: damage.wallID.flatMap { id in
                                                   measurement.walls.firstIndex { $0.id == id }.map { wallName(measurement.walls[$0], index: $0) }
                                               },
                                               image: DamageStore.image(of: damage))
                                })
                })
    }

    static func render(job: Job, settings: TenantSettings) -> Data {
        render(content(for: job), settings: settings)
    }

    static func render(_ content: Content, settings: TenantSettings) -> Data {
        // Two passes: the first counts pages so every footer can say "Page x of y".
        let first = renderPass(content, settings: settings, totalPages: nil)
        return renderPass(content, settings: settings, totalPages: first.pages).data
    }

    static func wallName(_ wall: WallSegment, index: Int) -> String {
        wall.name ?? String(localized: "Wall \(index + 1)")
    }

    // MARK: - Rendering

    private static func renderPass(_ content: Content, settings: TenantSettings, totalPages: Int?) -> (data: Data, pages: Int) {
        let brand = PDFBrand(settings: settings)
        let title = String(localized: "Measurement Report")
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
            func row(_ cells: [String], columns: [(CGFloat, NSTextAlignment)], bold: Bool = false) {
                let font = bold ? brand.font(8.5, bold: true) : brand.font(8.5)
                let height = zip(cells, columns).map { PDFGenerator.height(of: $0, font: font, width: $1.0) }.max() ?? 0
                ensureSpace(height + 3)
                var x = margin
                var bottom = y
                for (cell, column) in zip(cells, columns) {
                    bottom = max(bottom, PDFGenerator.draw(cell, in: CGRect(x: x, y: y, width: column.0, height: .greatestFiniteMagnitude),
                                                           font: font, alignment: column.1))
                    x += column.0
                }
                y = bottom + 3
            }
            func rule() {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: margin, y: y))
                path.addLine(to: CGPoint(x: margin + width, y: y))
                UIColor.lightGray.setStroke()
                path.lineWidth = 0.5
                path.stroke()
                y += 4
            }

            newPage()
            text(title, font: brand.font(18, bold: true), color: brand.color)
            y += 4
            let details: [(String, String)] = [
                (String(localized: "Project"), content.jobTitle),
                (String(localized: "Client"), content.clientName),
                (String(localized: "Site"), content.siteAddress),
                (String(localized: "Date"), content.date.formatted(date: .long, time: .omitted)),
            ].filter { !$0.1.isEmpty }
            for (label, value) in details {
                let height = PDFGenerator.height(of: value, font: brand.font(10), width: width - 90)
                ensureSpace(height)
                _ = PDFGenerator.draw(label, in: CGRect(x: margin, y: y, width: 90, height: height), font: brand.font(10, bold: true))
                y = PDFGenerator.draw(value, in: CGRect(x: margin + 90, y: y, width: width - 90, height: .greatestFiniteMagnitude), font: brand.font(10))
            }

            for room in content.rooms {
                let m = room.measurement
                // Each room starts with heading + plan together.
                let planHeight: CGFloat = 230
                ensureSpace(planHeight + 60)
                y += 14
                let kind = m.isFacade == true ? String(localized: "Facade") : String(localized: "Room")
                text("\(room.name) (\(kind))", font: brand.font(13, bold: true), color: brand.color)
                y += 4
                drawPlan(m, in: CGRect(x: margin, y: y, width: width, height: planHeight), brand: brand)
                y += planHeight + 8

                // Walls
                let wallColumns: [(CGFloat, NSTextAlignment)] = [(30, .left), (min(200, width - 270), .left), (80, .right), (80, .right), (80, .right)]
                row([String(localized: "No."), String(localized: "Wall"), String(localized: "Length"),
                     String(localized: "Height"), String(localized: "Area")], columns: wallColumns, bold: true)
                rule()
                for (index, wall) in m.walls.enumerated() {
                    row(["W\(index + 1)", wallName(wall, index: index), Formatters.meters(wall.length),
                         Formatters.meters(wall.height), Formatters.meters(wall.grossArea, suffix: "m²")], columns: wallColumns)
                }
                rule()

                // Openings
                if !m.openings.isEmpty {
                    y += 4
                    let openingColumns: [(CGFloat, NSTextAlignment)] = [(110, .left), (110, .left), (100, .right), (89, .right), (90, .right)]
                    row([String(localized: "Opening"), String(localized: "Wall"), String(localized: "Width × Height"),
                         String(localized: "Depth"), String(localized: "Area")], columns: openingColumns, bold: true)
                    rule()
                    for opening in m.openings {
                        let wallLabel = opening.wallID.flatMap { id in m.walls.firstIndex { $0.id == id } }.map { "W\($0 + 1)" } ?? "–"
                        let size = "\(opening.width.formatted(.number.precision(.fractionLength(2)))) × \(Formatters.meters(opening.height))"
                        row([opening.name ?? opening.kind.title, wallLabel, size,
                             opening.depth.map { Formatters.meters($0) } ?? "–",
                             Formatters.meters(opening.area, suffix: "m²")], columns: openingColumns)
                    }
                    rule()
                }

                // Summary
                y += 2
                var summary: [String] = []
                if m.isFacade != true {
                    summary.append(String(localized: "Floor area \(Formatters.meters(m.floorArea, suffix: "m²"))"))
                }
                summary.append(String(localized: "Perimeter \(Formatters.meters(m.perimeter))"))
                summary.append(String(localized: "Wall area gross \(Formatters.meters(m.grossWallArea, suffix: "m²"))"))
                summary.append(String(localized: "Openings \(Formatters.meters(m.totalOpeningArea, suffix: "m²"))"))
                summary.append(String(localized: "Wall area net \(Formatters.meters(max(0, m.grossWallArea - m.totalOpeningArea), suffix: "m²"))"))
                if m.isFacade == true {
                    summary.append(String(localized: "Scaffold area \(Formatters.meters(m.scaffoldArea, suffix: "m²"))"))
                }
                text(summary.joined(separator: " · "), font: brand.font(9, bold: true))

                // Damage documentation
                if !room.damages.isEmpty {
                    y += 8
                    text(String(localized: "Damage documentation"), font: brand.font(11, bold: true), color: brand.color)
                    let photoSize = CGSize(width: 150, height: 112)
                    for damage in room.damages {
                        var description = damage.category
                        if let wall = damage.wallName { description += " · \(wall)" }
                        if !damage.note.isEmpty { description += "\n\(damage.note)" }
                        let textWidth = width - photoSize.width - 12
                        let height = max(damage.image == nil ? 0 : photoSize.height,
                                         PDFGenerator.height(of: description, font: brand.font(9), width: textWidth))
                        ensureSpace(height + 8)
                        if let image = damage.image {
                            let size = PDFBrand.fitted(image.size, into: photoSize)
                            image.draw(in: CGRect(x: margin, y: y, width: size.width, height: size.height))
                        }
                        _ = PDFGenerator.draw(description, in: CGRect(x: margin + photoSize.width + 12, y: y, width: textWidth,
                                                                      height: .greatestFiniteMagnitude), font: brand.font(9))
                        y += height + 8
                    }
                }
            }

            y += 12
            text(String(localized: "Dimensions were captured with LiDAR scanning, laser distance meter or manual entry and checked by our staff. Final billing follows the actual measured quantities."),
                 font: brand.font(7.5), color: .darkGray)
        }
        return (data, pages)
    }

    /// Scaled floor plan with wall numbers and lengths; openings as coloured marks.
    private static func drawPlan(_ m: RoomMeasurement, in box: CGRect, brand: PDFBrand) {
        UIColor(white: 0.97, alpha: 1).setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 4).fill()
        let points = m.walls.flatMap { [$0.start, $0.end] }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        let padding: CGFloat = 34
        let spanX = max(maxX - minX, 0.01), spanY = max(maxY - minY, 0.01)
        let scale = min((box.width - 2 * padding) / spanX, (box.height - 2 * padding) / spanY)
        let offsetX = box.minX + (box.width - spanX * scale) / 2
        let offsetY = box.minY + (box.height - spanY * scale) / 2
        func map(_ p: PlanPoint) -> CGPoint { CGPoint(x: offsetX + (p.x - minX) * scale, y: offsetY + (p.y - minY) * scale) }

        if m.floorPolygon.count >= 3 {
            let floor = UIBezierPath()
            floor.move(to: map(m.floorPolygon[0]))
            for p in m.floorPolygon.dropFirst() { floor.addLine(to: map(p)) }
            floor.close()
            brand.color.withAlphaComponent(0.07).setFill()
            floor.fill()
        }

        let labelFont = UIFont.boldSystemFont(ofSize: 7.5)
        for (index, wall) in m.walls.enumerated() {
            let a = map(wall.start), b = map(wall.end)
            let path = UIBezierPath()
            path.move(to: a)
            path.addLine(to: b)
            UIColor.black.setStroke()
            path.lineWidth = 2.5
            path.stroke()

            // Openings: coloured segment at their position along the wall.
            let length = max(wall.length, .ulpOfOne)
            for opening in m.openings where opening.wallID == wall.id {
                let center = (opening.centerOffset ?? length / 2) / length
                let half = opening.width / 2 / length
                let t0 = max(0, center - half), t1 = min(1, center + half)
                let mark = UIBezierPath()
                mark.move(to: CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0))
                mark.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1))
                (opening.kind == .door ? UIColor.systemOrange : opening.kind == .window ? UIColor.systemCyan : UIColor.systemPurple).setStroke()
                mark.lineWidth = 5
                mark.stroke()
            }

            // Label outside the wall, perpendicular to it.
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dx = b.x - a.x, dy = b.y - a.y
            let norm = max(hypot(dx, dy), 1)
            var normal = CGPoint(x: -dy / norm, y: dx / norm)
            let center = CGPoint(x: box.midX, y: box.midY)
            if hypot(mid.x + normal.x * 10 - center.x, mid.y + normal.y * 10 - center.y) < hypot(mid.x - center.x, mid.y - center.y) {
                normal = CGPoint(x: -normal.x, y: -normal.y)
            }
            let label = NSAttributedString(string: "W\(index + 1)  \(Formatters.meters(wall.length))",
                                           attributes: [.font: labelFont, .foregroundColor: UIColor.darkGray])
            let size = label.size()
            let origin = CGPoint(x: mid.x + normal.x * 12 - size.width / 2, y: mid.y + normal.y * 12 - size.height / 2)
            label.draw(at: origin)
        }
    }
}
