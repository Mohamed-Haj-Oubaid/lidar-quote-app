import SwiftUI
import SwiftData
import PDFKit

/// Live calculation for all rooms of a job; "Issue" freezes it into an immutable quote revision.
struct QuoteBuilderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    let job: Job

    @Query(filter: #Predicate<PriceBookVersion> { $0.isActive }, sort: \PriceBookVersion.version, order: .reverse)
    private var priceBooks: [PriceBookVersion]
    @State private var issuedQuote: Quote?
    @State private var errorMessage: String?
    @State private var samplePreview: SamplePreview?

    /// Quotes from the local sample book can never get an official number on the server.
    private var usesSamplePriceBook: Bool { priceBooks.first?.isLocalSample == true }

    var body: some View {
        let calculation = currentCalculation
        List {
            if let calculation {
                Section("Price book") {
                    LabeledContent(calculation.priceBookName, value: "v\(calculation.priceBookVersion)")
                    LabeledContent("Engine", value: calculation.engineVersion)
                }
                Section("Items") {
                    if calculation.lines.isEmpty {
                        Text("Select services & materials for each room first.")
                            .foregroundStyle(.secondary)
                    }
                    // Offsets: lines of old (1.0.0) quotes may share an id.
                    ForEach(Array(calculation.lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(line.itemName)
                                Spacer()
                                Text(Formatters.money(line.totalCents))
                                    .monospacedDigit()
                            }
                            Text("\(line.roomName) · \(Formatters.quantity(line.billedQuantityHundredths, unit: line.unit)) × \(Formatters.money(line.unitPriceCents))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let note = line.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Totals") {
                    LabeledContent("Net", value: Formatters.money(calculation.netTotalCents))
                    LabeledContent("VAT", value: Formatters.money(calculation.vatCents))
                    LabeledContent("Gross", value: Formatters.money(calculation.grossTotalCents))
                        .font(.headline)
                }
            } else {
                ContentUnavailableView("No Price Book", systemImage: "list.bullet.rectangle")
            }
            if usesSamplePriceBook {
                Section {
                    Label("Sample prices – sign in and sync to issue real quotes.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Preview PDF", systemImage: "doc.text.magnifyingglass") { preview(calculation) }
                        .disabled(calculation?.lines.isEmpty ?? true)
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("New Quote")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Issue Quote") { issue(calculation) }
                    .disabled(usesSamplePriceBook || (calculation?.lines.isEmpty ?? true))
            }
        }
        .navigationDestination(item: $issuedQuote) { quote in
            QuotePreviewView(quote: quote)
        }
        .sheet(item: $samplePreview) { preview in
            NavigationStack {
                PDFKitView(data: preview.data)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Sample Preview")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { samplePreview = nil }
                        }
                    }
            }
        }
    }

    /// Watermarked PDF only – creates no quote, no outbox entry, uses no provisional number.
    private func preview(_ calculation: QuoteCalculation?) {
        guard let calculation,
              let data = PDFGenerator.renderSamplePreview(calculation: calculation, job: job, settings: LocalStore.settings(in: modelContext))
        else { return }
        samplePreview = SamplePreview(data: data)
    }

    private var currentCalculation: QuoteCalculation? {
        guard let book = priceBooks.first else { return nil }
        let rooms = job.sortedSurveys.map { RoomInput(surveyID: $0.id, roomName: $0.roomName, measurement: $0.measurement, selections: $0.selections) }
        return EstimationEngine.calculate(rooms: rooms, priceBook: book.snapshot)
    }

    private func issue(_ calculation: QuoteCalculation?) {
        guard let calculation, !usesSamplePriceBook else { return }
        do {
            issuedQuote = try LocalStore.issueQuote(for: job, calculation: calculation, in: modelContext)
            Task { await sync.syncNow() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SamplePreview: Identifiable {
    let id = UUID()
    let data: Data
}

/// PDF preview with sharing through the system share sheet (Mail, AirDrop, Messages, …).
struct QuotePreviewView: View {
    let quote: Quote

    var body: some View {
        Group {
            if let data = quote.pdfData {
                PDFKitView(data: data)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("PDF Not Available", systemImage: "doc")
            }
        }
        .navigationTitle(quote.displayNumber)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            if quote.isProvisional {
                Label("Provisional number – the official number is assigned on the next sync.", systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.15))
            }
        }
        .toolbar {
            if let url = shareURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url)
                }
            }
        }
    }

    /// Writes the PDF to a temporary file named after the quote number for sharing.
    private var shareURL: URL? {
        guard let data = quote.pdfData else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(quote.displayNumber).pdf")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data {
            view.document = PDFDocument(data: data)
        }
    }
}
