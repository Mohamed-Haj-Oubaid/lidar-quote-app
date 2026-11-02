import Foundation
import Network
import Observation
import SwiftData

/// Offline-first sync between the on-device SwiftData store and Supabase.
///
/// * **Push**: drains the `PendingMutation` outbox in order through the
///   `push_mutations` RPC. Each mutation carries an idempotency key, so a replay
///   after a dropped connection is harmless. The server answers `issue_quote`
///   with the official sequential quote number, which replaces the provisional
///   `OFFLINE-TEMP-…` number locally (and the PDF is re-rendered).
/// * **Pull**: `pull_changes(since:)` returns tenant settings, published
///   price-book versions and finalized quote numbers newer than the cursor.
/// * **Media**: USDZ models are uploaded only when the firm has *not* enabled
///   "device-only media".
@Observable
final class SyncManager {
    enum Status: Equatable {
        case idle
        case offline
        case notSignedIn
        case syncing
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var isOnline = false

    private let container: ModelContainer
    private let backend: BackendClient
    private let monitor = NWPathMonitor()
    private var isSyncing = false

    init(container: ModelContainer, backend: BackendClient) {
        self.container = container
        self.backend = backend
    }

    private var context: ModelContext { container.mainContext }

    /// Starts watching connectivity; every transition to "online" triggers a sync.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameOnline = online && !self.isOnline
                self.isOnline = online
                if !online { self.status = .offline }
                if cameOnline { await self.syncNow() }
            }
        }
        monitor.start(queue: .main)
    }

    func syncNow() async {
        guard !isSyncing else { return }
        guard backend.isConfigured, backend.isSignedIn else {
            status = .notSignedIn
            return
        }
        guard isOnline else {
            status = .offline
            return
        }
        isSyncing = true
        status = .syncing
        defer { isSyncing = false }

        do {
            try await push()
            try await pull()
            try await uploadMedia()
            LocalStore.settings(in: context).lastSyncAt = .now
            try context.save()
            status = .idle
        } catch BackendError.notSignedIn {
            status = .notSignedIn
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Push

    private struct PushResult: Decodable {
        var idempotencyKey: UUID
        var status: String
        var quoteID: UUID?
        var finalNumber: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case status, error
            case idempotencyKey = "idempotency_key", quoteID = "quote_id", finalNumber = "final_number"
        }
    }

    private func push() async throws {
        let descriptor = FetchDescriptor<PendingMutation>(sortBy: [SortDescriptor(\.createdAt)])
        let pending = try context.fetch(descriptor)
        let batchSize = 50

        for start in stride(from: 0, to: pending.count, by: batchSize) {
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            let items: [[String: Any]] = try batch.map { mutation in
                [
                    "idempotency_key": mutation.id.uuidString,
                    "kind": mutation.kind,
                    "payload": try JSONSerialization.jsonObject(with: mutation.payload),
                ]
            }
            let data = try await backend.rpc("push_mutations", params: ["p_batch": items])
            let results = try Self.decoder.decode([PushResult].self, from: data)
            let byKey = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })

            for result in results {
                guard let mutation = byKey[result.idempotencyKey] else { continue }
                switch result.status {
                case "applied", "duplicate":
                    if let quoteID = result.quoteID, let number = result.finalNumber {
                        finalize(quoteID: quoteID, number: number)
                    }
                    context.delete(mutation)
                default:
                    mutation.attempts += 1
                    mutation.lastError = result.error ?? result.status
                }
            }
            try context.save()
        }
    }

    /// Replaces the provisional number with the official one and re-renders the PDF.
    private func finalize(quoteID: UUID, number: String) {
        let descriptor = FetchDescriptor<Quote>(predicate: #Predicate { $0.id == quoteID })
        guard let quote = try? context.fetch(descriptor).first, quote.finalNumber != number else { return }
        quote.finalNumber = number
        if let job = quote.job {
            quote.pdfData = PDFGenerator.render(quote: quote, job: job, settings: LocalStore.settings(in: context))
        }
    }

    // MARK: - Pull

    private struct PullResponse: Decodable {
        var cursor: Int
        var hasMore: Bool?
        var tenant: TenantDTO?
        var priceBookVersions: [PriceBookVersionDTO]
        var quoteNumbers: [QuoteNumberDTO]

        enum CodingKeys: String, CodingKey {
            case cursor, tenant
            case hasMore = "has_more"
            case priceBookVersions = "price_book_versions", quoteNumbers = "quote_numbers"
        }
    }

    private struct TenantDTO: Decodable {
        var id: UUID
        var name: String
        var address: String?
        var quotePrefix: String
        var mediaDeviceOnly: Bool
        var privacyNotice: String?

        enum CodingKeys: String, CodingKey {
            case id, name, address
            case quotePrefix = "quote_prefix", mediaDeviceOnly = "media_device_only", privacyNotice = "privacy_notice"
        }
    }

    private struct PriceBookVersionDTO: Decodable {
        var id: UUID
        var priceBookID: UUID
        var name: String
        var version: Int
        var vatRateBasisPoints: Int
        var publishedAt: Date
        var items: [PriceItem]
        var isActive: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, version, items
            case priceBookID = "price_book_id", vatRateBasisPoints = "vat_rate_bp"
            case publishedAt = "published_at", isActive = "is_active"
        }
    }

    private struct QuoteNumberDTO: Decodable {
        var quoteID: UUID
        var finalNumber: String
        enum CodingKeys: String, CodingKey { case quoteID = "quote_id", finalNumber = "final_number" }
    }

    /// Pulls page by page until the server reports no more changes.
    private func pull() async throws {
        var hasMore = true
        while hasMore {
            hasMore = try await pullPage()
        }
    }

    private func pullPage() async throws -> Bool {
        let settings = LocalStore.settings(in: context)
        let data = try await backend.rpc("pull_changes", params: ["p_since": settings.syncCursor, "p_limit": 500])
        let response = try Self.decoder.decode(PullResponse.self, from: data)

        if let tenant = response.tenant {
            settings.tenantID = tenant.id
            settings.firmName = tenant.name
            settings.firmAddress = tenant.address ?? ""
            settings.quotePrefix = tenant.quotePrefix
            settings.mediaDeviceOnly = tenant.mediaDeviceOnly
            if let notice = tenant.privacyNotice, !notice.isEmpty {
                settings.privacyNoticeText = notice
            }
        }

        let existing = try context.fetch(FetchDescriptor<PriceBookVersion>())
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for dto in response.priceBookVersions {
            // Published versions are immutable – only the active flag can change.
            if let local = byID[dto.id] {
                local.isActive = dto.isActive
            } else {
                let version = PriceBookVersion(
                    id: dto.id, priceBookID: dto.priceBookID, name: dto.name, version: dto.version,
                    vatRateBasisPoints: dto.vatRateBasisPoints, publishedAt: dto.publishedAt,
                    items: dto.items, isActive: dto.isActive, isLocalSample: false
                )
                context.insert(version)
                byID[dto.id] = version
            }
        }
        // Once the firm's real price book arrives, retire the local sample.
        if byID.values.contains(where: { !$0.isLocalSample && $0.isActive }) {
            for sample in byID.values where sample.isLocalSample {
                sample.isActive = false
            }
        }

        for number in response.quoteNumbers {
            finalize(quoteID: number.quoteID, number: number.finalNumber)
        }

        settings.syncCursor = response.cursor
        try context.save()
        return response.hasMore ?? false
    }

    // MARK: - Media

    private func uploadMedia() async throws {
        let settings = LocalStore.settings(in: context)
        guard !settings.mediaDeviceOnly, let tenantID = settings.tenantID else { return }
        let descriptor = FetchDescriptor<Survey>(predicate: #Predicate { $0.usdzFileName != nil && !$0.mediaUploaded })
        for survey in try context.fetch(descriptor) {
            guard let fileName = survey.usdzFileName, let job = survey.job else { continue }
            let path = "\(tenantID.uuidString.lowercased())/\(job.id.uuidString.lowercased())/\(fileName)"
            try await backend.upload(bucket: "survey-media", path: path,
                                     fileURL: try SurveyEngine.mediaURL(for: fileName),
                                     contentType: "model/vnd.usdz+zip")
            survey.mediaUploaded = true
            try context.save()
        }
    }

    // MARK: - Decoding

    /// Postgres `timestamptz` JSON may or may not include fractional seconds.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: string) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date \(string)"))
        }
        return decoder
    }()
}
