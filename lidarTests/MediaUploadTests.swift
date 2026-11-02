import Foundation
import SwiftData
import Testing
@testable import lidar

/// H8 – one failing media upload never fails the sync; it backs off and retries.
@MainActor
@Suite(.serialized)
struct MediaUploadTests {
    @Test func failingFileIsSkippedAndRetriedLater() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        LocalStore.seedIfNeeded(in: context)
        let tenant = UUID()
        let settings = LocalStore.settings(in: context)
        settings.tenantID = tenant
        settings.mediaDeviceOnly = false
        let backend = FakeBackend(session: makeSession(user: UUID(), tenant: tenant))
        let sync = SyncManager(container: container, backend: backend, monitorsConnectivity: false)
        var clock = Date(timeIntervalSince1970: 2_000_000)
        sync.now = { clock }

        let job = Job(title: "Job")
        context.insert(job)
        var surveys: [Survey] = []
        for index in 0..<2 {
            let survey = Survey(roomName: "Room \(index)", measurement: .empty, job: job)
            let fileName = "test-\(survey.id.uuidString).usdz"
            try Data("usdz".utf8).write(to: try SurveyEngine.mediaURL(for: fileName))
            survey.usdzFileName = fileName
            context.insert(survey)
            surveys.append(survey)
        }
        try context.save()
        defer { for survey in surveys { try? FileManager.default.removeItem(at: try SurveyEngine.mediaURL(for: survey.usdzFileName!)) } }

        backend.failingUploads = [surveys[0].usdzFileName!]
        await sync.syncNow()

        #expect(sync.status == .idle)                 // the sync itself succeeded
        #expect(!surveys[0].mediaUploaded && surveys[0].mediaNextAttemptAt == clock.addingTimeInterval(2))
        #expect(surveys[1].mediaUploaded)
        #expect(sync.failedMediaUploads == 1)

        backend.failingUploads = []
        await sync.syncNow()                          // still inside the backoff window
        #expect(!surveys[0].mediaUploaded)

        clock = clock.addingTimeInterval(3)
        await sync.syncNow()
        #expect(surveys[0].mediaUploaded)
        #expect(sync.failedMediaUploads == 0)
    }
}
