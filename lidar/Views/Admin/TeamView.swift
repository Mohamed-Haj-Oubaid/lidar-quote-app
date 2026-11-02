import SwiftUI

/// Settings → Company → Team. Online-only; the server enforces every permission.
struct TeamView: View {
    @Environment(BackendClient.self) private var backend
    @Environment(SyncManager.self) private var sync

    @State private var team: Team?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var inviteEmail = ""
    @State private var inviteRole = Role.estimator
    @State private var memberToRemove: TeamMember?

    private var myRole: Role? { backend.session?.role }
    private var isOwner: Bool { myRole == .owner }
    /// Owners invite admins and estimators, admins only estimators.
    private var invitableRoles: [Role] { isOwner ? [.admin, .estimator] : [.estimator] }

    var body: some View {
        Form {
            if !sync.isOnline {
                Section {
                    Label("Team management needs an internet connection.", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Invite") {
                TextField("Email", text: $inviteEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                Picker("Role", selection: $inviteRole) {
                    ForEach(invitableRoles, id: \.self) { role in
                        Text(role.title).tag(role)
                    }
                }
                Button("Send Invitation") { run { try await backend.inviteMember(email: inviteEmail, role: inviteRole); inviteEmail = "" } }
                    .disabled(inviteEmail.isEmpty || !sync.isOnline || isLoading)
            }

            if let team {
                Section("Members") {
                    ForEach(team.members) { member in
                        memberRow(member)
                    }
                }
                if !team.invitations.isEmpty {
                    Section("Open invitations") {
                        ForEach(team.invitations) { invitation in
                            LabeledContent(invitation.email, value: invitation.role.title)
                                .swipeActions {
                                    Button("Revoke", role: .destructive) {
                                        run { try await backend.revokeInvitation(invitation.id) }
                                    }
                                }
                        }
                    }
                }
            } else if isLoading {
                ProgressView()
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("Team")
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("Remove member?", isPresented: Binding(
            get: { memberToRemove != nil },
            set: { if !$0 { memberToRemove = nil } }
        ), titleVisibility: .visible, presenting: memberToRemove) { member in
            Button("Remove \(member.email)", role: .destructive) {
                run { try await backend.removeMember(member.userID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Their access ends immediately on all devices.")
        }
    }

    @ViewBuilder
    private func memberRow(_ member: TeamMember) -> some View {
        let isMe = member.userID == backend.session?.userID
        HStack {
            VStack(alignment: .leading) {
                Text(member.displayName ?? member.email)
                if member.displayName != nil {
                    Text(member.email).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isOwner, !isMe, member.role != .owner {
                Menu(member.role.title) {
                    ForEach([Role.admin, .estimator], id: \.self) { role in
                        Button(role.title) { run { try await backend.changeRole(of: member.userID, to: role) } }
                    }
                }
                .disabled(!sync.isOnline)
            } else {
                Text(member.role.title).foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            // The owner can remove admins/estimators; admins only estimators.
            if !isMe, member.role != .owner, isOwner || member.role == .estimator {
                Button("Remove", role: .destructive) { memberToRemove = member }
            }
        }
    }

    private func reload() async {
        guard sync.isOnline else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            team = try await backend.getTeam()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                try await action()
                errorMessage = nil
                team = try await backend.getTeam()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension Role {
    var title: String {
        switch self {
        case .owner: String(localized: "Owner")
        case .admin: String(localized: "Admin")
        case .estimator: String(localized: "Estimator")
        }
    }
}

/// Settings → Company section, shown to Owner and Admin only.
struct CompanyAdminSection: View {
    @Environment(BackendClient.self) private var backend
    @Environment(SyncManager.self) private var sync
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var isExporting = false

    var body: some View {
        Section {
            NavigationLink("Team") { TeamView() }
            NavigationLink("Price Book") { PriceBookEditorView() }
            if backend.session?.role == .owner {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share Company Export", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button(isExporting ? "Exporting…" : "Export Company Data", systemImage: "externaldrive") {
                        Task { await export() }
                    }
                    .disabled(!sync.isOnline || isExporting)
                }
            }
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Company administration")
        } footer: {
            Text("Team, price book and export need an internet connection.")
        }
    }

    private func export() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await backend.exportCompanyData()
            let stamp = Date.now.formatted(.iso8601.year().month().day())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("company-export-\(stamp).json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}
