import AppKit
import Combine

@MainActor
final class OverlayController: NSObject, ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            restartTimer()
            if isEnabled {
                sync(force: true)
            } else {
                WallpaperCover.shared.restoreAll()
            }
        }
    }

    @Published var coverExternalDisplays: Bool {
        didSet {
            UserDefaults.standard.set(coverExternalDisplays, forKey: Keys.coverExternal)
            sync(force: true)
        }
    }

    @Published var dynamicWallpapers: Bool {
        didSet {
            UserDefaults.standard.set(dynamicWallpapers, forKey: Keys.dynamicWallpapers)
            restartTimer()
            if dynamicWallpapers, isEnabled {
                sync(force: true)
            }
        }
    }

    @Published var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon)
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var wallpaperSource: DispatchSourceFileSystemObject?
    private var wallpaperFolder: Int32 = -1
    private var started = false
    private var syncDebounce: DispatchWorkItem?

    override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.enabled) == nil {
            defaults.set(true, forKey: Keys.enabled)
        }
        if defaults.object(forKey: Keys.dynamicWallpapers) == nil {
            defaults.set(true, forKey: Keys.dynamicWallpapers)
        }
        if defaults.object(forKey: Keys.showMenuBarIcon) == nil {
            defaults.set(true, forKey: Keys.showMenuBarIcon)
        }
        isEnabled = defaults.bool(forKey: Keys.enabled)
        coverExternalDisplays = defaults.bool(forKey: Keys.coverExternal)
        dynamicWallpapers = defaults.bool(forKey: Keys.dynamicWallpapers)
        showMenuBarIcon = defaults.bool(forKey: Keys.showMenuBarIcon)
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        listen()
        watchWallpaperStore()
        restartTimer()
        NSLog("Inkbar start hide=%@", isEnabled.description)
        WallpaperCover.shared.requestScreenAccess()
        sync(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        syncDebounce?.cancel()
        syncDebounce = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        wallpaperSource?.cancel()
        wallpaperSource = nil
        started = false
    }

    /// Restoring happens once when the switch goes off, never from here: every wallpaper event
    /// would otherwise slam the remembered original back over the user's new pick.
    func sync(force: Bool = false) {
        guard started, isEnabled else { return }

        WallpaperCover.shared.applyIfNeeded(
            to: NSScreen.screens.filter(shouldCover),
            force: force,
            followChanges: dynamicWallpapers || force,
            style: CoverStyle(hideNotch: isEnabled)
        )
    }

    private func scheduleSync(force: Bool = false, after delay: TimeInterval = 0.2) {
        syncDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sync(force: force)
        }
        syncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func shouldCover(_ screen: NSScreen) -> Bool {
        if coverExternalDisplays {
            return true
        }
        return screen.hasNotch || screen.isBuiltin
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard started, isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sync()
            }
        }
        timer?.tolerance = 0.5
    }

    private func listen() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(after: 0.55) }
            }
        )

        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(after: 0.15) }
            }
        )

        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(after: 0.25) }
            }
        )

        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(after: 0.4) }
            }
        )

        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(force: true, after: 0.8) }
            }
        )

        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(force: true, after: 0.8) }
            }
        )

        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(after: 0.5) }
            }
        )

        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync(after: 0.4) }
            }
        )
    }

    private func watchWallpaperStore() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        wallpaperFolder = open(url.path, O_EVTONLY)
        guard wallpaperFolder >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: wallpaperFolder,
            eventMask: [.write, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.scheduleSync(after: 1.2)
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.wallpaperFolder >= 0 else { return }
            close(self.wallpaperFolder)
            self.wallpaperFolder = -1
        }
        wallpaperSource = source
        source.resume()
    }

    private enum Keys {
        static let enabled = "inkbar.enabled"
        static let coverExternal = "inkbar.coverExternalDisplays"
        static let dynamicWallpapers = "inkbar.dynamicWallpapers"
        static let showMenuBarIcon = "inkbar.showMenuBarIcon"
    }
}
