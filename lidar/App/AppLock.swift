import Foundation
import LocalAuthentication
import Observation

/// Optional Face ID / passcode lock, engaged whenever the app goes to the background.
/// Protects client data on a lost or shared device.
@Observable
final class AppLock {
    private(set) var isLocked = false

    func lockIfEnabled(_ enabled: Bool) {
        if enabled { isLocked = true }
    }

    func unlock() async {
        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                           localizedReason: String(localized: "Unlock to access jobs and client data"))
            if success { isLocked = false }
        } catch {
            // Stay locked; the user can retry.
        }
    }
}
