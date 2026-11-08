import SwiftUI
import SwiftData

struct JobDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BackendClient.self) private var backend
    @Environment(SyncManager.self) private var sync
    @Bindable var job: Job

    @State private var isConfirmingErase = false
    @State private var eraseError: String?
    @State private var isEditing = false
    @State private var isShowingPrivacyNotice = false
    @State private var isScanning = false
    @State private var isAddingManualRoom = false
    @State private var isSketching = false

    var body: some View {
        List {
            Section("Client") {
                if let erased = job.clientDataErasedAt {
                    Label("Client data erased \(erased.formatted(date: .abbreviated, time: .omitted))", systemImage: "person.crop.circle.badge.xmark")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Name", value: job.clientName.isEmpty ? "–" : job.clientName)
                if !job.siteAddress.isEmpty {
                    LabeledContent("Site", value: job.siteAddress)
                }
                if !job.clientEmail.isEmpty {
                    LabeledContent("Email", value: job.clientEmail)
                }
                if !job.clientPhone.isEmpty {
                    LabeledContent("Phone", value: job.clientPhone)
                }
            }

            Section {
                if let confirmed = job.privacyNoticeConfirmedAt {
                    Label("Privacy notice shown \(confirmed.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                } else {
                    Button("Show Privacy Notice to Client", systemImage: "hand.raised") {
                        isShowingPrivacyNotice = true
                    }
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("The client must be informed before their home is scanned.")
            }

            Section("Rooms") {
                ForEach(job.sortedSurveys) { survey in
                    NavigationLink(value: survey) {
                        RoomRow(survey: survey)
                    }
                }
                .onDelete(perform: deleteRooms)

                Button("Scan Room with LiDAR", systemImage: "viewfinder") {
                    isScanning = true
                }
                .disabled(job.privacyNoticeConfirmedAt == nil || !SurveyEngine.isScanningSupported)

                Button("Draw Floor Plan & Laser Measure", systemImage: "pencil.and.outline") {
                    isSketching = true
                }

                Button("Add Room Manually", systemImage: "square.and.pencil") {
                    isAddingManualRoom = true
                }

                if !SurveyEngine.isScanningSupported {
                    Text("This device has no LiDAR scanner. Enter rooms manually or use an iPhone Pro / iPad Pro.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Quotes") {
                ForEach(job.sortedQuotes) { quote in
                    NavigationLink(value: quote) {
                        QuoteRow(quote: quote)
                    }
                }
                NavigationLink {
                    QuoteBuilderView(job: job)
                } label: {
                    Label("Create Quote", systemImage: "doc.badge.plus")
                }
                .disabled(job.surveys.isEmpty)
            }

            WorkProofSection(job: job)
        }
        .navigationTitle(job.title)
        .navigationDestination(for: Survey.self) { survey in
            RoomDetailView(survey: survey)
        }
        .navigationDestination(for: Quote.self) { quote in
            QuotePreviewView(quote: quote)
        }
        .navigationDestination(for: WorkProof.self) { proof in
            WorkProofView(proof: proof)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { isEditing = true }
            }
            if backend.session?.role?.canManageFirm == true, job.clientDataErasedAt == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Erase Client Data…", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                            isConfirmingErase = true
                        }
                        .disabled(!sync.isOnline)
                    }
                }
            }
        }
        .confirmationDialog("Erase this client's personal data?", isPresented: $isConfirmingErase, titleVisibility: .visible) {
            Button("Erase Permanently", role: .destructive) { Task { await eraseClientData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Name, contact details, site address and 3D models of this job are deleted on the server and all devices (GDPR Art. 17). Quotes stay for commercial record-keeping. This cannot be undone.")
        }
        .alert("Erasure failed", isPresented: Binding(get: { eraseError != nil }, set: { if !$0 { eraseError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(eraseError ?? "")
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack { JobFormView(job: job) }
        }
        .sheet(isPresented: $isShowingPrivacyNotice) {
            NavigationStack { PrivacyNoticeView(job: job) }
        }
        .sheet(isPresented: $isAddingManualRoom) {
            NavigationStack { ManualRoomView(job: job) }
        }
        .fullScreenCover(isPresented: $isScanning) {
            ScanRoomView(job: job)
        }
        .fullScreenCover(isPresented: $isSketching) {
            NavigationStack { SketchRoomView(job: job) }
        }
    }

    /// Server first (it is authoritative), then Storage files, then the local copy.
    private func eraseClientData() async {
        do {
            try await backend.eraseClientData(jobID: job.id)
            try LocalStore.applyClientErasure(to: job, in: modelContext)
        } catch {
            eraseError = error.localizedDescription
        }
    }

    private func deleteRooms(at offsets: IndexSet) {
        let surveys = job.sortedSurveys
        for index in offsets {
            // Also queues delete_survey so the room disappears on the server and other devices.
            try? LocalStore.delete(survey: surveys[index], in: modelContext)
        }
    }
}

private struct RoomRow: View {
    let survey: Survey

    var body: some View {
        let m = survey.measurement
        VStack(alignment: .leading, spacing: 2) {
            Text(survey.roomName)
                .font(.headline)
            Text("Floor \(Formatters.meters(m.floorArea, suffix: "m²")) · Walls \(Formatters.meters(m.grossWallArea, suffix: "m²")) · \(m.doorCount) doors · \(m.windowCount) windows")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct QuoteRow: View {
    let quote: Quote

    private var statusColor: Color {
        if quote.isProvisional { return .orange }
        switch quote.status {
        case "accepted": return .green
        case "rejected", "superseded": return .secondary
        default: return .blue
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.displayNumber)
                    .font(.headline.monospaced())
                Text("Revision \(quote.revision) · \(quote.issuedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let calculation = quote.calculation {
                    Text(Formatters.money(calculation.grossTotalCents))
                        .font(.subheadline.monospacedDigit())
                }
                Text(quote.isProvisional ? String(localized: "Provisional") : QuoteStatus.title(quote.status))
                    .font(.caption2.bold())
                    .foregroundStyle(statusColor)
            }
        }
    }
}

/// Art. 13 GDPR notice shown to the end client before scanning; confirmation is logged on the job.
struct PrivacyNoticeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var job: Job

    var body: some View {
        let settings = LocalStore.settings(in: modelContext)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(settings.firmName)
                    .font(.title2.bold())
                Text(settings.privacyNoticeText)
                    .font(.body)
            }
            .padding()
        }
        .navigationTitle("Privacy Notice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Client Informed") {
                    job.privacyNoticeConfirmedAt = .now
                    try? LocalStore.save(job: job, in: modelContext)
                    dismiss()
                }
            }
        }
    }
}
