import SwiftUI
import SwiftData
import PencilKit
import MessageUI

// MARK: - Client signature

/// The client signs the quote on the device; the quote becomes an order.
struct SignQuoteView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let quote: Quote

    @State private var signerName = ""
    @State private var drawing = PKDrawing()
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if let calculation = quote.calculation {
                    LabeledContent("Quote", value: quote.displayNumber)
                    LabeledContent("Gross total", value: Formatters.money(calculation.grossTotalCents))
                }
            }
            Section("Client") {
                TextField("Full name", text: $signerName)
                    .textContentType(.name)
            }
            Section {
                SignaturePad(drawing: $drawing)
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                Button("Clear Signature", systemImage: "eraser", role: .destructive) { drawing = PKDrawing() }
                    .disabled(drawing.strokes.isEmpty)
            } header: {
                Text("Signature")
            } footer: {
                Text("With the signature the client accepts the quote and orders the listed services at the stated prices.")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Client Signature")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { signerName = quote.job?.clientName ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Accept Quote") { sign() }
                    .disabled(drawing.strokes.isEmpty || signerName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func sign() {
        do {
            try LocalStore.signQuote(quote, signerName: signerName, signature: SignaturePad.image(of: drawing), in: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - E-mail

struct MailAttachment: Hashable {
    var data: Data
    var mimeType: String
    var fileName: String
}

struct MailDraft: Identifiable {
    let id = UUID()
    var recipients: [String]
    var subject: String
    var body: String
    var attachments: [MailAttachment]
}

/// System mail composer. Reports whether the mail was sent.
struct MailComposer: UIViewControllerRepresentable {
    let draft: MailDraft
    let completion: (Bool) -> Void

    static var canSendMail: Bool { MFMailComposeViewController.canSendMail() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(draft.recipients)
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        for attachment in draft.attachments {
            controller.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            completion(result == .sent)
        }
    }
}

enum MailDrafts {
    /// Quote PDF plus measurement report, addressed to the client.
    static func quote(_ quote: Quote, job: Job, settings: TenantSettings) -> MailDraft? {
        guard let pdf = quote.pdfData else { return nil }
        let number = quote.displayNumber
        var attachments = [MailAttachment(data: pdf, mimeType: "application/pdf", fileName: "\(QuotePreviewView.fileName(for: number)).pdf")]
        if !job.surveys.isEmpty {
            attachments.append(MailAttachment(data: AufmassPDF.render(job: job, settings: settings), mimeType: "application/pdf",
                                              fileName: "\(QuotePreviewView.fileName(for: String(localized: "Measurement Report \(number)"))).pdf"))
        }
        let greeting = job.clientName.isEmpty ? String(localized: "Dear Sir or Madam,") : String(localized: "Dear \(job.clientName),")
        let body = [
            greeting, "",
            String(localized: "Thank you for your inquiry. Attached you will find our quote \(number) for “\(job.title)” and the measurement report."),
            String(localized: "We would be pleased to receive your order. Please do not hesitate to contact us if you have any questions."),
            "", String(localized: "Kind regards"), settings.firmName, settings.phone,
        ].joined(separator: "\n")
        return MailDraft(recipients: job.clientEmail.isEmpty ? [] : [job.clientEmail],
                         subject: String(localized: "Quote \(number) – \(settings.firmName)"),
                         body: body, attachments: attachments)
    }

    /// Invoice PDF plus XRechnung XML.
    static func invoice(_ invoice: Invoice, settings: TenantSettings) -> MailDraft? {
        guard let pdf = invoice.pdfData else { return nil }
        let name = QuotePreviewView.fileName(for: invoice.number)
        var attachments = [MailAttachment(data: pdf, mimeType: "application/pdf", fileName: "\(name).pdf")]
        if let data = invoice.eInvoiceData(settings: settings) {
            attachments.append(MailAttachment(data: Data(EInvoice.xrechnungXML(data).utf8), mimeType: "application/xml",
                                              fileName: "\(name)-xrechnung.xml"))
        }
        let greeting = invoice.buyerName.isEmpty ? String(localized: "Dear Sir or Madam,") : String(localized: "Dear \(invoice.buyerName),")
        let body = [
            greeting, "",
            String(localized: "Attached you will find our invoice \(invoice.number) as PDF and as e-invoice (XRechnung)."),
            String(localized: "Thank you for your order."),
            "", String(localized: "Kind regards"), settings.firmName, settings.phone,
        ].joined(separator: "\n")
        return MailDraft(recipients: invoice.buyerEmail.isEmpty ? [] : [invoice.buyerEmail],
                         subject: String(localized: "Invoice \(invoice.number) – \(settings.firmName)"),
                         body: body, attachments: attachments)
    }
}

// MARK: - Invoices

/// Choose the date of service and create the invoice.
struct CreateInvoiceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let quote: Quote
    let created: (Invoice) -> Void

    @State private var serviceDate = Date.now
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Quote", value: quote.displayNumber)
                if let calculation = quote.calculation {
                    LabeledContent("Gross total", value: Formatters.money(calculation.grossTotalCents))
                }
                DatePicker("Date of service", selection: $serviceDate, displayedComponents: .date)
            } footer: {
                Text("German invoices must state when the work was carried out (§ 14 UStG). The invoice number is assigned automatically and never repeats.")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Create Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    do {
                        let invoice = try LocalStore.createInvoice(from: quote, serviceDate: serviceDate, in: modelContext)
                        dismiss()
                        created(invoice)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

/// Invoice PDF with e-mail, XRechnung export and payment tracking.
struct InvoiceView: View {
    @Environment(\.modelContext) private var modelContext
    let invoice: Invoice

    @State private var mail: MailDraft?
    @State private var shareFiles: [URL] = []
    @State private var missingFields: [String] = []

    var body: some View {
        Group {
            if let data = invoice.pdfData {
                PDFKitView(data: data).ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("PDF Not Available", systemImage: "doc")
            }
        }
        .navigationTitle(invoice.number)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 4) {
                if let paidAt = invoice.paidAt {
                    Label("Paid on \(paidAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Due \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))", systemImage: "clock")
                        .foregroundStyle(invoice.dueDate < .now ? .red : .orange)
                }
                if !missingFields.isEmpty {
                    Text("E-invoice incomplete – missing: \(missingFields.joined(separator: ", "))")
                        .foregroundStyle(.red)
                }
            }
            .font(.footnote)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !shareFiles.isEmpty {
                    ShareLink(items: shareFiles)
                }
                Button("Send by E-mail", systemImage: "envelope") {
                    mail = MailDrafts.invoice(invoice, settings: LocalStore.settings(in: modelContext))
                }
                .disabled(!MailComposer.canSendMail)
            }
            if !invoice.isPaid {
                ToolbarItem(placement: .bottomBar) {
                    Button("Mark as Paid", systemImage: "checkmark.circle") {
                        try? LocalStore.markPaid(invoice, in: modelContext)
                    }
                }
            }
        }
        .sheet(item: $mail) { draft in
            MailComposer(draft: draft) { _ in mail = nil }
                .ignoresSafeArea()
        }
        .task(id: invoice.id) { prepareFiles() }
    }

    /// PDF + XRechnung XML as share files.
    private func prepareFiles() {
        let settings = LocalStore.settings(in: modelContext)
        var files: [URL] = []
        if let pdf = invoice.pdfData, let file = try? PDFFile.make(pdf, name: invoice.number) { files.append(file.url) }
        if let data = invoice.eInvoiceData(settings: settings) {
            missingFields = EInvoice.missingFields(data)
            if let xml = try? PDFFile.make(Data(EInvoice.xrechnungXML(data).utf8), name: "\(invoice.number)-xrechnung", fileExtension: "xml") {
                files.append(xml.url)
            }
        }
        shareFiles = files
    }
}

/// All invoices of the company on this device, with the DATEV export for the tax advisor.
struct InvoicesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Invoice.issuedAt, order: .reverse) private var invoices: [Invoice]

    @AppStorage("datevConsultantNumber") private var consultantNumber = ""
    @AppStorage("datevClientNumber") private var clientNumber = ""
    @State private var from = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
    @State private var to = Date.now
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section {
                ForEach(invoices) { invoice in
                    NavigationLink {
                        InvoiceView(invoice: invoice)
                    } label: {
                        InvoiceRow(invoice: invoice)
                    }
                }
                if invoices.isEmpty {
                    Text("No invoices yet. Create one from an accepted quote.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Invoices are stored on this device only. Export them regularly (PDF, XRechnung, DATEV) – they must be kept for 10 years.")
            }

            Section {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
                TextField("Consultant number (Beraternummer)", text: $consultantNumber).keyboardType(.numberPad)
                TextField("Client number (Mandantennummer)", text: $clientNumber).keyboardType(.numberPad)
                DatevAccountsFields()
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share DATEV File", systemImage: "square.and.arrow.up") }
                }
                Button("Create DATEV Export", systemImage: "tablecells") { export() }
                    .disabled(periodInvoices.isEmpty)
            } header: {
                Text("DATEV export")
            } footer: {
                Text("Booking batch (EXTF) with one booking per invoice: debtor account to revenue account. Please have your tax advisor check the accounts.")
            }
        }
        .navigationTitle("Invoices")
    }

    private var periodInvoices: [Invoice] {
        let start = Calendar.current.startOfDay(for: from)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) ?? to
        return invoices.filter { $0.issuedAt >= start && $0.issuedAt < end }
    }

    private func export() {
        let settings = LocalStore.settings(in: modelContext)
        let bookings = periodInvoices.compactMap { invoice -> EInvoice.DatevBooking? in
            guard let calculation = invoice.calculation else { return nil }
            return EInvoice.DatevBooking(grossCents: calculation.grossTotalCents, date: invoice.issuedAt,
                                         invoiceNumber: invoice.number, text: invoice.buyerName.isEmpty ? invoice.projectTitle : invoice.buyerName)
        }
        let csv = EInvoice.datevCSV(bookings, settings: .init(consultantNumber: consultantNumber, clientNumber: clientNumber,
                                                              revenueAccount: settings.datevRevenueAccount,
                                                              debtorAccount: settings.datevDebtorAccount),
                                    from: from, to: to)
        // DATEV expects Windows-1252 (ANSI) text.
        let data = csv.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(csv.utf8)
        exportURL = try? PDFFile.make(data, name: "EXTF_Buchungsstapel_\(from.formatted(.iso8601.year().month().day()))", fileExtension: "csv").url
    }
}

