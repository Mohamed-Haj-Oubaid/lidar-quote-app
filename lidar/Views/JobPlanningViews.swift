import SwiftUI
import SwiftData

/// Stage, dates and assigned worker of a job (device-local planning).
struct JobPlanningSection: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var job: Job

    var body: some View {
        Section {
            Picker(selection: $job.stage) {
                ForEach(JobStage.allCases) { stage in
                    Label(stage.title, systemImage: stage.systemImage).tag(stage)
                }
            } label: {
                Label("Stage", systemImage: job.stage.systemImage)
            }
            Toggle("Scheduled", isOn: Binding(
                get: { job.plannedStart != nil },
                set: { scheduled in
                    job.plannedStart = scheduled ? (job.plannedStart ?? Calendar.current.startOfDay(for: .now)) : nil
                    job.plannedEnd = scheduled ? (job.plannedEnd ?? job.plannedStart) : nil
                }
            ))
            if let start = job.plannedStart {
                DatePicker("Start", selection: Binding(get: { start }, set: { newStart in
                    job.plannedStart = newStart
                    if let end = job.plannedEnd, end < newStart { job.plannedEnd = newStart }
                }), displayedComponents: .date)
                DatePicker("End", selection: Binding(get: { job.plannedEnd ?? start }, set: { job.plannedEnd = $0 }),
                           in: start..., displayedComponents: .date)
            }
            TextField("Assigned worker / team", text: $job.assignedWorker)
                .textContentType(.name)
            TextField("Planning notes", text: $job.planningNotes, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("Planning")
        } footer: {
            Text("Planning is stored on this device.")
        }
        .onChange(of: job.stageRaw) { try? modelContext.save() }
        .onDisappear { try? modelContext.save() }
    }
}

/// Upcoming work sorted by start date, grouped by week.
struct ScheduleView: View {
    @Query(sort: \Job.updatedAt, order: .reverse) private var jobs: [Job]

    private var scheduled: [Job] {
        jobs.filter { $0.plannedStart != nil && $0.stage != .paid }
            .sorted { ($0.plannedStart ?? .distantFuture) < ($1.plannedStart ?? .distantFuture) }
    }

    private var weeks: [(start: Date, jobs: [Job])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: scheduled) { job in
            calendar.dateInterval(of: .weekOfYear, for: job.plannedStart ?? .now)?.start ?? .now
        }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(weeks, id: \.start) { week in
                Section {
                    ForEach(week.jobs) { job in
                        NavigationLink(value: job) { ScheduleRow(job: job) }
                    }
                } header: {
                    let week = Calendar.current.component(.weekOfYear, from: week.start)
                    Text("Week \(week)")
                }
            }
            let unscheduled = jobs.filter { $0.plannedStart == nil && [.ordered, .inProgress].contains($0.stage) }
            if !unscheduled.isEmpty {
                Section("Ordered, not scheduled") {
                    ForEach(unscheduled) { job in
                        NavigationLink(value: job) { ScheduleRow(job: job) }
                    }
                }
            }
        }
        .overlay {
            if scheduled.isEmpty {
                ContentUnavailableView("Nothing Scheduled", systemImage: "calendar",
                                       description: Text("Set start dates in a job's planning section."))
            }
        }
        .navigationTitle("Schedule")
    }
}

private struct ScheduleRow: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.title).font(.headline)
                Spacer()
                StageBadge(stage: job.stage)
            }
            if let start = job.plannedStart {
                let end = job.plannedEnd ?? start
                Text(Calendar.current.isDate(start, inSameDayAs: end)
                     ? start.formatted(date: .abbreviated, time: .omitted)
                     : "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline)
            }
            let details = [job.assignedWorker, job.siteAddress].filter { !$0.isEmpty }
            if !details.isEmpty {
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct StageBadge: View {
    let stage: JobStage

    var body: some View {
        Label(stage.title, systemImage: stage.systemImage)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch stage {
        case .inquiry: .gray
        case .survey: .blue
        case .quoted: .orange
        case .ordered: .purple
        case .inProgress: .indigo
        case .invoiced: .teal
        case .paid: .green
        }
    }
}

/// Owner/Admin only: revenue of the latest quote against the material purchase cost.
struct JobProfitSection: View {
    @Environment(\.modelContext) private var modelContext
    let job: Job

    /// Latest quote that still counts (not rejected or replaced).
    private var quote: Quote? {
        job.sortedQuotes.first { !["rejected", "superseded"].contains($0.status) }
    }

    var body: some View {
        if let quote, let calculation = quote.calculation {
            let materials = LocalStore.settings(in: modelContext).materials
            let needs = MaterialCalculator.needs(for: job.sortedSurveys.map(\.measurement), materials: materials)
            let purchase = MaterialCalculator.totalCost(needs)
            let profit = calculation.netTotalCents - purchase
            Section {
                LabeledContent("Revenue (net)", value: Formatters.money(calculation.netTotalCents))
                if let labor = calculation.laborTotalCents {
                    LabeledContent("of which material", value: Formatters.money(calculation.netTotalCents - labor))
                    LabeledContent("of which labour", value: Formatters.money(labor))
                }
                LabeledContent("Material purchase", value: "− \(Formatters.money(purchase))")
                LabeledContent("Gross profit") {
                    let margin = calculation.netTotalCents > 0 ? Double(profit) / Double(calculation.netTotalCents) : 0
                    Text("\(Formatters.money(profit)) (\(margin.formatted(.percent.precision(.fractionLength(0)))))")
                        .foregroundStyle(profit >= 0 ? .green : .red)
                        .bold()
                }
            } header: {
                Text("Profit (quote \(quote.displayNumber))")
            } footer: {
                Text("Gross profit = net revenue − material purchase cost from the material list, before wages. Only owners and admins see this.")
            }
        }
    }
}
