import AppKit

@main
enum InkbarMain {
    static func main() {
        let delegate = AppDelegate()
        InkbarMain.retainedDelegate = delegate

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }

    private static var retainedDelegate: AppDelegate?
}
