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

    func rpc(_ function: String, params: [String: Any]) async throws -> Data {
        rpcCalls.append(function)
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
