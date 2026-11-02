import Foundation
import SwiftData
@testable import lidar

/// Fresh in-memory store with the app's full schema.
func makeTestContainer() throws -> ModelContainer {
    let schema = Schema([TenantSettings.self, PriceBookVersion.self, Job.self, Survey.self, Quote.self, PendingMutation.self])
    return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
}

func makeSession(user: UUID, tenant: UUID?, role: Role = .owner) -> AuthSession {
    AuthSession(accessToken: "token", refreshToken: "refresh", expiresAt: .now.addingTimeInterval(3600),
                userID: user, email: "\(user.uuidString.prefix(4))@test.de", tenantID: tenant, role: role)
}

/// In-memory stand-in for Supabase. Records every pushed mutation and answers
/// `pull_changes` with whatever `pullPages` holds (empty page by default).
final class FakeBackend: BackendAPI {
    var isConfigured = true
    var session: AuthSession? {
        didSet { LocalStore.actingUserID = session?.userID }
    }

    /// Every mutation sent through `push_mutations`, in order.
    private(set) var pushed: [[String: Any]] = []
    /// Override the server's answer per mutation (default: applied).
    var pushResult: ([String: Any]) -> [String: Any] = { item in
        ["idempotency_key": item["idempotency_key"] ?? "", "status": "applied"]
    }
    /// Queued pull responses; when empty an empty page is returned.
    var pullPages: [[String: Any]] = []
    private(set) var rpcCalls: [String] = []
    private(set) var uploads: [String] = []
    var failingUploads: Set<String> = []

    init(session: AuthSession? = nil) {
        self.session = session
        LocalStore.actingUserID = session?.userID
    }

    var pushedKinds: [String] { pushed.compactMap { $0["kind"] as? String } }

    /// When set, push/pull go to this shared in-memory server (multi-device tests).
    var server: FakeServer?

    func rpc(_ function: String, params: [String: Any]) async throws -> Data {
        rpcCalls.append(function)
        if let server {
            switch function {
            case "push_mutations":
                let batch = params["p_batch"] as? [[String: Any]] ?? []
                pushed += batch
                return try JSONSerialization.data(withJSONObject: server.push(batch))
            case "pull_changes":
                return try JSONSerialization.data(withJSONObject: server.pull(since: params["p_since"] as? Int ?? 0))
            default:
                return Data("{}".utf8)
            }
        }
        switch function {
        case "push_mutations":
            let batch = params["p_batch"] as? [[String: Any]] ?? []
            pushed += batch
            return try JSONSerialization.data(withJSONObject: batch.map(pushResult))
        case "pull_changes":
            let page = pullPages.isEmpty
                ? ["cursor": params["p_since"] ?? 0, "has_more": false, "price_book_versions": [], "quote_numbers": []]
                : pullPages.removeFirst()
            return try JSONSerialization.data(withJSONObject: page)
        default:
            return Data("{}".utf8)
        }
    }

    func upload(bucket: String, path: String, fileURL: URL, contentType: String) async throws {
        if failingUploads.contains(fileURL.lastPathComponent) {
            throw BackendError.http(status: 500, message: "upload failed")
        }
        uploads.append(path)
    }

    func signOut() async {
        session = nil
    }
}

/// Tiny in-memory model of the Supabase sync API: stores jobs, rooms and quotes
/// with a change sequence, applies last-writer-wins on push and soft deletes.
final class FakeServer {
    private(set) var seq = 0
    var jobs: [String: [String: Any]] = [:]
    var surveys: [String: [String: Any]] = [:]
    var quotes: [String: [String: Any]] = [:]
    private var quoteCounter = 0
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func now() -> String { formatter.string(from: .now) }
    private func date(_ value: Any?) -> Date { (value as? String).flatMap(formatter.date(from:)) ?? .distantPast }
    private func nextSeq() -> Int { seq += 1; return seq }

    /// Simulates another device or the office changing a row directly on the server.
    func touchJob(_ id: UUID, _ change: (inout [String: Any]) -> Void) {
        guard var row = jobs[id.uuidString] else { return }
        change(&row)
        row["row_seq"] = nextSeq()
        jobs[id.uuidString] = row
    }

    func push(_ batch: [[String: Any]]) -> [[String: Any]] {
        batch.map { item in
            let key = item["idempotency_key"] ?? ""
            let p = item["payload"] as? [String: Any] ?? [:]
            let id = p["id"] as? String ?? ""
            var result: [String: Any] = ["idempotency_key": key, "status": "applied"]
            switch item["kind"] as? String {
            case "upsert_job":
                if let existing = jobs[id], date(p["updated_at"]) < date(existing["updated_at"]) { break }
                var row = jobs[id] ?? ["id": id, "created_at": now(), "deleted_at": NSNull(), "client_data_erased_at": NSNull()]
                for key in ["title", "client_name", "client_email", "client_phone", "site_address", "updated_at"] {
                    row[key] = p[key] ?? NSNull()
                }
                if row["privacy_notice_confirmed_at"] == nil || row["privacy_notice_confirmed_at"] is NSNull {
                    row["privacy_notice_confirmed_at"] = p["privacy_notice_confirmed_at"] ?? NSNull()
                }
                row["row_seq"] = nextSeq()
                jobs[id] = row
            case "upsert_survey":
                guard let jobID = p["job_id"] as? String, jobs[jobID] != nil else {
                    result = ["idempotency_key": key, "status": "rejected", "error": "unknown job", "sqlstate": "P0001", "retryable": false]
                    break
                }
                if let existing = surveys[id], date(p["updated_at"]) < date(existing["updated_at"]) { break }
                var row = p
                row["deleted_at"] = NSNull()
                row["row_seq"] = nextSeq()
                surveys[id] = row
            case "delete_survey":
                surveys[id]?["deleted_at"] = now()
                surveys[id]?["row_seq"] = nextSeq()
            case "delete_job":
                jobs[id]?["deleted_at"] = now()
                jobs[id]?["row_seq"] = nextSeq()
                for (surveyID, survey) in surveys where survey["job_id"] as? String == id {
                    surveys[surveyID]?["deleted_at"] = now()
                    surveys[surveyID]?["row_seq"] = nextSeq()
                }
            case "issue_quote":
                quoteCounter += 1
                let number = String(format: "T-2026-%05d", quoteCounter)
                var row = p
                row["final_number"] = number
                row["status"] = "issued"
                row["row_seq"] = nextSeq()
                quotes[id] = row
                result["quote_id"] = id
                result["final_number"] = number
            default:
                break
            }
            return result
        }
    }

    func pull(since: Int) -> [String: Any] {
        func changed(_ rows: [String: [String: Any]]) -> [[String: Any]] {
            rows.values.filter { ($0["row_seq"] as? Int ?? 0) > since }
                .sorted { ($0["row_seq"] as? Int ?? 0) < ($1["row_seq"] as? Int ?? 0) }
        }
        return ["cursor": seq, "has_more": false, "price_book_versions": [], "quote_numbers": [],
                "jobs": changed(jobs), "surveys": changed(surveys), "quotes": changed(quotes)]
    }
}
