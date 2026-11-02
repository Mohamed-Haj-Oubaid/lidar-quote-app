import Foundation
import SwiftData

/// Shared JSON coders for blobs persisted inside SwiftData models.
enum StoreCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    static let decoder = JSONDecoder()
}

/// Per-device copy of the firm's (tenant's) configuration. Cloud-owned; pulled on sync.
@Model
final class TenantSettings {
    var tenantID: UUID?
    var firmName: String
    var firmAddress: String
    var quotePrefix: String
    /// Per-firm switch: keep USDZ models and photos on the device only.
    var mediaDeviceOnly: Bool
    /// Tenant-editable end-client privacy notice (Art. 13 GDPR), shown before a scan and printed on quotes.
    var privacyNoticeText: String
    /// Random 4-character code identifying this device in provisional quote numbers.
    var deviceCode: String
    var nextProvisionalSequence: Int
    var syncCursor: Int
    var lastSyncAt: Date?
    var appLockEnabled: Bool

    init(deviceCode: String) {
        self.firmName = Self.defaultFirmName
        self.firmAddress = ""
        self.quotePrefix = Self.defaultQuotePrefix
        self.mediaDeviceOnly = true
        self.privacyNoticeText = Self.defaultPrivacyNotice
        self.deviceCode = deviceCode
        self.nextProvisionalSequence = 1
        self.syncCursor = 0
        self.appLockEnabled = false
    }

    static var defaultFirmName: String { String(localized: "My Company") }
    static let defaultQuotePrefix = "ANG"
    static var defaultPrivacyNotice: String {
        String(localized: "To prepare your quote we measure the room with a LiDAR scanner. We store room dimensions, your name and contact details to create and manage the quote. No camera images are stored. Controller: the company named on this quote. You have the right to access, rectify and erase your data.")
    }

    /// Forgets everything that belongs to a company account. Device identity
    /// (`deviceCode`, provisional numbering) and the app-lock preference stay.
    func resetAccountFields() {
        tenantID = nil
        syncCursor = 0
        lastSyncAt = nil
        firmName = Self.defaultFirmName
        firmAddress = ""
        quotePrefix = Self.defaultQuotePrefix
        mediaDeviceOnly = true
        privacyNoticeText = Self.defaultPrivacyNotice
    }
}

/// An immutable, published version of a price book.
@Model
final class PriceBookVersion {
    @Attribute(.unique) var id: UUID
    var priceBookID: UUID
    var name: String
    var version: Int
    var vatRateBasisPoints: Int
    var publishedAt: Date
    var itemsData: Data
    var isActive: Bool
    /// True for the locally seeded sample book that the server does not know about.
    var isLocalSample: Bool

    init(id: UUID, priceBookID: UUID, name: String, version: Int, vatRateBasisPoints: Int, publishedAt: Date, items: [PriceItem], isActive: Bool, isLocalSample: Bool) {
        self.id = id
        self.priceBookID = priceBookID
        self.name = name
        self.version = version
        self.vatRateBasisPoints = vatRateBasisPoints
        self.publishedAt = publishedAt
        self.itemsData = (try? StoreCoding.encoder.encode(items)) ?? Data()
        self.isActive = isActive
        self.isLocalSample = isLocalSample
    }

    /// Decoded once; versions are immutable, so the cache never goes stale.
    @Transient private var cachedItems: [PriceItem]?

    var items: [PriceItem] {
        if let cachedItems { return cachedItems }
        let decoded = (try? StoreCoding.decoder.decode([PriceItem].self, from: itemsData)) ?? []
        cachedItems = decoded
        return decoded
    }

    var snapshot: PriceBookSnapshot {
        PriceBookSnapshot(versionID: id, version: version, name: name, vatRateBasisPoints: vatRateBasisPoints, items: items)
    }
}

@Model
final class Job {
    @Attribute(.unique) var id: UUID
    var title: String
    var clientName: String
    var clientEmail: String
    var clientPhone: String
    var siteAddress: String
    var createdAt: Date
    var updatedAt: Date
    /// When the worker confirmed the end client was shown the privacy notice.
    var privacyNoticeConfirmedAt: Date?
    /// Set when the client's personal data was erased on request (Art. 17 GDPR).
    var clientDataErasedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Survey.job) var surveys: [Survey] = []
    @Relationship(deleteRule: .cascade, inverse: \Quote.job) var quotes: [Quote] = []

    init(id: UUID = UUID(), title: String, clientName: String = "", clientEmail: String = "", clientPhone: String = "", siteAddress: String = "") {
        self.id = id
        self.title = title
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.clientPhone = clientPhone
        self.siteAddress = siteAddress
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sortedSurveys: [Survey] { surveys.sorted { $0.capturedAt < $1.capturedAt } }
    var sortedQuotes: [Quote] { quotes.sorted { $0.revision > $1.revision } }
}

/// One measured room (Aufmaß) inside a job.
@Model
final class Survey {
    @Attribute(.unique) var id: UUID
    var roomName: String
    var capturedAt: Date
    var updatedAt: Date
    var measurementData: Data
    var selectionsData: Data
    /// File name of the parametric USDZ model in the app's media directory, if any.
    var usdzFileName: String?
    var mediaUploaded: Bool
    var job: Job?
    /// Failed media uploads back off like the outbox instead of failing every sync.
    var mediaUploadAttempts: Int = 0
    var mediaNextAttemptAt: Date?

    init(id: UUID = UUID(), roomName: String, measurement: RoomMeasurement, job: Job) {
        self.id = id
        self.roomName = roomName
        self.capturedAt = .now
        self.updatedAt = .now
        self.measurementData = (try? StoreCoding.encoder.encode(measurement)) ?? Data()
        self.selectionsData = (try? StoreCoding.encoder.encode([ItemSelection]())) ?? Data()
        self.mediaUploaded = false
        self.job = job
    }

