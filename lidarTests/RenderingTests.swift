import Foundation
import SwiftData
import Testing
@testable import lidar

/// M2 – cached decoding stays correct; share file names are safe.
@MainActor
@Suite(.serialized)
struct RenderingTests {
    @Test func cachedMeasurementIsInvalidatedBySetters() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let job = Job(title: "Job")
        context.insert(job)
        let survey = Survey(roomName: "A", measurement: .rectangle(width: 2, depth: 2, height: 2.5), job: job)
        context.insert(survey)
        #expect(abs(survey.measurement.floorArea - 4) < 1e-9)
        survey.measurement = .rectangle(width: 3, depth: 3, height: 2.5)
        #expect(abs(survey.measurement.floorArea - 9) < 1e-9)
        let itemID = UUID()
        #expect(survey.selections.isEmpty)
        survey.selections = [ItemSelection(itemID: itemID, wastePercent: 5)]
        #expect(survey.selections.map(\.itemID) == [itemID])
    }

    @Test func shareFileNamesHaveNoPathSeparators() {
        #expect(QuotePreviewView.fileName(for: "ANG-2026-00001") == "ANG-2026-00001")
        #expect(QuotePreviewView.fileName(for: "A/B:C") == "A-B-C")
        #expect(QuotePreviewView.fileName(for: "  ") == "Quote")
    }
}
