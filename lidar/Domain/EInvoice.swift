import Foundation

/// Party data printed on an e-invoice.
nonisolated struct InvoiceParty: Hashable {
    var name: String
    var street: String
    var postalCode: String
    var city: String
    var countryCode = "DE"
    var email: String
    var phone: String = ""
    var vatID: String = ""
    var taxNumber: String = ""

    /// Splits a free-text address ("Street 1\n12345 City" or "Street 1, 12345 City").
    static func address(_ text: String) -> (street: String, postalCode: String, city: String) {
        let parts = text.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var street = "", postal = "", city = ""
        for part in parts {
            if postal.isEmpty, let match = part.firstMatch(of: /^(\d{4,5})\s+(.+)$/) {
                postal = String(match.1)
                city = String(match.2)
            } else if street.isEmpty {
                street = part
            }
        }
        return (street, postal, city)
    }
}

/// Everything needed to write an XRechnung (EN 16931, UBL 2.1 syntax).
nonisolated struct EInvoiceData: Hashable {
    var number: String
    var issueDate: Date
    var dueDate: Date
    var serviceDate: Date
    var buyerReference: String
    var seller: InvoiceParty
    var buyer: InvoiceParty
    var iban: String
    var paymentTerms: String
    var calculation: QuoteCalculation
}

