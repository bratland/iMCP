import OSLog
import ServiceManagement
import SwiftUI

private let log = Logger(subsystem: "com.loopwork.iMCP", category: "launch-at-login")

@MainActor
final class LaunchAtLoginController: ObservableObject {
    static let shared = LaunchAtLoginController()

    @Published private(set) var isEnabled: Bool

    private init() {
        self.isEnabled = Self.currentStatusIsEnabled()
    }

    func refresh() {
        isEnabled = Self.currentStatusIsEnabled()
    }

    func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else {
                    isEnabled = true
                    return
                }
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            log.error("Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
        }
        isEnabled = Self.currentStatusIsEnabled()
    }

    var binding: Binding<Bool> {
        Binding(
            get: { self.isEnabled },
            set: { self.setEnabled($0) }
        )
    }

    private static func currentStatusIsEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}
