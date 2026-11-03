import UIKit

/// The company's PDF design (logo, colour, font, letterhead layout), read from
/// `TenantSettings` and applied to quotes and work-proof reports alike.
struct PDFBrand {
    enum FontStyle: String, CaseIterable, Identifiable {
        case system, serif, rounded, monospaced
        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: String(localized: "Standard")
            case .serif: String(localized: "Serif")
            case .rounded: String(localized: "Rounded")
            case .monospaced: String(localized: "Monospaced")
            }
        }

        fileprivate var design: UIFontDescriptor.SystemDesign {
            switch self {
            case .system: .default
            case .serif: .serif
            case .rounded: .rounded
            case .monospaced: .monospaced
            }
        }
    }

    enum LogoAlignment: String, CaseIterable, Identifiable {
        case left, center, right
        var id: String { rawValue }

        var title: String {
            switch self {
            case .left: String(localized: "Left")
            case .center: String(localized: "Center")
            case .right: String(localized: "Right")
            }
        }
    }

    static let defaultColorHex = "#1F4E79"
    /// Largest box the logo is scaled into (aspect ratio kept).
    static let logoMaxSize = CGSize(width: 150, height: 56)

    var color: UIColor
    var logo: UIImage?
    var fontStyle: FontStyle
    var logoAlignment: LogoAlignment
    var headerNote: String
    var footerNote: String

    init(settings: TenantSettings) {
        color = UIColor(hex: settings.brandColorHex) ?? UIColor(hex: Self.defaultColorHex) ?? .black
        logo = settings.logoData.flatMap(UIImage.init(data:))
        fontStyle = FontStyle(rawValue: settings.pdfFontStyle) ?? .system
        logoAlignment = LogoAlignment(rawValue: settings.logoAlignment) ?? .left
        headerNote = settings.pdfHeaderNote.trimmingCharacters(in: .whitespacesAndNewlines)
        footerNote = settings.pdfFooterNote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func font(_ size: CGFloat, bold: Bool = false) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard let descriptor = base.fontDescriptor.withDesign(fontStyle.design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// Draws logo, company name and address, the optional header note and a
    /// coloured rule. Returns the y position below it.
    func drawLetterhead(settings: TenantSettings, at top: CGFloat) -> CGFloat {
        let margin = PDFGenerator.margin
        let width = PDFGenerator.pageRect.width - 2 * margin
        let logoSize = logo.map { Self.fitted($0.size, into: Self.logoMaxSize) } ?? .zero
        let gap: CGFloat = logo == nil ? 0 : 14

        var textRect = CGRect(x: margin, y: top, width: width, height: .greatestFiniteMagnitude)
        var alignment = NSTextAlignment.left
        var bottom = top

        if let logo {
            switch logoAlignment {
            case .left:
                logo.draw(in: CGRect(origin: CGPoint(x: margin, y: top), size: logoSize))
                textRect.origin.x += logoSize.width + gap
                textRect.size.width -= logoSize.width + gap
                alignment = .right
            case .right:
                logo.draw(in: CGRect(origin: CGPoint(x: margin + width - logoSize.width, y: top), size: logoSize))
                textRect.size.width -= logoSize.width + gap
            case .center:
                logo.draw(in: CGRect(origin: CGPoint(x: margin + (width - logoSize.width) / 2, y: top), size: logoSize))
                textRect.origin.y = top + logoSize.height + 8
                alignment = .center
            }
            bottom = top + logoSize.height
        }

        var y = PDFGenerator.draw(settings.firmName, in: textRect, font: font(16, bold: true), color: color, alignment: alignment)
        if !settings.firmAddress.isEmpty {
            textRect.origin.y = y
            y = PDFGenerator.draw(settings.firmAddress, in: textRect, font: font(9), color: .darkGray, alignment: alignment)
        }
        y = max(y, bottom)

        if !headerNote.isEmpty {
            y = PDFGenerator.draw(headerNote, in: CGRect(x: margin, y: y + 4, width: width, height: .greatestFiniteMagnitude),
                                  font: font(9), color: color, alignment: logoAlignment == .center ? .center : .left)
        }

        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: margin, y: y + 6))
        rule.addLine(to: CGPoint(x: margin + width, y: y + 6))
        color.setStroke()
        rule.lineWidth = 1.5
        rule.stroke()
        return y + 12
    }

    /// Size that fits `size` into `box` keeping the aspect ratio.
    static func fitted(_ size: CGSize, into box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

extension UIColor {
    /// Parses "#RRGGBB" (the "#" is optional).
    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// "#RRGGBB" in sRGB.
    var hexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func component(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", component(red), component(green), component(blue))
    }
}
