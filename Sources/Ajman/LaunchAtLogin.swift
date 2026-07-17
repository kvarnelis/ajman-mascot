import Foundation
import ServiceManagement

struct LaunchAtLogin {
    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ on: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(
                domain: "net.varnelis.Ajman.LaunchAtLogin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Launch at Login requires macOS 13 or later."]
            )
        }

        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
