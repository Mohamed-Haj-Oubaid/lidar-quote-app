import Foundation
import SwiftData

/// An invoice (Rechnung) created from an accepted quote. Immutable once issued
/// except for the payment date. Keeps its own copy of buyer and seller data, so
/// it stays complete for the 10-year retention period even if the job is deleted
/// or the client's data is erased. Device-local.
@Model
final class Invoice {
    @Attribute(.unique) var id: UUID
    var number: String
    var issuedAt: Date
    /// Date of service (Leistungsdatum) – mandatory on German invoices (§ 14 UStG).
    var serviceDate: Date
    var dueDate: Date
    var quoteID: UUID?
    var quoteNumber: String
    var calculationData: Data
    var buyerName: String
    var buyerAddress: String
    var buyerEmail: String
    var projectTitle: String
    @Attribute(.externalStorage) var pdfData: Data?
    var paidAt: Date?
    var job: Job?

    init(id: UUID = UUID(), number: String, serviceDate: Date, dueDate: Date, quote: Quote, calculation: QuoteCalculation, job: Job) {
        self.id = id
        self.number = number
        self.issuedAt = .now
        self.serviceDate = serviceDate
        self.dueDate = dueDate
        self.quoteID = quote.id
        self.quoteNumber = quote.displayNumber
        self.calculationData = (try? StoreCoding.encoder.encode(calculation)) ?? Data()
        self.buyerName = job.clientName
        self.buyerAddress = job.siteAddress
        self.buyerEmail = job.clientEmail
        self.projectTitle = job.title
        self.job = job
    }

    @Transient private var cachedCalculation: QuoteCalculation?

    var calculation: QuoteCalculation? {
        if let cachedCalculation { return cachedCalculation }
        let decoded = try? StoreCoding.decoder.decode(QuoteCalculation.self, from: calculationData)
        cachedCalculation = decoded
        return decoded
    }

    var isPaid: Bool { paidAt != nil }
}

extension Invoice {
    /// XRechnung input from this invoice and the company settings.
    func eInvoiceData(settings: TenantSettings) -> EInvoiceData? {
        guard let calculation else { return nil }
        let sellerAddress = InvoiceParty.address(settings.firmAddress)
        let buyerParts = InvoiceParty.address(self.buyerAddress)
        let seller = InvoiceParty(name: settings.firmName, street: sellerAddress.street, postalCode: sellerAddress.postalCode,
                                  city: sellerAddress.city, email: settings.email, phone: settings.phone,
                                  vatID: settings.vatID, taxNumber: settings.taxNumber)
        let buyer = InvoiceParty(name: buyerName, street: buyerParts.street, postalCode: buyerParts.postalCode,
                                 city: buyerParts.city, email: buyerEmail)
        let terms = settings.paymentTerms.isEmpty
            ? String(localized: "Payable by \(dueDate.formatted(date: .long, time: .omitted)) without deduction.")
            : settings.paymentTerms
        return EInvoiceData(number: number, issueDate: issuedAt, dueDate: dueDate, serviceDate: serviceDate,
                            buyerReference: projectTitle.isEmpty ? number : projectTitle,
                            seller: seller, buyer: buyer, iban: settings.bankIBAN, paymentTerms: terms, calculation: calculation)
    }
}
