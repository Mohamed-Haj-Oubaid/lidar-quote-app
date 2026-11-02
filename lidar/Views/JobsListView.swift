import SwiftUI
import SwiftData

struct JobsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Job.updatedAt, order: .reverse) private var jobs: [Job]
    @State private var isCreatingJob = false
    @State private var isShowingSettings = false
    @State private var jobToDelete: Job?

    var body: some View {
        List {
            ForEach(jobs) { job in
                NavigationLink(value: job) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.title)
                            .font(.headline)
                        if !job.clientName.isEmpty {
                            Text(job.clientName)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(job.surveys.count) rooms · \(job.quotes.count) quotes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        jobToDelete = job
                    }
                }
            }
        }
        .confirmationDialog("Delete this job?", isPresented: Binding(
            get: { jobToDelete != nil },
            set: { if !$0 { jobToDelete = nil } }
        ), titleVisibility: .visible, presenting: jobToDelete) { job in
            Button("Delete Job", role: .destructive) {
                try? LocalStore.delete(job: job, in: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: { job in
            if job.quotes.isEmpty {
                Text("\(job.title) and its rooms are deleted on all devices.")
            } else {
                Text("\(job.title) and its rooms are deleted on all devices. Its \(job.quotes.count) issued quotes stay on the server for commercial record-keeping.")
            }
        }
        .overlay {
            if jobs.isEmpty {
                ContentUnavailableView {
                    Label("No Jobs", systemImage: "ruler")
                } description: {
                    Text("Create a job to scan rooms and issue a quote – no connection needed.")
                } actions: {
                    Button("New Job") { isCreatingJob = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Jobs")
        .navigationDestination(for: Job.self) { job in
            JobDetailView(job: job)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                SyncStatusBadge()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Job", systemImage: "plus") { isCreatingJob = true }
            }
        }
        .sheet(isPresented: $isCreatingJob) {
            NavigationStack { JobFormView(job: nil) }
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack { SettingsView() }
        }
    }
}

/// Create or edit a job and its end-client contact details.
struct JobFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let job: Job?

    @State private var title = ""
    @State private var clientName = ""
    @State private var clientEmail = ""
    @State private var clientPhone = ""
    @State private var siteAddress = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Job") {
                TextField("Title", text: $title)
                TextField("Site address", text: $siteAddress, axis: .vertical)
            }
            Section("Client") {
                TextField("Name", text: $clientName)
                    .textContentType(.name)
                TextField("Email", text: $clientEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                TextField("Phone", text: $clientPhone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle(job == nil ? "New Job" : "Edit Job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard let job else { return }
            title = job.title
            clientName = job.clientName
            clientEmail = job.clientEmail
            clientPhone = job.clientPhone
            siteAddress = job.siteAddress
        }
    }

    private func save() {
        let target = job ?? Job(title: title)
        if job == nil { modelContext.insert(target) }
        target.title = title
        target.clientName = clientName
        target.clientEmail = clientEmail
        target.clientPhone = clientPhone
        target.siteAddress = siteAddress
        do {
            try LocalStore.save(job: target, in: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
