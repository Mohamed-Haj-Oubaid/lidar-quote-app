import SwiftUI
import SwiftData
import PDFKit

/// Live calculation for all rooms of a job; "Issue" freezes it into an immutable quote revision.
struct QuoteBuilderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Environment(BackendClient.self) private var backend
    let job: Job

    @Query(filter: #Predicate<PriceBookVersion> { $0.isActive }, sort: \PriceBookVersion.version, order: .reverse)
    private var priceBooks: [PriceBookVersion]
    @State private var issuedQuote: Quote?
    @State private var errorMessage: String?
    @State private var samplePreview: SamplePreview?
    /// Recomputed only when the inputs change (see `inputsKey`), not on every body evaluation.
    @State private var calculation: QuoteCalculation?

    private var canSeePrices: Bool { backend.session?.role?.canSeePrices ?? true }

    /// Quotes from the local sample book can never get an official number on the server.
    private var usesSamplePriceBook: Bool { priceBooks.first?.isLocalSample == true }

    var body: some View {
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
                                if canSeePrices {
                                    Text(Formatters.money(line.totalCents))
                                        .monospacedDigit()
                                }
                            }
                            if canSeePrices {
                                Text("\(line.roomName) · \(Formatters.quantity(line.billedQuantityHundredths, unit: line.unit)) × \(Formatters.money(line.unitPriceCents))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let material = line.materialCents, let labor = line.laborCents {
                                    Text("Material \(Formatters.money(material)) · labour \(Formatters.money(labor))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("\(line.roomName) · \(Formatters.quantity(line.billedQuantityHundredths, unit: line.unit))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let note = line.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if canSeePrices {
                    Section("Totals") {
                        if let labor = calculation.laborTotalCents {
                            LabeledContent("Material (net)", value: Formatters.money(calculation.netTotalCents - labor))
                            LabeledContent("Labour (net)", value: Formatters.money(labor))
                        }
                        LabeledContent("Net", value: Formatters.money(calculation.netTotalCents))
                        LabeledContent("VAT", value: Formatters.money(calculation.vatCents))
                        LabeledContent("Gross", value: Formatters.money(calculation.grossTotalCents))
                            .font(.headline)
                    }
                } else {
                    Section {
                        Label("Prices are visible to the owner and admins.", systemImage: "eye.slash")
                            .foregroundStyle(.secondary)
                    }
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
        .navigationDestination(item: canSeePrices ? $issuedQuote : .constant(nil)) { quote in
            QuotePreviewView(quote: quote)
        }
        .task(id: inputsKey) { calculation = currentCalculation }
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

    /// Cheap fingerprint of everything the calculation depends on.
    private var inputsKey: String {
        let rooms = job.sortedSurveys.map { "\($0.id)|\($0.roomName)|\($0.updatedAt.timeIntervalSinceReferenceDate)" }
        return ([priceBooks.first?.id.uuidString ?? "-"] + rooms).joined(separator: ";")
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
    @Environment(\.modelContext) private var modelContext
    let quote: Quote
    @State private var shareURL: URL?
    @State private var isSigning = false
    @State private var isCreatingInvoice = false
    @State private var mail: MailDraft?
    @State private var openedInvoice: Invoice?

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
        .task(id: quote.pdfData) { writeShareFile() }
        .sheet(isPresented: $isSigning) {
            NavigationStack { SignQuoteView(quote: quote) }
        }
        .sheet(isPresented: $isCreatingInvoice) {
            NavigationStack {
                CreateInvoiceView(quote: quote) { invoice in openedInvoice = invoice }
            }
        }
        .sheet(item: $mail) { draft in
            MailComposer(draft: draft) { sent in
                if sent { try? LocalStore.markQuoteSent(quote, in: modelContext) }
                mail = nil
            }
            .ignoresSafeArea()
        }
        .navigationDestination(item: $openedInvoice) { invoice in
            InvoiceView(invoice: invoice)
        }
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
        .safeAreaInset(edge: .bottom) {
            if let signedAt = quote.clientSignedAt, quote.status == "accepted" {
                Label(quote.clientSignaturePNG == nil
                      ? String(localized: "Accepted \(signedAt.formatted(date: .abbreviated, time: .shortened))")
                      : String(localized: "Signed by \(quote.clientSignerName) · \(signedAt.formatted(date: .abbreviated, time: .shortened))"),
                      systemImage: "signature")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .toolbar {
            if let url = shareURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Actions", systemImage: "ellipsis.circle") {
                    if LocalStore.allowedStatusChanges(for: quote).contains("accepted") {
                        Button("Client Signs Quote", systemImage: "signature") { isSigning = true }
                    }
                    Button("Send by E-mail", systemImage: "envelope") { composeMail() }
                        .disabled(!MailComposer.canSendMail || quote.pdfData == nil)
                    if quote.status == "accepted" {
                        if let invoice = invoiceForQuote {
                            Button("Show Invoice \(invoice.number)", systemImage: "eurosign.circle") { openedInvoice = invoice }
                        } else {
                            Button("Create Invoice", systemImage: "eurosign.circle") { isCreatingInvoice = true }
                        }
                    }
                }
            }
            let changes = LocalStore.allowedStatusChanges(for: quote)
            if !changes.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        ForEach(changes, id: \.self) { status in
                            Button(QuoteStatus.actionTitle(status)) {
                                try? LocalStore.setStatus(status, of: quote, in: modelContext)
                            }
                        }
                    }
                }
            }
        }
    }

    private var invoiceForQuote: Invoice? {
        quote.job?.invoices.first { $0.quoteID == quote.id }
    }

    private func composeMail() {
        guard let job = quote.job else { return }
        mail = MailDrafts.quote(quote, job: job, settings: LocalStore.settings(in: modelContext))
    }

    /// Writes the share file once per PDF version (not on every render).
    private func writeShareFile() {
        guard let data = quote.pdfData else {
            shareURL = nil
            return
        }
        LocalStore.removeSharedPDFs()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.fileName(for: quote.displayNumber)).pdf")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            shareURL = url
        } catch {
            shareURL = nil
        }
    }

    /// Quote numbers become file names: no path separators or colons.
    static func fileName(for number: String) -> String {
        let cleaned = number.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Quote" : cleaned
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

/// Display texts for the quote lifecycle.
enum QuoteStatus {
    static func title(_ status: String) -> String {
        switch status {
        case "sent": String(localized: "Sent")
        case "accepted": String(localized: "Accepted")
        case "rejected": String(localized: "Rejected")
        case "superseded": String(localized: "Superseded")
        default: String(localized: "Issued")
        }
    }

    static func actionTitle(_ status: String) -> String {
        switch status {
        case "sent": String(localized: "Mark as Sent")
        case "accepted": String(localized: "Accepted")
        default: String(localized: "Rejected")
        }
    }
}