private struct DatevAccountsFields: View {
    @Environment(\.modelContext) private var modelContext
    @State private var revenue = ""
    @State private var debtor = ""

    var body: some View {
        Group {
            LabeledContent("Revenue account") {
                TextField("8400", text: $revenue).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Debtor account") {
                TextField("10000", text: $debtor).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
        }
        .onAppear {
            let settings = LocalStore.settings(in: modelContext)
            revenue = settings.datevRevenueAccount
            debtor = settings.datevDebtorAccount
        }
        .onChange(of: revenue) { _, value in store { $0.datevRevenueAccount = value } }
        .onChange(of: debtor) { _, value in store { $0.datevDebtorAccount = value } }
    }

    private func store(_ change: (TenantSettings) -> Void) {
        change(LocalStore.settings(in: modelContext))
        try? modelContext.save()
    }
}

struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(invoice.number).font(.headline.monospaced())
                Text("\(invoice.buyerName.isEmpty ? invoice.projectTitle : invoice.buyerName) · \(invoice.issuedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let calculation = invoice.calculation {
                    Text(Formatters.money(calculation.grossTotalCents)).font(.subheadline.monospacedDigit())
                }
                Text(invoice.isPaid ? String(localized: "Paid") : (invoice.dueDate < .now ? String(localized: "Overdue") : String(localized: "Open")))
                    .font(.caption2.bold())
                    .foregroundStyle(invoice.isPaid ? .green : (invoice.dueDate < .now ? .red : .orange))
            }
        }
    }
}
