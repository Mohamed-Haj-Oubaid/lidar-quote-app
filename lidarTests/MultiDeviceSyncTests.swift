import Foundation
import SwiftData
import Testing
@testable import lidar

/// H3 – two devices of the same company converge through pull_changes.
@MainActor
@Suite(.serialized)
struct MultiDeviceSyncTests {
    let tenant = UUID()
    let bookID = UUID()
    let item = PriceItem(id: UUID(), code: "MAL-01", name: "Paint", basis: .floorArea, unitPriceCents: 1250,
                         openingRule: .noDeduction, defaultWastePercent: 0)

    struct Device {
        let context: ModelContext
        let backend: FakeBackend
        let sync: SyncManager

        func use() { LocalStore.actingUserID = backend.session?.userID }
        func jobs() throws -> [Job] { try context.fetch(FetchDescriptor<Job>()) }
        func surveys() throws -> [Survey] { try context.fetch(FetchDescriptor<Survey>()) }
    }

    private func makeDevice(server: FakeServer) throws -> Device {
        let container = try makeTestContainer()
        let context = container.mainContext
        LocalStore.seedIfNeeded(in: context)
        LocalStore.settings(in: context).tenantID = tenant
        // Same company price book on both devices (normally pulled from the server).
        context.insert(PriceBookVersion(id: bookID, priceBookID: UUID(), name: "Standard", version: 1, vatRateBasisPoints: 1900,
                                        publishedAt: .now, items: [item], isActive: true, isLocalSample: false))
        for sample in try context.fetch(FetchDescriptor<PriceBookVersion>()) where sample.isLocalSample { sample.isActive = false }
        try context.save()
        let backend = FakeBackend(session: makeSession(user: UUID(), tenant: tenant))
        backend.server = server
        return Device(context: context, backend: backend,
                      sync: SyncManager(container: container, backend: backend, monitorsConnectivity: false))
    }

    private func createJobWithRoom(on device: Device) throws -> (Job, Survey) {
        device.use()
        let job = Job(title: "Bad Müller", clientName: "Frau Müller")
        device.context.insert(job)
        try LocalStore.save(job: job, in: device.context)
        let survey = Survey(roomName: "Bad", measurement: .rectangle(width: 3, depth: 2, height: 2.5), job: job)
        survey.selections = [ItemSelection(itemID: item.id, wastePercent: 0)]
        device.context.insert(survey)
        try LocalStore.save(survey: survey, in: device.context)
        return (job, survey)
    }

    private func sync(_ device: Device) async {
        device.use()
        await device.sync.syncNow()
    }

    @Test func devicesConvergeOnCreateRenameAndDelete() async throws {
        let server = FakeServer()
        let a = try makeDevice(server: server)
        let b = try makeDevice(server: server)

        let (job, survey) = try createJobWithRoom(on: a)
        await sync(a)
        await sync(b)

        let jobOnB = try #require(try b.jobs().first)
        #expect(jobOnB.id == job.id && jobOnB.clientName == "Frau Müller")
        let roomOnB = try #require(try b.surveys().first)
        #expect(roomOnB.id == survey.id)
        #expect(roomOnB.measurement == survey.measurement)
        #expect(roomOnB.selections == survey.selections)

        // B renames, A picks it up.
        b.use()
        try LocalStore.rename(survey: roomOnB, to: "Gäste-WC", in: b.context)
        await sync(b)
        await sync(a)
        #expect(try a.surveys().first?.roomName == "Gäste-WC")

        // A deletes the room, it disappears on B.
        a.use()
        try LocalStore.delete(survey: try #require(try a.surveys().first), in: a.context)
        await sync(a)
        await sync(b)
        #expect(try b.surveys().isEmpty)

        // A deletes the job, it disappears on B.
        a.use()
        try LocalStore.delete(job: try #require(try a.jobs().first), in: a.context)
        await sync(a)
        await sync(b)
        #expect(try b.jobs().isEmpty)
    }

    @Test func pendingLocalChangeWinsOverServerRow() async throws {
        let server = FakeServer()
        let a = try makeDevice(server: server)
        let b = try makeDevice(server: server)
        let (job, _) = try createJobWithRoom(on: a)
        await sync(a)
        await sync(b)

        // B edits offline; its push is postponed (backoff) so the change stays pending.
        let jobOnB = try #require(try b.jobs().first)
        b.use()
        jobOnB.title = "B's title"
        try LocalStore.save(job: jobOnB, in: b.context)
        let pending = try #require(try b.context.fetch(FetchDescriptor<PendingMutation>()).first)
        pending.nextAttemptAt = .now.addingTimeInterval(3600)

        // Meanwhile A changes the same job.
        a.use()
        job.title = "A's title"
        try LocalStore.save(job: job, in: a.context)
        await sync(a)

        await sync(b)
        #expect(jobOnB.title == "B's title")
    }

    @Test func quotesArriveWithOfficialNumberAndPDF() async throws {
        let server = FakeServer()
        let a = try makeDevice(server: server)
        let b = try makeDevice(server: server)
        let (job, survey) = try createJobWithRoom(on: a)
        let book = try #require(LocalStore.activePriceBook(in: a.context))
        let calculation = EstimationEngine.calculate(
            rooms: [RoomInput(surveyID: survey.id, roomName: survey.roomName, measurement: survey.measurement, selections: survey.selections)],
            priceBook: book.snapshot)
        let quote = try LocalStore.issueQuote(for: job, calculation: calculation, in: a.context)
        await sync(a)
        #expect(quote.finalNumber == "T-2026-00001")

        await sync(b)
        let quoteOnB = try #require(try b.context.fetch(FetchDescriptor<Quote>()).first)
        #expect(quoteOnB.id == quote.id)
        #expect(quoteOnB.finalNumber == "T-2026-00001")
        #expect(quoteOnB.calculation == calculation)
        #expect(quoteOnB.snapshotSHA256 == quote.snapshotSHA256)
        #expect(quoteOnB.pdfData != nil)
        #expect(quoteOnB.job?.id == job.id)
    }

    @Test func erasedClientDataOverwritesLocalCopy() async throws {
        let server = FakeServer()
        let a = try makeDevice(server: server)
        let b = try makeDevice(server: server)
        let (job, _) = try createJobWithRoom(on: a)
        await sync(a)
        await sync(b)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let erasedAt = formatter.string(from: .now)
        server.touchJob(job.id) { row in
            row["title"] = "Erased job"
            row["client_name"] = NSNull()
            row["client_email"] = NSNull()
            row["client_data_erased_at"] = erasedAt
            row["updated_at"] = erasedAt
        }
        await sync(b)
        let jobOnB = try #require(try b.jobs().first)
        #expect(jobOnB.clientName.isEmpty)
        #expect(jobOnB.title == "Erased job")
        #expect(jobOnB.clientDataErasedAt != nil)
    }
}