/// Writes German e-invoices (XRechnung 3.0, UBL) and DATEV booking exports.
nonisolated enum EInvoice {
    static let customizationID = "urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0"
    static let profileID = "urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"

    /// UN/ECE Rec. 20 unit codes.
    static func unitCode(_ unit: PricingUnit) -> String {
        switch unit {
        case .squareMeter: "MTK"
        case .linearMeter: "MTR"
        case .piece: "H87"
        }
    }

    static func xrechnungXML(_ data: EInvoiceData) -> String {
        let c = data.calculation
        let vatPercent = decimal(Double(c.vatRateBasisPoints) / 100)
        func amount(_ cents: Int) -> String { decimal(Double(cents) / 100, digits: 2) }
        func date(_ value: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: value)
        }
        func party(_ p: InvoiceParty, isSeller: Bool) -> String {
            var xml = """
                <cac:Party>
                  <cbc:EndpointID schemeID="EM">\(escape(p.email))</cbc:EndpointID>
                  <cac:PartyName><cbc:Name>\(escape(p.name))</cbc:Name></cac:PartyName>
                  <cac:PostalAddress>
                    <cbc:StreetName>\(escape(p.street))</cbc:StreetName>
                    <cbc:CityName>\(escape(p.city))</cbc:CityName>
                    <cbc:PostalZone>\(escape(p.postalCode))</cbc:PostalZone>
                    <cac:Country><cbc:IdentificationCode>\(p.countryCode)</cbc:IdentificationCode></cac:Country>
                  </cac:PostalAddress>

            """
            if isSeller, !p.vatID.isEmpty {
                xml += """
                      <cac:PartyTaxScheme>
                        <cbc:CompanyID>\(escape(p.vatID))</cbc:CompanyID>
                        <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
                      </cac:PartyTaxScheme>

                """
            }
            if isSeller, !p.taxNumber.isEmpty {
                xml += """
                      <cac:PartyTaxScheme>
                        <cbc:CompanyID>\(escape(p.taxNumber))</cbc:CompanyID>
                        <cac:TaxScheme><cbc:ID>FC</cbc:ID></cac:TaxScheme>
                      </cac:PartyTaxScheme>

                """
            }
            xml += """
                  <cac:PartyLegalEntity><cbc:RegistrationName>\(escape(p.name))</cbc:RegistrationName></cac:PartyLegalEntity>

            """
            if isSeller {
                xml += """
                      <cac:Contact>
                        <cbc:Name>\(escape(p.name))</cbc:Name>
                        <cbc:Telephone>\(escape(p.phone))</cbc:Telephone>
                        <cbc:ElectronicMail>\(escape(p.email))</cbc:ElectronicMail>
                      </cac:Contact>

                """
            }
            xml += "    </cac:Party>"
            return xml
        }

        let lines = c.lines.enumerated().map { index, line in
            """
              <cac:InvoiceLine>
                <cbc:ID>\(index + 1)</cbc:ID>
                <cbc:InvoicedQuantity unitCode="\(unitCode(line.unit))">\(decimal(line.billedQuantity, digits: 2))</cbc:InvoicedQuantity>
                <cbc:LineExtensionAmount currencyID="EUR">\(amount(line.totalCents))</cbc:LineExtensionAmount>
                <cac:Item>
                  <cbc:Description>\(escape(line.roomName))</cbc:Description>
                  <cbc:Name>\(escape(line.itemName))</cbc:Name>
                  <cac:SellersItemIdentification><cbc:ID>\(escape(line.itemCode))</cbc:ID></cac:SellersItemIdentification>
                  <cac:ClassifiedTaxCategory>
                    <cbc:ID>S</cbc:ID>
                    <cbc:Percent>\(vatPercent)</cbc:Percent>
                    <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
                  </cac:ClassifiedTaxCategory>
                </cac:Item>
                <cac:Price><cbc:PriceAmount currencyID="EUR">\(amount(line.unitPriceCents))</cbc:PriceAmount></cac:Price>
              </cac:InvoiceLine>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
                 xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
                 xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
          <cbc:CustomizationID>\(customizationID)</cbc:CustomizationID>
          <cbc:ProfileID>\(profileID)</cbc:ProfileID>
          <cbc:ID>\(escape(data.number))</cbc:ID>
          <cbc:IssueDate>\(date(data.issueDate))</cbc:IssueDate>
          <cbc:DueDate>\(date(data.dueDate))</cbc:DueDate>
          <cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>
          <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
          <cbc:BuyerReference>\(escape(data.buyerReference))</cbc:BuyerReference>
          <cac:AccountingSupplierParty>
        \(party(data.seller, isSeller: true))
          </cac:AccountingSupplierParty>
          <cac:AccountingCustomerParty>
        \(party(data.buyer, isSeller: false))
          </cac:AccountingCustomerParty>
          <cac:Delivery><cbc:ActualDeliveryDate>\(date(data.serviceDate))</cbc:ActualDeliveryDate></cac:Delivery>
          <cac:PaymentMeans>
            <cbc:PaymentMeansCode>58</cbc:PaymentMeansCode>
            <cbc:PaymentID>\(escape(data.number))</cbc:PaymentID>
            <cac:PayeeFinancialAccount><cbc:ID>\(escape(data.iban.replacingOccurrences(of: " ", with: "")))</cbc:ID></cac:PayeeFinancialAccount>
          </cac:PaymentMeans>
          <cac:PaymentTerms><cbc:Note>\(escape(data.paymentTerms))</cbc:Note></cac:PaymentTerms>
          <cac:TaxTotal>
            <cbc:TaxAmount currencyID="EUR">\(amount(c.vatCents))</cbc:TaxAmount>
            <cac:TaxSubtotal>
              <cbc:TaxableAmount currencyID="EUR">\(amount(c.netTotalCents))</cbc:TaxableAmount>
              <cbc:TaxAmount currencyID="EUR">\(amount(c.vatCents))</cbc:TaxAmount>
              <cac:TaxCategory>
                <cbc:ID>S</cbc:ID>
                <cbc:Percent>\(vatPercent)</cbc:Percent>
                <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
              </cac:TaxCategory>
            </cac:TaxSubtotal>
          </cac:TaxTotal>
          <cac:LegalMonetaryTotal>
            <cbc:LineExtensionAmount currencyID="EUR">\(amount(c.netTotalCents))</cbc:LineExtensionAmount>
            <cbc:TaxExclusiveAmount currencyID="EUR">\(amount(c.netTotalCents))</cbc:TaxExclusiveAmount>
            <cbc:TaxInclusiveAmount currencyID="EUR">\(amount(c.grossTotalCents))</cbc:TaxInclusiveAmount>
            <cbc:PayableAmount currencyID="EUR">\(amount(c.grossTotalCents))</cbc:PayableAmount>
          </cac:LegalMonetaryTotal>
        \(lines)
        </Invoice>

        """
    }

    /// Fields the XRechnung validator rejects when empty.
    static func missingFields(_ data: EInvoiceData) -> [String] {
        var missing: [String] = []
        if data.seller.name.isEmpty { missing.append(String(localized: "Company name")) }
        if data.seller.street.isEmpty || data.seller.postalCode.isEmpty || data.seller.city.isEmpty {
            missing.append(String(localized: "Company address (street, postal code and city)"))
        }
        if data.seller.email.isEmpty { missing.append(String(localized: "Company e-mail")) }
        if data.seller.phone.isEmpty { missing.append(String(localized: "Company phone")) }
        if data.seller.vatID.isEmpty && data.seller.taxNumber.isEmpty { missing.append(String(localized: "VAT ID or tax number")) }
        if data.iban.isEmpty { missing.append("IBAN") }
        if data.buyer.name.isEmpty { missing.append(String(localized: "Client name")) }
        if data.buyer.email.isEmpty { missing.append(String(localized: "Client e-mail")) }
        if data.buyer.postalCode.isEmpty || data.buyer.city.isEmpty { missing.append(String(localized: "Client address with postal code and city")) }
        return missing
    }

    // MARK: - DATEV

    struct DatevSettings: Hashable {
        var consultantNumber: String
        var clientNumber: String
        var revenueAccount: String
        var debtorAccount: String
    }

    struct DatevBooking: Hashable {
        var grossCents: Int
        var date: Date
        var invoiceNumber: String
        var text: String
    }

    /// DATEV-Format "Buchungsstapel" (EXTF 700): one debit booking debtor → revenue per invoice.
    /// The revenue account is an automatic VAT account (e.g. SKR03 8400), so no tax key is needed.
    static func datevCSV(_ bookings: [DatevBooking], settings: DatevSettings, from: Date, to: Date, created: Date = .now) -> String {
        func format(_ date: Date, _ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        func quoted(_ text: String, max: Int) -> String {
            "\"" + String(text.replacingOccurrences(of: "\"", with: "'").prefix(max)) + "\""
        }
        let yearStart = Calendar(identifier: .gregorian).date(from: DateComponents(year: Calendar.current.component(.year, from: from), month: 1, day: 1)) ?? from
        let header = [
            "\"EXTF\"", "700", "21", "\"Buchungsstapel\"", "13", format(created, "yyyyMMddHHmmssSSS"), "", "\"RE\"", "\"LiDAR Quote\"", "\"\"",
            settings.consultantNumber, settings.clientNumber, format(yearStart, "yyyyMMdd"), "4",
            format(from, "yyyyMMdd"), format(to, "yyyyMMdd"), "\"Ausgangsrechnungen\"", "\"\"", "1", "0", "0", "\"EUR\"",
        ].joined(separator: ";")
        let columns = [
            "Umsatz (ohne Soll/Haben-Kz)", "Soll/Haben-Kennzeichen", "WKZ Umsatz", "Kurs", "Basis-Umsatz", "WKZ Basis-Umsatz",
            "Konto", "Gegenkonto (ohne BU-Schlüssel)", "BU-Schlüssel", "Belegdatum", "Belegfeld 1", "Belegfeld 2", "Skonto", "Buchungstext",
        ].joined(separator: ";")
        let rows = bookings.map { booking in
            [
                decimal(Double(booking.grossCents) / 100, digits: 2).replacingOccurrences(of: ".", with: ","), "\"S\"", "\"EUR\"", "", "", "",
                settings.debtorAccount, settings.revenueAccount, "\"\"", format(booking.date, "ddMM"),
                quoted(booking.invoiceNumber, max: 36), "\"\"", "", quoted(booking.text, max: 60),
            ].joined(separator: ";")
        }
        return ([header, columns] + rows).joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Helpers

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Dot decimal separator regardless of the device locale.
    static func decimal(_ value: Double, digits: Int? = nil) -> String {
        if let digits { return String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
