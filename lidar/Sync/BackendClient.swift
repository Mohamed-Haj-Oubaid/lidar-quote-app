import Foundation
import Observation

/// Supabase project settings, read from Info.plist (`SUPABASE_URL`, `SUPABASE_ANON_KEY`).
/// The project must live in the `eu-central-1` (Frankfurt) region. Only the public
/// anon key ships in the app – the service-role key never does.
struct SupabaseConfig {
    var url: URL
    var anonKey: String

    static func fromBundle() -> SupabaseConfig? {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              let url = URL(string: urlString),
              !urlString.contains("YOUR-PROJECT"), !key.isEmpty, !key.contains("YOUR-ANON-KEY")
        else { return nil }
        return SupabaseConfig(url: url, anonKey: key)
    }
}

enum Role: String, Codable {
    case owner, admin, estimator

    /// Only Owner/Admin may change firm settings and price books.
    var canManageFirm: Bool { self != .estimator }
}

struct AuthSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: UUID
    var email: String?
    var tenantID: UUID?
    var role: Role?
}

enum BackendError: LocalizedError {
    case notConfigured
    case notSignedIn
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "Supabase is not configured (SUPABASE_URL / SUPABASE_ANON_KEY).")
        case .notSignedIn: String(localized: "Please sign in to sync.")
        case let .http(status, message): "HTTP \(status): \(message)"
        }
    }
}

/// Thin client for the Supabase REST surface the app needs: Auth (email OTP),
/// RPC (`push_mutations`, `pull_changes`) and Storage (media uploads).
/// The app never reads or writes tables directly – only through the RPC boundary.
@Observable
final class BackendClient {
    let config: SupabaseConfig?
    private(set) var session: AuthSession?

    private let urlSession: URLSession
    private static let keychainAccount = "session"

    init(config: SupabaseConfig? = .fromBundle()) {
        self.config = config
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: configuration)
        if let data = KeychainStore.load(account: Self.keychainAccount) {
            session = try? JSONDecoder().decode(AuthSession.self, from: data)
        }
    }

    var isConfigured: Bool { config != nil }
    var isSignedIn: Bool { session != nil }

    // MARK: - Auth (email OTP)

    /// Sends a one-time code. New accounts are only created for invited e-mail addresses:
    /// the server's "Before User Created" hook rejects everyone else.
    func sendOTP(email: String) async throws {
        _ = try await request("auth/v1/otp", body: ["email": email, "create_user": true], authorized: false)
    }

    func verifyOTP(email: String, code: String) async throws {
        let data = try await request("auth/v1/verify", body: ["type": "email", "email": email, "token": code], authorized: false)
        try storeSession(from: data)
    }

    func signOut() async {
        if session != nil {
            _ = try? await request("auth/v1/logout", body: [String: String](), authorized: true)
        }
        session = nil
        KeychainStore.delete(account: Self.keychainAccount)
    }

    /// Refreshes the short-lived access token using the rotating refresh token.
    func refreshIfNeeded() async throws {
        guard let current = session else { throw BackendError.notSignedIn }
        guard current.expiresAt.timeIntervalSinceNow < 60 else { return }
        do {
            let data = try await request("auth/v1/token?grant_type=refresh_token", body: ["refresh_token": current.refreshToken], authorized: false)
            try storeSession(from: data)
        } catch BackendError.http(let status, _) where (400..<500).contains(status) {
            // Refresh token revoked or expired – require a new sign-in.
            await signOut()
            throw BackendError.notSignedIn
        }
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String
        var expires_in: Double
        var user: User
        struct User: Decodable { var id: UUID; var email: String? }
    }

    /// Custom claims added by the `custom_access_token_hook` in the database.
    private struct Claims: Decodable {
        var tenant_id: UUID?
        var user_role: Role?
    }

    private func storeSession(from data: Data) throws {
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let claims = Self.decodeClaims(token.access_token)
        let newSession = AuthSession(
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            expiresAt: Date().addingTimeInterval(token.expires_in),
            userID: token.user.id,
            email: token.user.email,
            tenantID: claims?.tenant_id,
            role: claims?.user_role
        )
        session = newSession
        KeychainStore.save(try JSONEncoder().encode(newSession), account: Self.keychainAccount)
    }

    /// Reads (does not verify) the JWT payload – the server verifies every request.
    private static func decodeClaims(_ jwt: String) -> Claims? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(Claims.self, from: data)
    }

    // MARK: - RPC & Storage

    /// Calls a Postgres function exposed through PostgREST (`/rest/v1/rpc/<name>`).
    func rpc(_ function: String, params: [String: Any]) async throws -> Data {
        try await refreshIfNeeded()
        let body = try JSONSerialization.data(withJSONObject: params)
        return try await request("rest/v1/rpc/\(function)", bodyData: body, authorized: true)
    }

    /// Uploads a file to a private Storage bucket (path is tenant-scoped by RLS policy).
    func upload(bucket: String, path: String, fileURL: URL, contentType: String) async throws {
        try await refreshIfNeeded()
        guard let config, let session else { throw BackendError.notSignedIn }
        var request = URLRequest(url: config.url.appendingPathComponent("storage/v1/object/\(bucket)/\(path)"))
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let (data, response) = try await urlSession.upload(for: request, fromFile: fileURL)
        try Self.validate(response, data: data)
    }

    // MARK: - Transport

    private func request(_ path: String, body: [String: Any], authorized: Bool) async throws -> Data {
        try await request(path, bodyData: try JSONSerialization.data(withJSONObject: body), authorized: authorized)
    }

    private func request(_ path: String, bodyData: Data, authorized: Bool) async throws -> Data {
        guard let config else { throw BackendError.notConfigured }
        guard let url = URL(string: path, relativeTo: config.url) else { throw BackendError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if authorized {
            guard let session else { throw BackendError.notSignedIn }
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
