import Foundation
import SwiftData

/// Mutation kinds understood by the `push_mutations` RPC (see supabase/migrations).
enum MutationKind: String {
    case upsertJob = "upsert_job"
    case upsertSurvey = "upsert_survey"
    case issueQuote = "issue_quote"
    case updateTenantSettings = "update_tenant_settings"
}

private struct TenantSettingsPayload: Encodable {
    var name: String
    var address: String
    var quotePrefix: String
    var mediaDeviceOnly: Bool
    var privacyNotice: String

    enum CodingKeys: String, CodingKey {
        case name, address
        case quotePrefix = "quote_prefix", mediaDeviceOnly = "media_device_only", privacyNotice = "privacy_notice"
    }
}

private struct JobPayload: Encodable {
    var id: UUID
    var title: String
    var clientName: String
    var clientEmail: String
    var clientPhone: String
    var siteAddress: String
    var privacyNoticeConfirmedAt: Date?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case clientName = "client_name", clientEmail = "client_email", clientPhone = "client_phone"
        case siteAddress = "site_address", privacyNoticeConfirmedAt = "privacy_notice_confirmed_at", updatedAt = "updated_at"
    }
}

private struct SurveyPayload: Encodable {
    var id: UUID
    var jobId: UUID
    var roomName: String
    var measurement: RoomMeasurement
    var capturedAt: Date
    var updatedAt: Date
    var hasMedia: Bool
    var selections: [ItemSelection]

    enum CodingKeys: String, CodingKey {
        case id, measurement, selections
        case jobId = "job_id", roomName = "room_name", capturedAt = "captured_at", updatedAt = "updated_at", hasMedia = "has_media"
    }
}

private struct QuotePayload: Encodable {
    var id: UUID
    var jobId: UUID
    var provisionalNumber: String
    var revision: Int
    var issuedAt: Date
    var priceBookVersionId: UUID
    var engineVersion: String
    var calculation: QuoteCalculation
    var snapshotSha256: String
    var netTotalCents: Int
    var grossTotalCents: Int

    enum CodingKeys: String, CodingKey {
        case id, revision, calculation
        case jobId = "job_id", provisionalNumber = "provisional_number", issuedAt = "issued_at"
        case priceBookVersionId = "price_book_version_id", engineVersion = "engine_version"
        case snapshotSha256 = "snapshot_sha256", netTotalCents = "net_total_cents", grossTotalCents = "gross_total_cents"
    }
}

