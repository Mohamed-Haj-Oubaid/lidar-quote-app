import Foundation

/// One material with its consumption rate (Verbrauch) and pack size, used to turn
/// measured areas into an order list. Rates are editable per company.
nonisolated struct MaterialRate: Codable, Hashable, Identifiable {
    enum Scope: String, Codable, CaseIterable, Identifiable {
        case rooms, facades
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rooms: String(localized: "Rooms")
            case .facades: String(localized: "Facades")
            }
        }
    }

    /// Which measured quantity the consumption refers to.
    enum Basis: String, Codable, CaseIterable, Identifiable {
        case netWallArea, wallAndCeilingArea, floorArea, revealLength, perimeter
        var id: String { rawValue }
        var title: String {
            switch self {
            case .netWallArea: String(localized: "Wall area (net)")
            case .wallAndCeilingArea: String(localized: "Wall + ceiling area")
            case .floorArea: String(localized: "Floor area")
            case .revealLength: String(localized: "Reveal length")
            case .perimeter: String(localized: "Perimeter")
            }
        }
        var unit: String {
            switch self {
            case .netWallArea, .wallAndCeilingArea, .floorArea: "m²"
            case .revealLength, .perimeter: "m"
            }
        }
    }

    var id = UUID()
    var name: String
    var scope: Scope
    var basis: Basis
    /// Consumption per m² (or per m) and coat, in `unit`.
    var consumption: Double
    var coats: Int = 1
    /// Unit of the material: l, kg, pcs, m², m.
    var unit: String
    /// Content of one pack in `unit`, e.g. 12.5 (l).
    var packSize: Double
    var packName: String
    var wastePercent: Int = 5
    var isEnabled: Bool = true
    /// Purchase price of one pack (Einkaufspreis, owner only). Optional so stored lists still decode.
    var packPriceCents: Int? = nil

    /// Quantity of the measured basis this material is applied to.
    func basisQuantity(in m: RoomMeasurement) -> Double {
        switch basis {
        case .netWallArea: max(0, m.grossWallArea - m.totalOpeningArea)
        case .wallAndCeilingArea: max(0, m.grossWallArea - m.totalOpeningArea) + m.floorArea
        case .floorArea: m.floorArea
        case .revealLength: m.openings.reduce(0) { $0 + $1.revealLength }
        case .perimeter: m.perimeter
        }
    }
}

/// Result line of the material calculation.
nonisolated struct MaterialNeed: Hashable, Identifiable {
    var material: MaterialRate
    var basisQuantity: Double
    var amount: Double
    var packs: Int
    var id: UUID { material.id }

    /// Purchase cost of the packs, when the pack price is known.
    var costCents: Int? { material.packPriceCents.map { $0 * packs } }
}

nonisolated enum MaterialCalculator {
    /// Sums the basis over all rooms (or facades) and converts it into packs.
    static func needs(for measurements: [RoomMeasurement], materials: [MaterialRate]) -> [MaterialNeed] {
        materials.filter(\.isEnabled).compactMap { material in
            let relevant = measurements.filter { ($0.isFacade == true) == (material.scope == .facades) }
            let quantity = relevant.reduce(0) { $0 + material.basisQuantity(in: $1) }
            guard quantity > 0 else { return nil }
            let amount = quantity * material.consumption * Double(max(material.coats, 1)) * (1 + Double(material.wastePercent) / 100)
            let packs = material.packSize > 0 ? Int((amount / material.packSize - 1e-9).rounded(.up)) : 0
            return MaterialNeed(material: material, basisQuantity: quantity, amount: amount, packs: packs)
        }
    }

    /// Total purchase cost of all needs with a known pack price.
    static func totalCost(_ needs: [MaterialNeed]) -> Int {
        needs.compactMap(\.costCents).reduce(0, +)
    }

    /// Plain-text order list for the supplier (mail, messenger).
    static func orderText(jobTitle: String, siteAddress: String, needs: [MaterialNeed]) -> String {
        var lines = [String(localized: "Material order – \(jobTitle)")]
        if !siteAddress.isEmpty { lines.append(String(localized: "Site: \(siteAddress)")) }
        lines.append("")
        for need in needs {
            let amount = need.amount.formatted(.number.precision(.fractionLength(0...1)))
            lines.append("• \(need.packs) × \(need.material.packName) – \(need.material.name) (\(amount) \(need.material.unit))")
        }
        return lines.joined(separator: "\n")
    }

    /// Typical German market consumption values – to be adjusted to the products used.
    static let defaults: [MaterialRate] = [
        MaterialRate(name: "Tiefgrund LF", scope: .rooms, basis: .wallAndCeilingArea, consumption: 0.15, unit: "l", packSize: 10, packName: "Kanister 10 l"),
        MaterialRate(name: "Innendispersionsfarbe weiß", scope: .rooms, basis: .wallAndCeilingArea, consumption: 0.15, coats: 2, unit: "l", packSize: 12.5, packName: "Eimer 12,5 l"),
        MaterialRate(name: "Abdeckvlies", scope: .rooms, basis: .floorArea, consumption: 1.1, unit: "m²", packSize: 25, packName: "Rolle 25 m²", wastePercent: 0),
        MaterialRate(name: "Acryl-Dichtstoff (Fugen)", scope: .rooms, basis: .perimeter, consumption: 0.1, unit: "Kartusche", packSize: 1, packName: "Kartusche 310 ml", wastePercent: 0, isEnabled: false),
        MaterialRate(name: "EPS-Dämmplatte WLG 035, 140 mm", scope: .facades, basis: .netWallArea, consumption: 1.0, unit: "m²", packSize: 2.0, packName: "Paket 2 m²"),
        MaterialRate(name: "Klebe- und Armierungsmörtel", scope: .facades, basis: .netWallArea, consumption: 10, unit: "kg", packSize: 25, packName: "Sack 25 kg"),
        MaterialRate(name: "Armierungsgewebe", scope: .facades, basis: .netWallArea, consumption: 1.1, unit: "m²", packSize: 50, packName: "Rolle 50 m²", wastePercent: 0),
        MaterialRate(name: "Schraubdübel mit Teller", scope: .facades, basis: .netWallArea, consumption: 6, unit: "Stk", packSize: 100, packName: "Karton 100 Stk"),
        MaterialRate(name: "Gewebe-Eckwinkel", scope: .facades, basis: .revealLength, consumption: 1.05, unit: "m", packSize: 2.5, packName: "Stange 2,5 m"),
        MaterialRate(name: "Putzgrund", scope: .facades, basis: .netWallArea, consumption: 0.3, unit: "kg", packSize: 20, packName: "Eimer 20 kg"),
        MaterialRate(name: "Silikonharz-Oberputz K2", scope: .facades, basis: .netWallArea, consumption: 3.0, unit: "kg", packSize: 25, packName: "Eimer 25 kg"),
        MaterialRate(name: "Silikonharz-Fassadenfarbe", scope: .facades, basis: .netWallArea, consumption: 0.2, coats: 2, unit: "l", packSize: 12.5, packName: "Eimer 12,5 l", isEnabled: false),
    ]
}

extension TenantSettings {
    /// The company's material rates; the defaults until the first edit.
    var materials: [MaterialRate] {
        get {
            guard !materialsData.isEmpty,
                  let decoded = try? StoreCoding.decoder.decode([MaterialRate].self, from: materialsData) else {
                return MaterialCalculator.defaults
            }
            return decoded
        }
        set { materialsData = (try? StoreCoding.encoder.encode(newValue)) ?? materialsData }
    }
}
