import Foundation
import SwiftData

/// Mutation kinds understood by the `push_mutations` RPC (see supabase/migrations).
enum MutationKind: String {
    case upsertJob = "upsert_job"
    case upsertSurvey = "upsert_survey"
    case issueQuote = "issue_quote"
    case updateTenantSettings = "update_tenant_settings"
    case deleteSurvey = "delete_survey"
    case deleteJob = "delete_job"
    case setQuoteStatus = "set_quote_status"
}

private struct QuoteStatusPayload: Encodable {
    var quoteId: UUID
    var jobId: UUID?
    var status: String
    var clientSignedAt: Date?

    enum CodingKeys: String, CodingKey {
        case status
        case quoteId = "quote_id", jobId = "job_id", clientSignedAt = "client_signed_at"
    }
}

private struct DeletePayload: Encodable {
    var id: UUID
    /// Lets the outbox block the delete together with its job; ignored by the server.
    var jobId: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case jobId = "job_id"
    }
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
    /// The exact canonical bytes the hash was computed over (UTF-8 string).
    var calculationJson: String
    var snapshotSha256: String
    var netTotalCents: Int
    var grossTotalCents: Int

    enum CodingKeys: String, CodingKey {
        case id, revision, calculation
        case calculationJson = "calculation_json"
        case jobId = "job_id", provisionalNumber = "provisional_number", issuedAt = "issued_at"
        case priceBookVersionId = "price_book_version_id", engineVersion = "engine_version"
        case snapshotSha256 = "snapshot_sha256", netTotalCents = "net_total_cents", grossTotalCents = "gross_total_cents"
    }
}

/// All local writes go through here so every domain change is paired with an
/// outbox entry in the same SwiftData save (offline-first, nothing lost).
/// Top-level payload keys are snake_case for Postgres; nested JSON (measurement,
/// calculation) keeps its canonical form so the server copy matches the hash.
enum LocalStoreError: LocalizedError, Equatable {
    case samplePriceBook
    case emptyRoomName
    case duplicateRoomName(String)

    var errorDescription: String? {
        switch self {
        case .samplePriceBook: String(localized: "Sample prices – sign in and sync to issue real quotes.")
        case .emptyRoomName: String(localized: "Enter a room name.")
        case .duplicateRoomName(let name): String(localized: "This job already has a room named “\(name)”.")
        }
    }
}

