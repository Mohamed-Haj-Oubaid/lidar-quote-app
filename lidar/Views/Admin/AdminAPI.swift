import Foundation

/// Typed wrappers around the Owner/Admin RPCs in 04_rpc.sql. These calls are
/// online-only; the server enforces the role on every call.
struct TeamMember: Decodable, Identifiable, Hashable {
    var userID: UUID
    var email: String
    var displayName: String?
    var role: Role
    var id: UUID { userID }

    enum CodingKeys: String, CodingKey {
        case email, role
        case userID = "user_id", displayName = "display_name"
    }
}

struct TeamInvitation: Decodable, Identifiable, Hashable {
    var id: UUID
    var email: String
    var role: Role
}

/// An open invitation for the signed-in account (needs the person's consent).
struct MyInvitation: Decodable {
    var company: String
    var role: Role
}

struct Team: Decodable {
    var members: [TeamMember]
    var invitations: [TeamInvitation]
}

extension BackendClient {
    private static let decoder: JSONDecoder = JSONDecoder()

    /// The open invitation for this account, or nil.
    func myInvitation() async throws -> MyInvitation? {
        let data = try await rpc("get_my_invitation", params: [:])
        if (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) is NSNull { return nil }
        return try? Self.decoder.decode(MyInvitation.self, from: data)
    }

    /// Joins the inviting company and refreshes the token so it carries the new claims.
    func acceptInvitation() async throws {
        _ = try await rpc("accept_invitation", params: [:])
        try await refresh(force: true)
    }

    func getTeam() async throws -> Team {
        try Self.decoder.decode(Team.self, from: try await rpc("get_team", params: [:]))
    }

    func inviteMember(email: String, role: Role) async throws {
        _ = try await rpc("invite_member", params: ["p_email": email, "p_role": role.rawValue])
    }

    func revokeInvitation(_ id: UUID) async throws {
        _ = try await rpc("revoke_invitation", params: ["p_invitation_id": id.uuidString])
    }

    func removeMember(_ userID: UUID) async throws {
        _ = try await rpc("remove_member", params: ["p_user_id": userID.uuidString])
    }

    func changeRole(of userID: UUID, to role: Role) async throws {
        _ = try await rpc("change_member_role", params: ["p_user_id": userID.uuidString, "p_role": role.rawValue])
    }

    /// Publishes a new immutable version. Pass `priceBookID: nil` to create a new book.
    func publishPriceBook(priceBookID: UUID?, name: String, vatRateBasisPoints: Int, items: [PriceItem]) async throws {
        let itemsJSON = try JSONSerialization.jsonObject(with: try StoreCoding.encoder.encode(items))
        var params: [String: Any] = ["p_name": name, "p_vat_rate_bp": vatRateBasisPoints, "p_items": itemsJSON]
        params["p_price_book_id"] = priceBookID?.uuidString ?? NSNull()
        _ = try await rpc("publish_price_book_version", params: params)
    }

    func activatePriceBookVersion(_ id: UUID) async throws {
        _ = try await rpc("set_active_price_book_version", params: ["p_version_id": id.uuidString])
    }

    /// Erases the end client's personal data (Art. 17) on the server and deletes the
    /// job's files from Storage. Returns the number of deleted files.
    @discardableResult
    func eraseClientData(jobID: UUID) async throws -> Int {
        let data = try await rpc("erase_client_data", params: ["p_job_id": jobID.uuidString])
        let folder = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["media_folder"] as? String
        guard let folder else { return 0 }
        let paths = try await listObjects(bucket: "survey-media", prefix: folder)
        try await deleteObjects(bucket: "survey-media", paths: paths)
        return paths.count
    }

    /// Full company export (Owner) as pretty-printed JSON.
    func exportCompanyData() async throws -> Data {
        let data = try await rpc("export_company_data", params: [:])
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
