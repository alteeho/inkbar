import AppKit
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @MainActor
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let language = LanguageSettings.shared
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = language.t("login.error.title")
            alert.informativeText = language.format("login.error.body", error.localizedDescription)
            alert.addButton(withTitle: language.t("ok"))
            alert.runModal()
            return false
        }
    }
}