enum LocalStore {
    /// The signed-in account; stamped on every outbox entry. Kept in sync by `BackendClient`.
    static var actingUserID: UUID?

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Millisecond precision: whole seconds made two edits within one second look
        // equally old, so last-writer-wins dropped the second one on other devices.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
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
        // The server rejects quotes from the device's sample book – never issue one.
        let bookID = calculation.priceBookVersionID
        let book = try context.fetch(FetchDescriptor<PriceBookVersion>(predicate: #Predicate { $0.id == bookID })).first
        if book?.isLocalSample ?? true { throw LocalStoreError.samplePriceBook }
        let settings = settings(in: context)
        let provisional = String(format: "OFFLINE-TEMP-%@-%04d", settings.deviceCode, settings.nextProvisionalSequence)
        settings.nextProvisionalSequence += 1

        let revision = (job.quotes.map(\.revision).max() ?? 0) + 1
        // Hash and payload come from the same bytes so the server can verify the hash.
        let canonical = try calculation.canonicalJSON()
        let quote = Quote(provisionalNumber: provisional, revision: revision, calculation: calculation,
                          snapshotSHA256: QuoteCalculation.sha256Hex(of: canonical), job: job)
        context.insert(quote)
        quote.pdfData = PDFGenerator.render(quote: quote, job: job, settings: settings)

        try enqueue(.issueQuote, QuotePayload(
            id: quote.id, jobId: job.id, provisionalNumber: provisional, revision: revision,
            issuedAt: quote.issuedAt, priceBookVersionId: calculation.priceBookVersionID,
            engineVersion: calculation.engineVersion, calculation: calculation,
            calculationJson: String(decoding: canonical, as: UTF8.self),
            snapshotSha256: quote.snapshotSHA256, netTotalCents: calculation.netTotalCents,
            grossTotalCents: calculation.grossTotalCents
        ), in: context)
        try context.save()
        return quote
    }

    // MARK: - Quote lifecycle

    /// Status changes allowed by the server (`m_set_quote_status`).
    static func allowedStatusChanges(for quote: Quote) -> [String] {
        switch quote.status {
        case "issued": ["sent", "accepted", "rejected"]
        case "sent": ["accepted", "rejected"]
        default: []
        }
    }

    /// Records sent / accepted / rejected locally and queues it – works offline.
    static func setStatus(_ status: String, of quote: Quote, in context: ModelContext) throws {
        guard allowedStatusChanges(for: quote).contains(status) else { return }
        quote.status = status
        if status == "accepted" { quote.clientSignedAt = .now }
        try enqueue(.setQuoteStatus, QuoteStatusPayload(
            quoteId: quote.id, jobId: quote.job?.id, status: status,
            clientSignedAt: status == "accepted" ? quote.clientSignedAt : nil
        ), in: context)
        try context.save()
    }

    /// Applies an Art. 17 erasure locally (after the server erased it): client fields
    /// cleared, media files removed. No outbox entry – the server already has it.
    static func applyClientErasure(to job: Job, in context: ModelContext) throws {
        job.title = String(localized: "Erased job")
        job.clientName = ""
        job.clientEmail = ""
        job.clientPhone = ""
        job.siteAddress = ""
        job.clientDataErasedAt = .now
        for survey in job.surveys {
            removeMedia(of: survey)
            survey.usdzFileName = nil
            survey.mediaUploaded = false
        }
        try context.save()
    }

    // MARK: - Rooms

    /// Room names are unique per job (trimmed, case-insensitive).
    static func isRoomName(_ name: String, takenIn job: Job, excluding survey: Survey? = nil) -> Bool {
        let key = normalizedRoomName(name)
        return job.surveys.contains { $0.id != survey?.id && normalizedRoomName($0.roomName) == key }
    }

    /// First "Room N" that is not taken in the job – never repeats after a deletion.
    static func nextRoomName(for job: Job) -> String {
        var number = job.surveys.count + 1
        for candidate in 1...(job.surveys.count + 1) {
            if !isRoomName(String(localized: "Room \(candidate)"), takenIn: job) {
                number = candidate
                break
            }
        }
        return String(localized: "Room \(number)")
    }

    static func normalizedRoomName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Validates a new room name for a job; returns the trimmed name.
    static func validatedRoomName(_ name: String, in job: Job, excluding survey: Survey? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalStoreError.emptyRoomName }
        guard !isRoomName(trimmed, takenIn: job, excluding: survey) else { throw LocalStoreError.duplicateRoomName(trimmed) }
        return trimmed
    }

    /// Renames a room and queues exactly one upsert – only when the name really changed.
    /// - Returns: `true` when a change was saved.
    @discardableResult
    static func rename(survey: Survey, to name: String, in context: ModelContext) throws -> Bool {
        guard let job = survey.job else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != survey.roomName else { return false }
        survey.roomName = try validatedRoomName(trimmed, in: job, excluding: survey)
        try save(survey: survey, in: context)
        return true
    }

    // MARK: - Deletes

    /// Deletes a room locally and tells the server (soft delete there).
    static func delete(survey: Survey, in context: ModelContext) throws {
        let id = survey.id
        let jobID = survey.job?.id
        let unsent = pendingMutations(in: context).filter { $0.kind == MutationKind.upsertSurvey.rawValue && $0.entityID == id }
        let serverMayKnow = unsent.isEmpty || unsent.contains { $0.attempts > 0 }
        // A room the server has never seen needs no delete – drop its pending upsert instead.
        for mutation in unsent { context.delete(mutation) }
        if serverMayKnow {
            try enqueue(.deleteSurvey, DeletePayload(id: id, jobId: jobID), in: context)
        }
        removeMedia(of: survey)
        context.delete(survey)
        try context.save()
    }