/// All local writes go through here so every domain change is paired with an
/// outbox entry in the same SwiftData save (offline-first, nothing lost).
/// Top-level payload keys are snake_case for Postgres; nested JSON (measurement,
/// calculation) keeps its canonical form so the server copy matches the hash.
enum LocalStore {
    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func settings(in context: ModelContext) -> TenantSettings {
        if let existing = try? context.fetch(FetchDescriptor<TenantSettings>()).first {
            return existing
        }
        let code = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4))
        let settings = TenantSettings(deviceCode: code)
        context.insert(settings)
        return settings
    }

    static func activePriceBook(in context: ModelContext) -> PriceBookVersion? {
        let descriptor = FetchDescriptor<PriceBookVersion>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.version, order: .reverse)]
        )
        return try? context.fetch(descriptor).first
    }

    // MARK: - Writes

    static func save(job: Job, in context: ModelContext) throws {
        job.updatedAt = .now
        try enqueue(.upsertJob, JobPayload(
            id: job.id, title: job.title, clientName: job.clientName, clientEmail: job.clientEmail,
            clientPhone: job.clientPhone, siteAddress: job.siteAddress,
            privacyNoticeConfirmedAt: job.privacyNoticeConfirmedAt, updatedAt: job.updatedAt
        ), in: context)
        try context.save()
    }

    static func save(survey: Survey, in context: ModelContext) throws {
        guard let job = survey.job else { return }
        survey.updatedAt = .now
        try enqueue(.upsertSurvey, SurveyPayload(
            id: survey.id, jobId: job.id, roomName: survey.roomName, measurement: survey.measurement,
            capturedAt: survey.capturedAt, updatedAt: survey.updatedAt, hasMedia: survey.usdzFileName != nil,
            selections: survey.selections
        ), in: context)
        try context.save()
    }

    /// Firm settings – the server only accepts this from Owner/Admin.
    static func save(settings: TenantSettings, in context: ModelContext) throws {
        try enqueue(.updateTenantSettings, TenantSettingsPayload(
            name: settings.firmName, address: settings.firmAddress, quotePrefix: settings.quotePrefix,
            mediaDeviceOnly: settings.mediaDeviceOnly, privacyNotice: settings.privacyNoticeText
        ), in: context)
        try context.save()
    }

    /// Freezes the calculation, assigns a provisional number and renders the PDF – fully offline.
    @discardableResult
    static func issueQuote(for job: Job, calculation: QuoteCalculation, in context: ModelContext) throws -> Quote {
        let settings = settings(in: context)
        let provisional = String(format: "OFFLINE-TEMP-%@-%04d", settings.deviceCode, settings.nextProvisionalSequence)
        settings.nextProvisionalSequence += 1

        let revision = (job.quotes.map(\.revision).max() ?? 0) + 1
        let quote = Quote(provisionalNumber: provisional, revision: revision, calculation: calculation,
                          snapshotSHA256: try calculation.sha256Hex(), job: job)
        context.insert(quote)
        quote.pdfData = PDFGenerator.render(quote: quote, job: job, settings: settings)

        try enqueue(.issueQuote, QuotePayload(
            id: quote.id, jobId: job.id, provisionalNumber: provisional, revision: revision,
            issuedAt: quote.issuedAt, priceBookVersionId: calculation.priceBookVersionID,
            engineVersion: calculation.engineVersion, calculation: calculation,
            snapshotSha256: quote.snapshotSHA256, netTotalCents: calculation.netTotalCents,
            grossTotalCents: calculation.grossTotalCents
        ), in: context)
        try context.save()
        return quote
    }

    private static func enqueue(_ kind: MutationKind, _ payload: some Encodable, in context: ModelContext) throws {
        let data = try payloadEncoder.encode(payload)
        context.insert(PendingMutation(kind: kind.rawValue, payload: data))
    }

    // MARK: - First launch

    /// Seeds settings and a sample price book so the app is usable before the first sync.
    static func seedIfNeeded(in context: ModelContext) {
        _ = settings(in: context)
        let existing = (try? context.fetchCount(FetchDescriptor<PriceBookVersion>())) ?? 0
        if existing == 0 {
            context.insert(PriceBookVersion(
                id: UUID(), priceBookID: UUID(), name: String(localized: "Sample price book"), version: 0,
                vatRateBasisPoints: 1900, publishedAt: .now, items: samplePriceItems,
                isActive: true, isLocalSample: true
            ))
        }
        try? context.save()
    }

    static let samplePriceItems: [PriceItem] = [
        PriceItem(id: UUID(), code: "MAL-01", name: String(localized: "Wall painting, 2 coats"), basis: .wallArea, unitPriceCents: 1250, openingRule: .vobPainting, defaultWastePercent: 0),
        PriceItem(id: UUID(), code: "MAL-02", name: String(localized: "Ceiling painting"), basis: .ceilingArea, unitPriceCents: 1450, openingRule: .noDeduction, defaultWastePercent: 0),
        PriceItem(id: UUID(), code: "DAM-01", name: String(localized: "Interior wall insulation"), basis: .wallArea, unitPriceCents: 6800, openingRule: .deductAll, defaultWastePercent: 5),
        PriceItem(id: UUID(), code: "FLI-01", name: String(localized: "Floor tiles incl. laying"), basis: .floorArea, unitPriceCents: 7900, openingRule: .noDeduction, defaultWastePercent: 10),
        PriceItem(id: UUID(), code: "SOC-01", name: String(localized: "Skirting board"), basis: .skirtingLength, unitPriceCents: 1890, openingRule: .noDeduction, defaultWastePercent: 5),
        PriceItem(id: UUID(), code: "LAI-01", name: String(localized: "Reveal plastering"), basis: .revealLength, unitPriceCents: 2400, openingRule: .noDeduction, defaultWastePercent: 0),
        PriceItem(id: UUID(), code: "TUE-01", name: String(localized: "Door frame painting"), basis: .doorCount, unitPriceCents: 6500, openingRule: .noDeduction, defaultWastePercent: 0),
        PriceItem(id: UUID(), code: "BAU-01", name: String(localized: "Site setup & covering"), basis: .fixedPiece, unitPriceCents: 9500, openingRule: .noDeduction, defaultWastePercent: 0),
    ]
}