    // Decoding JSON on every access (several times per SwiftUI body) is wasteful:
    // decode once and invalidate in the setters – the only writers of the blobs.
    @Transient private var cachedMeasurement: RoomMeasurement?
    @Transient private var cachedSelections: [ItemSelection]?

    var measurement: RoomMeasurement {
        get {
            if let cachedMeasurement { return cachedMeasurement }
            let decoded = (try? StoreCoding.decoder.decode(RoomMeasurement.self, from: measurementData)) ?? .empty
            cachedMeasurement = decoded
            return decoded
        }
        set {
            measurementData = (try? StoreCoding.encoder.encode(newValue)) ?? measurementData
            cachedMeasurement = nil
            updatedAt = .now
        }
    }

    var selections: [ItemSelection] {
        get {
            if let cachedSelections { return cachedSelections }
            let decoded = (try? StoreCoding.decoder.decode([ItemSelection].self, from: selectionsData)) ?? []
            cachedSelections = decoded
            return decoded
        }
        set {
            selectionsData = (try? StoreCoding.encoder.encode(newValue)) ?? selectionsData
            cachedSelections = nil
            updatedAt = .now
        }
    }
}

/// An issued quote revision. Immutable once created: changes produce a new revision.
/// Only `finalNumber`, `pdfData`, `status` and `clientSignedAt` ever change after issue.
@Model
final class Quote {
    @Attribute(.unique) var id: UUID
    var provisionalNumber: String
    var finalNumber: String?
    var revision: Int
    var issuedAt: Date
    var priceBookVersionID: UUID
    var engineVersion: String
    var calculationData: Data
    var snapshotSHA256: String
    @Attribute(.externalStorage) var pdfData: Data?
    var job: Job?
    /// Lifecycle from the server: issued, sent, accepted, rejected, superseded.
    var status: String = "issued"
    var clientSignedAt: Date?

    init(id: UUID = UUID(), provisionalNumber: String, revision: Int, calculation: QuoteCalculation, snapshotSHA256: String, job: Job) {
        self.id = id
        self.provisionalNumber = provisionalNumber
        self.revision = revision
        self.issuedAt = .now
        self.priceBookVersionID = calculation.priceBookVersionID
        self.engineVersion = calculation.engineVersion
        self.calculationData = (try? StoreCoding.encoder.encode(calculation)) ?? Data()
        self.snapshotSHA256 = snapshotSHA256
        self.job = job
    }

    var displayNumber: String { finalNumber ?? provisionalNumber }
    var isProvisional: Bool { finalNumber == nil }

    /// Frozen at issue time, so decoding once is enough.
    @Transient private var cachedCalculation: QuoteCalculation?

    var calculation: QuoteCalculation? {
        if let cachedCalculation { return cachedCalculation }
        let decoded = try? StoreCoding.decoder.decode(QuoteCalculation.self, from: calculationData)
        cachedCalculation = decoded
        return decoded
    }
}

/// Outbox entry: a domain change waiting to be pushed to Supabase.
/// Written in the same save as the change itself, so nothing is lost offline.
@Model
final class PendingMutation {
    /// Doubles as the server-side idempotency key – replays are harmless.
    @Attribute(.unique) var id: UUID
    var kind: String
    var payload: Data
    var createdAt: Date
    var attempts: Int
    var lastError: String?
    /// Account that created the change. Never pushed under a different account,
    /// so one company's changes can't end up in another company. Nil = created
    /// while signed out (offline before the first sign-in).
    var userID: UUID?
    /// Set when the server rejected the change permanently (or a change it depends
    /// on is blocked). Blocked entries are not resent until the user taps Retry.
    var blockedReason: String?
    /// Earliest time of the next attempt after a transient failure (exponential backoff).
    var nextAttemptAt: Date?

    init(kind: String, payload: Data, userID: UUID? = nil) {
        self.id = UUID()
        self.kind = kind
        self.payload = payload
        self.createdAt = .now
        self.attempts = 0
        self.userID = userID
    }

    var isBlocked: Bool { blockedReason != nil }

    private var payloadObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
    }

    /// Id of the entity this change writes (`id` for jobs/rooms/quotes, `quote_id` for a status change).
    var entityID: UUID? {
        let object = payloadObject
        return (object["id"] as? String ?? object["quote_id"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// The job this change belongs to – used to block dependents of a blocked job.
    var jobID: UUID? {
        let object = payloadObject
        switch kind {
        case "upsert_job", "delete_job":
            return (object["id"] as? String).flatMap(UUID.init(uuidString:))
        default:
            return (object["job_id"] as? String).flatMap(UUID.init(uuidString:))
        }
    }

    /// Short human-readable description for the outbox list.
    var displayTitle: String {
        let object = payloadObject
        let name = object["title"] as? String ?? object["room_name"] as? String ?? object["provisional_number"] as? String
        let what: String = switch kind {
        case "upsert_job": String(localized: "Job")
        case "delete_job": String(localized: "Delete job")
        case "upsert_survey": String(localized: "Room")
        case "delete_survey": String(localized: "Delete room")
        case "issue_quote": String(localized: "Quote")
        case "set_quote_status": String(localized: "Quote status")
        case "update_tenant_settings": String(localized: "Company settings")
        default: kind
        }
        guard let name, !name.isEmpty else { return what }
        return "\(what): \(name)"
    }

    /// Exponential backoff: 2, 4, 8 … seconds, capped at one hour.
    static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        min(pow(2, Double(min(attempts, 12))), 3600)
    }
}
