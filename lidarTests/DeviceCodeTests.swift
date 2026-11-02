import Foundation
import SwiftData
import Testing
@testable import lidar

/// M5 – unambiguous 6-character device codes.
@MainActor
@Suite(.serialized)
struct DeviceCodeTests {
    @Test func codesUseTheUnambiguousAlphabet() {
        let allowed = Set(LocalStore.deviceCodeAlphabet)
        for _ in 0..<200 {
            let code = LocalStore.makeDeviceCode()
            #expect(code.count == 6)
            #expect(code.allSatisfy(allowed.contains))
        }
        #expect(!allowed.contains("0") && !allowed.contains("O") && !allowed.contains("1") && !allowed.contains("I"))
    }

    @Test func unusedOldCodesAreUpgradedUsedOnesKept() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let unused = TenantSettings(deviceCode: "AB12")
        context.insert(unused)
        #expect(LocalStore.settings(in: context).deviceCode.count == 6)

        let used = LocalStore.settings(in: context)
        used.deviceCode = "CD34"
        used.nextProvisionalSequence = 5          // numbers with CD34 were already handed out
        #expect(LocalStore.settings(in: context).deviceCode == "CD34")
    }
}
