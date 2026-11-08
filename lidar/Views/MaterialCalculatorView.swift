import SwiftUI
import SwiftData

/// Material list for a job: quantities and packs from the measured areas, ready
/// to share with the supplier. Consumption rates are editable and remembered.
struct MaterialCalculatorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BackendClient.self) private var backend
    let job: Job

    /// Purchase prices are for the owner and admins only.
    private var canSeePrices: Bool { backend.session?.role?.canSeePrices ?? true }

    @State private var materials: [MaterialRate] = []
    @State private var editing: MaterialRate?

    private var measurements: [RoomMeasurement] { job.sortedSurveys.map(\.measurement) }
    private var needs: [MaterialNeed] { MaterialCalculator.needs(for: measurements, materials: materials) }

    var body: some View {
        List {
            let needsByID = Dictionary(uniqueKeysWithValues: needs.map { ($0.id, $0) })
            ForEach(MaterialRate.Scope.allCases) { scope in
                let items = materials.filter { $0.scope == scope }
                Section(scope.title) {
                    ForEach(items) { material in
                        MaterialRow(material: material, need: needsByID[material.id], showsPrice: canSeePrices,
                                    toggle: { toggle(material) }, edit: { editing = material })
                    }
                    .onDelete { offsets in delete(offsets.map { items[$0].id }) }
                }
            }
            if canSeePrices {
                Section {
                    LabeledContent("Material purchase cost", value: Formatters.money(MaterialCalculator.totalCost(needs)))
                        .bold()
                } footer: {
                    Text("Sum of the packs with a purchase price. Enter purchase prices by tapping a material.")
                }
            }
            Section {
                Button("Add Material", systemImage: "plus") {
                    editing = MaterialRate(name: "", scope: .rooms, basis: .netWallArea, consumption: 0.1, unit: "l", packSize: 10, packName: "")
                }
                Button("Reset to Defaults", systemImage: "arrow.counterclockwise", role: .destructive) {
                    store(MaterialCalculator.defaults)
                }
            } footer: {
                Text("Typical consumption values incl. waste. Check them against the data sheets of the products you use.")
            }
        }
        .navigationTitle("Material List")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: MaterialCalculator.orderText(jobTitle: job.title, siteAddress: job.siteAddress, needs: needs)) {
                    Label("Share Order List", systemImage: "square.and.arrow.up")
                }
                .disabled(needs.isEmpty)
            }
        }
        .onAppear { materials = LocalStore.settings(in: modelContext).materials }
        .sheet(item: $editing) { material in
            NavigationStack {
                MaterialEditor(material: material, showsPrice: canSeePrices) { updated in
                    var list = materials
                    if let index = list.firstIndex(where: { $0.id == updated.id }) {
                        list[index] = updated
                    } else {
                        list.append(updated)
                    }
                    store(list)
                }
            }
        }
    }

    private func toggle(_ material: MaterialRate) {
        var list = materials
        guard let index = list.firstIndex(where: { $0.id == material.id }) else { return }
        list[index].isEnabled.toggle()
        store(list)
    }

    private func delete(_ ids: [UUID]) {
        store(materials.filter { !ids.contains($0.id) })
    }

    /// Device-local company setting – saved directly, not synced.
    private func store(_ list: [MaterialRate]) {
        materials = list
        LocalStore.settings(in: modelContext).materials = list
        try? modelContext.save()
    }
}

private struct MaterialRow: View {
    let material: MaterialRate
    let need: MaterialNeed?
    let showsPrice: Bool
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: material.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(material.isEnabled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(material.isEnabled ? Text("Included") : Text("Not included"))

            VStack(alignment: .leading, spacing: 2) {
                Text(material.name)
                    .foregroundStyle(material.isEnabled ? .primary : .secondary)
                let coats = material.coats > 1 ? " × \(material.coats)" : ""
                Text("\(material.consumption.formatted()) \(material.unit)/\(material.basis.unit)\(coats) · \(material.basis.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let need {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(need.packs) × \(material.packName)")
                        .font(.subheadline.bold())
                    Text("\(need.amount.formatted(.number.precision(.fractionLength(0...1)))) \(material.unit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showsPrice, let cost = need.costCents {
                        Text(Formatters.money(cost))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: edit)
    }
}

private struct MaterialEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var material: MaterialRate
    let showsPrice: Bool
    let save: (MaterialRate) -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $material.name)
                Picker("Used for", selection: $material.scope) {
                    ForEach(MaterialRate.Scope.allCases) { Text($0.title).tag($0) }
                }
                Picker("Per", selection: $material.basis) {
                    ForEach(MaterialRate.Basis.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Consumption") {
                LabeledContent("Unit") {
                    TextField("Unit", text: $material.unit).multilineTextAlignment(.trailing)
                }
                LabeledContent("Per \(material.basis.unit)") {
                    TextField("Consumption", value: $material.consumption, format: .number.precision(.fractionLength(0...3)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Stepper("Coats: \(material.coats)", value: $material.coats, in: 1...5)
                Stepper("Waste: \(material.wastePercent) %", value: $material.wastePercent, in: 0...50)
            }
            Section("Pack") {
                TextField("Pack name, e.g. Bucket 12.5 l", text: $material.packName)
                LabeledContent("Content (\(material.unit))") {
                    TextField("Content", value: $material.packSize, format: .number.precision(.fractionLength(0...3)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                if showsPrice {
                    LabeledContent("Purchase price per pack") {
                        TextField("Price", value: Binding(
                            get: { material.packPriceCents.map { Decimal($0) / 100 } },
                            set: { material.packPriceCents = $0.map { NSDecimalNumber(decimal: $0 * 100).rounding(accordingToBehavior: nil).intValue } }
                        ), format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                        Text("€").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(material.name.isEmpty ? String(localized: "New Material") : material.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save(material)
                    dismiss()
                }
                .disabled(material.name.trimmingCharacters(in: .whitespaces).isEmpty || material.packSize <= 0)
            }
        }
    }
}
