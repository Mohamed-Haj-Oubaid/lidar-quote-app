import SwiftUI
import SwiftData

/// Settings → Company → Price Book. Edits a draft copy of the active version and
/// publishes it as a new immutable version. Item ids stay stable across versions,
/// so room selections keep working. Online-only.
struct PriceBookEditorView: View {
    @Environment(BackendClient.self) private var backend
    @Environment(SyncManager.self) private var sync
    @Query(sort: \PriceBookVersion.version, order: .reverse) private var versions: [PriceBookVersion]

    @State private var name = ""
    @State private var vatPercent: Decimal = 19
    @State private var items: [PriceItem] = []
    @State private var loadedFrom: UUID?
    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?

    private var active: PriceBookVersion? { versions.first { $0.isActive } }
    /// Versions of the active (server) book, for rollback.
    private var history: [PriceBookVersion] {
        guard let book = active, !book.isLocalSample else { return [] }
        return versions.filter { $0.priceBookID == book.priceBookID && !$0.isLocalSample }
    }

    var body: some View {
        Form {
            if !sync.isOnline {
                Section {
                    Label("Publishing needs an internet connection.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Price book") {
                TextField("Name", text: $name)
                LabeledContent("VAT") {
                    TextField("VAT", value: $vatPercent, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                    Text("%").foregroundStyle(.secondary)
                }
                if let active {
                    LabeledContent("Based on", value: active.isLocalSample ? String(localized: "Sample prices") : "v\(active.version)")
                }
            }

            Section("Items") {
                ForEach($items) { $item in
                    NavigationLink {
                        PriceItemEditor(item: $item)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name.isEmpty ? String(localized: "New item") : item.name)
                            Text("\(item.code) · \(Formatters.money(item.unitPriceCents)) / \(item.unit.symbol) · \(item.basis.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { items.remove(atOffsets: $0) }
                Button("Add Item", systemImage: "plus") {
                    items.append(PriceItem(id: UUID(), code: "", name: "", basis: .wallArea, unitPriceCents: 0,
                                           openingRule: .noDeduction, defaultWastePercent: 0))
                }
            }

            Section {
                Button(isWorking ? "Publishing…" : "Publish New Version", systemImage: "paperplane") {
                    Task { await publish() }
                }
                .disabled(!canPublish)
            } footer: {
                Text("Published versions never change. Existing quotes keep the prices they were issued with.")
            }

            if history.count > 1 {
                Section("Versions") {
                    ForEach(history) { version in
                        HStack {
                            Text("v\(version.version) · \(version.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                            Spacer()
                            if version.isActive {
                                Text("Active").foregroundStyle(.green)
                            } else {
                                Button("Make Active") { Task { await activate(version) } }
                                    .disabled(!sync.isOnline || isWorking)
                            }
                        }
                    }
                }
            }

            if let message { Text(message).foregroundStyle(.green) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("Price Book")
        .onAppear(perform: loadDraft)
    }

    private var canPublish: Bool {
        sync.isOnline && !isWorking && !name.trimmingCharacters(in: .whitespaces).isEmpty && !items.isEmpty
            && items.allSatisfy { !$0.code.isEmpty && !$0.name.isEmpty && $0.unitPriceCents >= 0 }
    }

    private func loadDraft() {
        guard let active, loadedFrom != active.id else { return }
        loadedFrom = active.id
        name = active.isLocalSample ? String(localized: "Standard") : active.name
        vatPercent = Decimal(active.vatRateBasisPoints) / 100
        // Same ids as the active version – room selections survive the publish.
        items = active.items
    }

    private func publish() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let vat = (vatPercent * 100).roundedInt
            // The local sample book is unknown to the server → create a new book.
            let bookID = active.flatMap { $0.isLocalSample ? nil : $0.priceBookID }
            try await backend.publishPriceBook(priceBookID: bookID, name: name, vatRateBasisPoints: vat, items: items)
            await sync.syncNow()
            loadedFrom = nil
            loadDraft()
            message = String(localized: "Published. All devices receive the new prices on their next sync.")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func activate(_ version: PriceBookVersion) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await backend.activatePriceBookVersion(version.id)
            await sync.syncNow()
            message = String(localized: "Version \(version.version) is active again.")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Edits one price item (price entered in euros, stored in cents).
private struct PriceItemEditor: View {
    @Binding var item: PriceItem

    var body: some View {
        Form {
            Section("Item") {
                TextField("Code", text: $item.code)
                    .textInputAutocapitalization(.characters)
                TextField("Name", text: $item.name)
                Picker("Billed by", selection: $item.basis) {
                    ForEach(QuantityBasis.allCases) { basis in
                        Text(basis.title).tag(basis)
                    }
                }
                LabeledContent("Price per \(item.unit.symbol)") {
                    TextField("Price", value: euros, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                    Text("€").foregroundStyle(.secondary)
                }
                Stepper("Default waste: \(item.defaultWastePercent) %", value: $item.defaultWastePercent, in: 0...50, step: 5)
            }
            if item.basis == .wallArea {
                Section("Openings (doors, windows)") {
                    Picker("Deduction", selection: $item.openingRule.mode) {
                        Text("None").tag(OpeningRule.Mode.none)
                        Text("All openings").tag(OpeningRule.Mode.all)
                        Text("Above threshold").tag(OpeningRule.Mode.aboveThreshold)
                    }
                    if item.openingRule.mode == .aboveThreshold {
                        MeterField(title: "Threshold (m²)", value: $item.openingRule.thresholdM2)
                    }
                    if item.openingRule.mode != .none {
                        Toggle("Add reveals", isOn: $item.openingRule.addReveals)
                        if item.openingRule.addReveals {
                            MeterField(title: "Reveal depth", value: $item.openingRule.revealDepthM)
                        }
                    }
                }
            }
        }
        .navigationTitle(item.name.isEmpty ? String(localized: "New item") : item.name)
    }

    private var euros: Binding<Decimal> {
        Binding(
            get: { Decimal(item.unitPriceCents) / 100 },
            set: { item.unitPriceCents = ($0 * 100).roundedInt }
        )
    }
}

private extension Decimal {
    /// Rounded half away from zero to a whole number (commercial rounding).
    var roundedInt: Int {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, 0, .plain)
        return NSDecimalNumber(decimal: result).intValue
    }
}