    /// Deletes a job with its rooms locally and tells the server. Issued quotes stay
    /// on the server (commercial retention); unsynced quotes are still sent first.
    static func delete(job: Job, in context: ModelContext) throws {
        let id = job.id
        let related = pendingMutations(in: context).filter { $0.jobID == id }
        let jobUpserts = related.filter { $0.kind == MutationKind.upsertJob.rawValue }
        let pendingQuotes = related.contains { $0.kind == MutationKind.issueQuote.rawValue }
        let serverMayKnow = jobUpserts.isEmpty || jobUpserts.contains { $0.attempts > 0 } || pendingQuotes

        if serverMayKnow {
            // Room edits are pointless now; quotes must still reach the server.
            for mutation in related where mutation.kind == MutationKind.upsertSurvey.rawValue
                || mutation.kind == MutationKind.deleteSurvey.rawValue {
                context.delete(mutation)
            }
            try enqueue(.deleteJob, DeletePayload(id: id, jobId: id), in: context)
        } else {
            // The server never saw this job: nothing to send at all.
            for mutation in related { context.delete(mutation) }
        }
        for survey in job.surveys { removeMedia(of: survey) }
        context.delete(job)
        try context.save()
    }

    private static func pendingMutations(in context: ModelContext) -> [PendingMutation] {
        (try? context.fetch(FetchDescriptor<PendingMutation>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    private static func removeMedia(of survey: Survey) {
        if let fileName = survey.usdzFileName, let url = try? SurveyEngine.mediaURL(for: fileName) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func enqueue(_ kind: MutationKind, _ payload: some Encodable, in context: ModelContext) throws {
        let data = try payloadEncoder.encode(payload)
        context.insert(PendingMutation(kind: kind.rawValue, payload: data, userID: actingUserID))
    }

    // MARK: - Account switch

    /// Removes every trace of the current company account from the device: jobs,
    /// rooms, quotes, the outbox, downloaded price books, synced settings, media
    /// files and shared PDFs. Called after sign-out and when a different company
    /// signs in on this device.
    static func wipeAccountData(in context: ModelContext) throws {
        for job in try context.fetch(FetchDescriptor<Job>()) { context.delete(job) }
        // Explicit as well, in case an orphan escaped the cascade.
        for survey in try context.fetch(FetchDescriptor<Survey>()) { context.delete(survey) }
        for quote in try context.fetch(FetchDescriptor<Quote>()) { context.delete(quote) }
        for mutation in try context.fetch(FetchDescriptor<PendingMutation>()) { context.delete(mutation) }

        let books = try context.fetch(FetchDescriptor<PriceBookVersion>())
        for book in books where !book.isLocalSample { context.delete(book) }
        // The sample book was retired when the firm's book arrived – bring it back.
        let samples = books.filter(\.isLocalSample)
        if samples.isEmpty {
            context.insert(makeSamplePriceBook())
        } else {
            for sample in samples { sample.isActive = true }
        }

        settings(in: context).resetAccountFields()

        let files = FileManager.default
        if let media = try? SurveyEngine.mediaDirectory() {
            try? files.removeItem(at: media)
        }
        removeSharedPDFs()

        try context.save()
    }

    /// Shared quote PDFs are written to the temporary directory for the share sheet.
    static func removeSharedPDFs() {
        let files = FileManager.default
        let temp = files.temporaryDirectory
        let contents = (try? files.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension.lowercased() == "pdf" {
            try? files.removeItem(at: url)
        }
    }

    // MARK: - First launch

    /// Seeds settings and a sample price book so the app is usable before the first sync.
    static func seedIfNeeded(in context: ModelContext) {
        _ = settings(in: context)
        let existing = (try? context.fetchCount(FetchDescriptor<PriceBookVersion>())) ?? 0
        if existing == 0 {
            context.insert(makeSamplePriceBook())
        }
        try? context.save()
    }

    private static func makeSamplePriceBook() -> PriceBookVersion {
        PriceBookVersion(
            id: UUID(), priceBookID: UUID(), name: String(localized: "Sample price book"), version: 0,
            vatRateBasisPoints: 1900, publishedAt: .now, items: samplePriceItems,
            isActive: true, isLocalSample: true
        )
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
