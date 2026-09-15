import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

struct CoverStyle: Equatable {
    var hideNotch: Bool
}

/// Paints a true-black menu-bar strip onto the desktop picture.
@MainActor
final class WallpaperCover {
    static let shared = WallpaperCover()

    var hasScreenAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard !didAskScreenAccess else { return false }
        didAskScreenAccess = true
        let granted = CGRequestScreenCaptureAccess()
        log("screen access granted=\(granted)")
        return granted
    }

    private var applyTask: Task<Void, Never>?
    private var pendingForce = false
    private var pendingFollow = true
    private var pendingScreens: [NSScreen] = []
    private var hasPending = false
    private var lastFingerprint: [CGDirectDisplayID: String] = [:]
    private var lastFail: [CGDirectDisplayID: (mark: String, at: TimeInterval)] = [:]
    private var lastReassertAt: [CGDirectDisplayID: TimeInterval] = [:]
    private var lastPaintedStyle: [CGDirectDisplayID: CoverStyle] = [:]
    private var lastWritten: [CGDirectDisplayID: URL] = [:]
    private var lastContentSignature: [CGDirectDisplayID: [UInt8]] = [:]
    private var reassertStreak: [CGDirectDisplayID: Int] = [:]
    private var activeStyle = CoverStyle(hideNotch: true)
    private var applyGeneration = 0
    private var folderAccessStarted = false
    private var lastFailureLog: [CGDirectDisplayID: TimeInterval] = [:]
    private var didAskScreenAccess = false

    private let folder: URL
    private let originals: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("Inkbar", isDirectory: true)
        Self.migrateSupportFolder(
            from: support.appendingPathComponent("Notchless", isDirectory: true),
            to: root
        )
        folder = root
        originals = root.appendingPathComponent("originals", isDirectory: true)
        try? FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        Self.rewriteStoredPaths(
            replacing: "/Application Support/Notchless",
            with: "/Application Support/Inkbar"
        )
        purgeJunk()
        dropPlaceholderOriginals()
        if let url = UserDefaults.standard.string(forKey: Keys.folderPath),
           url.contains("/Application Support/Inkbar") || url.contains("/Application Support/Notchless")
        {
            UserDefaults.standard.removeObject(forKey: Keys.folderBookmark)
            UserDefaults.standard.removeObject(forKey: Keys.folderPath)
        }
    }

    func applyIfNeeded(
        to screens: [NSScreen],
        force: Bool = false,
        followChanges: Bool = true,
        style: CoverStyle
    ) {
        activeStyle = style
        if applyTask != nil {
            hasPending = true
            pendingForce = pendingForce || force
            pendingFollow = pendingFollow || followChanges
            pendingScreens = screens
            return
        }
        applyGeneration += 1
        let generation = applyGeneration
        applyTask = Task { @MainActor in
            activateFolderAccess()
            for screen in screens {
                await apply(
                    to: screen,
                    force: force,
                    followChanges: followChanges,
                    style: style,
                    generation: generation
                )
            }
            applyTask = nil
            if hasPending {
                hasPending = false
                let nextScreens = pendingScreens.isEmpty ? screens : pendingScreens
                let nextForce = pendingForce
                let nextFollow = pendingFollow
                pendingForce = false
                pendingFollow = true
                pendingScreens = []
                applyIfNeeded(to: nextScreens, force: nextForce, followChanges: nextFollow, style: activeStyle)
            }
        }
    }

    func restoreAll() {
        applyGeneration += 1
        hasPending = false
        pendingForce = false
        pendingScreens = []
        for screen in NSScreen.screens {
            restore(screen)
        }
        lastFingerprint.removeAll()
        lastPaintedStyle.removeAll()
        lastWritten.removeAll()
        lastContentSignature.removeAll()
        reassertStreak.removeAll()
        log("restored original wallpaper")
    }

    private func apply(
        to screen: NSScreen,
        force: Bool,
        followChanges: Bool,
        style: CoverStyle,
        generation: Int
    ) async {
        guard generation == applyGeneration else { return }
        guard var current = NSWorkspace.shared.desktopImageURL(for: screen) else { return }

        if isJunk(current) {
            log("skip junk \(current.lastPathComponent)")
            return
        }

        if isManaged(current) {
            setManagedURL(current, for: screen)
            if force || lastPaintedStyle[screen.displayID] != style {
                await restyle(screen, style: style, generation: generation)
            }
            return
        }

        if isSystemPlaceholder(current) {
            await coverPlaceholder(current, screen: screen, style: style, generation: generation)
            return
        }

        let mark = fingerprint(of: current)
        if let failed = lastFail[screen.displayID], failed.mark == mark,
           Date().timeIntervalSince1970 - failed.at < 2
        {
            return
        }

        if let painted = paintedFile(for: screen),
           shouldReassert(current, mark: mark, screen: screen),
           lastPaintedStyle[screen.displayID] == style || lastPaintedStyle[screen.displayID] == nil
        {
            if !isOriginalCopy(current), !isSystemPlaceholder(current) {
                rememberOriginal(current, for: screen)
                rememberSourceMark(mark, for: screen)
            }
            if lastPaintedStyle[screen.displayID] != style {
                await restyle(screen, style: style, generation: generation)
            } else {
                reassert(painted, on: screen, reason: "space-revert \(current.lastPathComponent)")
            }
            return
        }

        if !followChanges, !force {
            return
        }

        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled, generation == applyGeneration else { return }
        guard let settled = NSWorkspace.shared.desktopImageURL(for: screen), !isManaged(settled) else { return }

        var source = settled
        if isSystemPlaceholder(settled), !isSystemPlaceholder(current) {
            source = current
        }
        if isSystemPlaceholder(source) {
            await coverPlaceholder(source, screen: screen, style: style, generation: generation)
            return
        }

        if let painted = paintedFile(for: screen),
           shouldReassert(source, mark: fingerprint(of: source), screen: screen)
        {
            if !isOriginalCopy(source), !isSystemPlaceholder(source) {
                rememberOriginal(source, for: screen)
                rememberSourceMark(fingerprint(of: source), for: screen)
            }
            if lastPaintedStyle[screen.displayID] != style {
                await restyle(screen, style: style, generation: generation)
            } else {
                reassert(painted, on: screen, reason: "space-revert \(source.lastPathComponent)")
            }
            return
        }

        var image = loadImage(from: source)
        if image == nil {
            image = await captureDesktop(of: screen)
        }
        guard let image, image.size.width > 1, image.size.height > 1 else {
            lastFail[screen.displayID] = (mark, Date().timeIntervalSince1970)
            logOnce(screen.displayID, "cannot read \(source.path) preflight=\(CGPreflightScreenCaptureAccess())")
            return
        }

        rememberOriginal(source, for: screen)
        saveOriginalImage(image, displayID: screen.displayID)
        rememberSourceMark(fingerprint(of: source), for: screen)
        commitPaint(image, for: screen, sourceName: source.lastPathComponent, style: style, generation: generation)
    }

    /// Dynamic and picker-managed wallpapers have no file URL. Wait out the gray flash, then
    /// snapshot whatever is actually on the desktop — including a settled solid color.
    private func coverPlaceholder(
        _ url: URL,
        screen: NSScreen,
        style: CoverStyle,
        generation: Int
    ) async {
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard generation == applyGeneration else { return }
        _ = requestScreenAccess()

        for attempt in 0..<10 {
            guard generation == applyGeneration else { return }
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard generation == applyGeneration else { return }
            }

            if let live = NSWorkspace.shared.desktopImageURL(for: screen) {
                if isManaged(live) { return }
                if let image = usableFileImage(live) {
                    paintNewSource(live, image: image, screen: screen, style: style, generation: generation)
                    return
                }
            }

            if let indexURL = currentIndexWallpaperURL(), let image = usableFileImage(indexURL) {
                paintNewSource(indexURL, image: image, screen: screen, style: style, generation: generation)
                return
            }

            guard let captured = await captureDesktop(of: screen, allowFlat: attempt >= 5),
                  captured.size.width > 1
            else { continue }
            if isNearSolid(captured), attempt < 5 {
                continue
            }
            if style.hideNotch, looksPainted(captured, screen: screen) {
                return
            }
            if lastPaintedStyle[screen.displayID] == style,
               let signature = contentSignature(of: captured),
               let previous = lastContentSignature[screen.displayID],
               signaturesMatch(signature, previous)
            {
                return
            }

            UserDefaults.standard.removeObject(forKey: originalKey(screen))
            saveOriginalImage(captured, displayID: screen.displayID)
            rememberSourceMark(fingerprint(of: url), for: screen)
            commitPaint(captured, for: screen, sourceName: "screen", style: style, generation: generation)
            return
        }

        logOnce(screen.displayID, "could not cover \(url.lastPathComponent) preflight=\(CGPreflightScreenCaptureAccess())")
    }

    private func paintNewSource(
        _ source: URL,
        image: NSImage,
        screen: NSScreen,
        style: CoverStyle,
        generation: Int
    ) {
        rememberOriginal(source, for: screen)
        saveOriginalImage(image, displayID: screen.displayID)
        rememberSourceMark(fingerprint(of: source), for: screen)
        commitPaint(image, for: screen, sourceName: source.lastPathComponent, style: style, generation: generation)
    }

    private func usableFileImage(_ url: URL) -> NSImage? {
        guard !isManaged(url), !isJunk(url), !isOriginalCopy(url), !isSystemPlaceholder(url) else { return nil }
        guard let image = loadImage(from: url), image.size.width > 1 else { return nil }
        return image
    }

    private func restyle(_ screen: NSScreen, style: CoverStyle, generation: Int) async {
        guard generation == applyGeneration else { return }
        var image: NSImage?
        if let copy = originalCopy(for: screen) {
            image = loadImage(from: copy)
        }
        if image == nil, let original = rememberedOriginal(for: screen) {
            image = loadImage(from: original)
        }
        guard let image, image.size.width > 1, image.size.height > 1 else {
            // Nothing clean to repaint from, so keep what is on screen instead of retrying forever.
            if let painted = paintedFile(for: screen) {
                lastPaintedStyle[screen.displayID] = style
                log("kept \(painted.lastPathComponent), no original to repaint")
            } else {
                log("restyle missing original for \(screen.displayID)")
            }
            return
        }
        commitPaint(image, for: screen, sourceName: "restyle", style: style, generation: generation)
    }

    private func commitPaint(
        _ image: NSImage,
        for screen: NSScreen,
        sourceName: String,
        style: CoverStyle,
        generation: Int
    ) {
        guard generation == applyGeneration else { return }
        guard let painted = paint(image, for: screen, style: style) else {
            log("paint failed")
            return
        }
        guard generation == applyGeneration else { return }

        let dest = nextPaintedURL(for: screen)
        do {
            var data = painted
            if let preview = NSImage(data: data), preview.size.width > screen.frame.width * 1.25 {
                if let fitted = jpegMatchingScreenPoints(data, screen: screen) {
                    data = fitted
                }
            }
            guard generation == applyGeneration else { return }
            try data.write(to: dest, options: .atomic)
            lastWritten[screen.displayID] = dest
            setManagedURL(dest, for: screen)
            try setWallpaper(dest, screen: screen)
            pruneOldFiles(keeping: dest, displayID: screen.displayID)
            lastFail.removeValue(forKey: screen.displayID)
            lastReassertAt[screen.displayID] = Date().timeIntervalSince1970
            lastPaintedStyle[screen.displayID] = style
            reassertStreak[screen.displayID] = 0
            if let signature = contentSignature(of: image) {
                lastContentSignature[screen.displayID] = signature
            }
            let points = NSImage(data: data)?.size ?? .zero
            log("applied \(dest.lastPathComponent) from \(sourceName) source=\(Int(image.size.width))x\(Int(image.size.height)) points=\(Int(points.width))x\(Int(points.height)) hide=\(style.hideNotch)")
        } catch {
            log("set wallpaper failed: \(error)")
        }
    }

    private func shouldReassert(_ current: URL, mark: String, screen: NSScreen) -> Bool {
        if isOriginalCopy(current) { return true }
        if let original = rememberedOriginal(for: screen), original.path == current.path { return true }
        if let saved = sourceMark(for: screen), saved == mark { return true }
        return false
    }

    /// Writing the wallpaper rewrites Index.plist, which wakes our own watcher. When a reassert
    /// does not stick, back off instead of spinning on that loop.
    @discardableResult
    private func reassert(_ url: URL, on screen: NSScreen, reason: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let now = Date().timeIntervalSince1970
        let elapsed = now - (lastReassertAt[screen.displayID] ?? 0)
        let streak = reassertStreak[screen.displayID] ?? 0
        if elapsed < min(15, Double(streak) * 3) { return false }
        reassertStreak[screen.displayID] = elapsed < 10 ? streak + 1 : 0
        do {
            try setWallpaper(url, screen: screen)
            lastReassertAt[screen.displayID] = now
            setManagedURL(url, for: screen)
            log("reassert \(url.lastPathComponent) (\(reason))")
            return true
        } catch {
            log("reassert failed: \(error)")
            return false
        }
    }

    private func paintedFile(for screen: NSScreen) -> URL? {
        if let url = lastWritten[screen.displayID], FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = UserDefaults.standard.url(forKey: managedKey(screen)),
           FileManager.default.fileExists(atPath: url.path),
           isManaged(url)
        {
            return url
        }
        let prefix = "wallpaper-\(screen.displayID)-"
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { isManaged($0) && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .first
    }

    private func nextPaintedURL(for screen: NSScreen) -> URL {
        let a = folder.appendingPathComponent("wallpaper-\(screen.displayID)-a.jpg")
        let b = folder.appendingPathComponent("wallpaper-\(screen.displayID)-b.jpg")
        if let current = lastWritten[screen.displayID] ?? UserDefaults.standard.url(forKey: managedKey(screen)),
           current.path == a.path
        {
            return b
        }
        return a
    }

    private func sourceMark(for screen: NSScreen) -> String? {
        lastFingerprint[screen.displayID] ?? UserDefaults.standard.string(forKey: sourceMarkKey(screen))
    }

    private func rememberSourceMark(_ mark: String, for screen: NSScreen) {
        lastFingerprint[screen.displayID] = mark
        UserDefaults.standard.set(mark, forKey: sourceMarkKey(screen))
    }

    private func loadImage(from url: URL) -> NSImage? {
        if let image = imageFromFile(url) { return image }
        activateFolderAccess()
        if let image = imageFromFile(url) { return image }
        if let folderURL = resolvedFolderURL() {
            let sibling = folderURL.appendingPathComponent(url.lastPathComponent)
            if let image = imageFromFile(sibling) {
                return image
            }
        }
        return nil
    }

    private func imageFromFile(_ url: URL) -> NSImage? {
        if isJunk(url) { return nil }
        if isDynamicContainer(url), let frame = currentHEICFrame(url) {
            return frame
        }
        if let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.size.width > 1 {
            return image
        }
        return NSImage(contentsOf: url)
    }

    private func captureDesktop(of screen: NSScreen, allowFlat: Bool = false) async -> NSImage? {
        if !CGPreflightScreenCaptureAccess() {
            _ = requestScreenAccess()
        }
        if CGPreflightScreenCaptureAccess(),
           let image = await captureWithScreenKit(of: screen, allowFlat: allowFlat)
        {
            return image
        }
        if let image = captureWallpaperWindow(of: screen, allowFlat: allowFlat) {
            return image
        }
        if !CGPreflightScreenCaptureAccess() {
            logOnce(0, "capture skipped, no screen access")
        }
        return nil
    }

    private func captureWithScreenKit(of screen: NSScreen, allowFlat: Bool) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) ?? content.displays.first else {
                return nil
            }

            let wallpaper = content.windows.first { $0.title == "Wallpaper" }
            let filter: SCContentFilter
            if let wallpaper {
                filter = SCContentFilter(desktopIndependentWindow: wallpaper)
            } else {
                let excluded = content.windows.filter { $0.title != "Wallpaper" }
                filter = SCContentFilter(display: display, excludingWindows: excluded)
            }

            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
            config.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
            config.scalesToFit = false
            if #available(macOS 14.2, *) {
                config.captureResolution = .best
            }

            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            if !allowFlat, isNearSolid(image) { return nil }
            log("captured desktop \(cg.width)x\(cg.height)")
            return image
        } catch {
            logOnce(screen.displayID, "capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func captureWallpaperWindow(of screen: NSScreen, allowFlat: Bool = false) -> NSImage? {
        guard let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in all {
            let name = info[kCGWindowName as String] as? String ?? ""
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            // WindowManager's backdrop is a flat gray during wallpaper transitions.
            guard name == "Wallpaper" else { continue }
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard width >= screen.frame.width * 0.8, height >= screen.frame.height * 0.8 else { continue }
            guard let cg = CGWindowListCreateImage(
                .null,
                [.optionIncludingWindow],
                wid,
                [.boundsIgnoreFraming, .bestResolution]
            ) else { continue }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            if !allowFlat, isNearSolid(image) { continue }
            log("captured wallpaper window \(cg.width)x\(cg.height) owner=\(owner)")
            return image
        }
        return nil
    }

    private func isDynamicContainer(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "heic" || ext == "heif"
    }

    private func currentHEICFrame(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let fraction = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400) / 86_400
        let index = min(count - 1, max(0, Int((fraction * Double(count)).rounded(.down))))
        guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func setWallpaper(_ url: URL, screen: NSScreen) throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .allowClipping: true,
            .imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
            .fillColor: NSColor.black
        ]
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    private func restore(_ screen: NSScreen) {
        activateFolderAccess()
        if let copy = originalCopy(for: screen),
           FileManager.default.fileExists(atPath: copy.path),
           !isJunk(copy),
           let image = loadImage(from: copy),
           !isNearSolid(image)
        {
            try? setWallpaper(copy, screen: screen)
        } else if let original = rememberedOriginal(for: screen),
                  FileManager.default.fileExists(atPath: original.path),
                  !isJunk(original),
                  !isSystemPlaceholder(original),
                  !isForeignPainted(original)
        {
            try? setWallpaper(original, screen: screen)
        }
        UserDefaults.standard.removeObject(forKey: managedKey(screen))
        UserDefaults.standard.removeObject(forKey: originalKey(screen))
        UserDefaults.standard.removeObject(forKey: sourceMarkKey(screen))
    }

    private func saveFolderBookmark(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Keys.folderBookmark)
            UserDefaults.standard.set(url.path, forKey: Keys.folderPath)
        } catch {
            UserDefaults.standard.set(url.path, forKey: Keys.folderPath)
            log("bookmark failed: \(error)")
        }
    }

    private func resolvedFolderURL() -> URL? {
        let candidates: [URL] = {
            var urls: [URL] = []
            if let data = UserDefaults.standard.data(forKey: Keys.folderBookmark) {
                var stale = false
                if let url = try? URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) {
                    if stale { saveFolderBookmark(url) }
                    urls.append(url)
                }
            }
            if let path = UserDefaults.standard.string(forKey: Keys.folderPath) {
                urls.append(URL(fileURLWithPath: path))
            }
            return urls
        }()

        for url in candidates where isUsableWallpaperFolder(url) {
            return url
        }
        return nil
    }

    private func isUsableWallpaperFolder(_ url: URL) -> Bool {
        let path = url.path
        if path.contains("/Application Support/Inkbar") { return false }
        if path.contains("/Application Support/Notchless") { return false }
        if path.contains("/inkbar-test") { return false }
        return true
    }

    private func clearFolderAccess() {
        UserDefaults.standard.removeObject(forKey: Keys.folderBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.folderPath)
        folderAccessStarted = false
    }

    private func activateFolderAccess() {
        guard let url = resolvedFolderURL() else { return }
        let ok = url.startAccessingSecurityScopedResource()
        if ok, !folderAccessStarted {
            log("folder access on \(url.path)")
        }
        folderAccessStarted = folderAccessStarted || ok
    }

    private func rememberOriginal(_ url: URL, for screen: NSScreen) {
        guard !isManaged(url), !isJunk(url), !isOriginalCopy(url),
              !isSystemPlaceholder(url), !isForeignPainted(url)
        else { return }
        UserDefaults.standard.set(url, forKey: originalKey(screen))
    }

    private func rememberedOriginal(for screen: NSScreen) -> URL? {
        UserDefaults.standard.url(forKey: originalKey(screen))
    }

    /// True when the image already carries a black menu-bar strip over normal content, which means
    /// it is a snapshot of our own paint and must not be kept as the wallpaper to restore.
    private func looksPainted(_ image: NSImage, screen: NSScreen) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
        let fraction = screen.menuBarOverlayHeight / max(screen.frame.height, 1)
        let barRows = Int((CGFloat(rep.pixelsHigh) * fraction).rounded())
        guard barRows >= 2, rep.pixelsHigh > barRows * 3 else { return false }

        func darkFraction(atRow row: Int) -> Double {
            var dark = 0
            var total = 0
            for x in stride(from: rep.pixelsWide / 20, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 20)) {
                guard let color = rep.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if color.brightnessComponent < 0.04 { dark += 1 }
            }
            guard total > 0 else { return 0 }
            return Double(dark) / Double(total)
        }

        return darkFraction(atRow: barRows / 2) > 0.97 && darkFraction(atRow: barRows * 2) < 0.7
    }

    /// Gray flash that macOS shows while the wallpaper picker commits. Real photos have much
    /// higher variance; a user-chosen solid color still comes from a real file, not a capture.
    private func isNearSolid(_ image: NSImage) -> Bool {
        guard let variance = brightnessVariance(of: image) else { return true }
        return variance < 0.008
    }

    private func brightnessVariance(of image: NSImage) -> Double? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let startY = max(0, Int(CGFloat(rep.pixelsHigh) * 0.1))
        let stepX = max(1, rep.pixelsWide / 40)
        let stepY = max(1, (rep.pixelsHigh - startY) / 24)
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        for y in stride(from: startY, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let brightness = Double(color.brightnessComponent)
                sum += brightness
                sumSquares += brightness * brightness
                count += 1
            }
        }
        guard count > 8 else { return nil }
        let mean = sum / Double(count)
        return max(0, sumSquares / Double(count) - mean * mean)
    }

    /// Newest wallpaper file recorded by WallpaperAgent, which is the user's pick even when
    /// NSWorkspace still reports DefaultDesktop.heic.
    private func currentIndexWallpaperURL() -> URL? {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        var bestDate = Date.distantPast
        var bestChoice: [String: Any]?

        func considerDesktop(_ desktop: [String: Any]) {
            let date = desktop["LastSet"] as? Date ?? .distantPast
            guard date >= bestDate else { return }
            guard let content = desktop["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]]
            else { return }
            for choice in choices {
                bestDate = date
                bestChoice = choice
            }
        }

        func walkSpace(_ node: Any) {
            guard let dict = node as? [String: Any] else { return }
            if let desktop = dict["Desktop"] as? [String: Any] {
                considerDesktop(desktop)
            }
            if let def = dict["Default"] {
                walkSpace(def)
            }
            if let displays = dict["Displays"] as? [String: Any] {
                for value in displays.values {
                    walkSpace(value)
                }
            }
        }

        if let spaces = root["Spaces"] as? [String: Any] {
            for value in spaces.values {
                walkSpace(value)
            }
        }
        if let displays = root["Displays"] as? [String: Any] {
            for value in displays.values {
                walkSpace(value)
            }
        }
        return bestChoice.flatMap(urlFromChoice)
    }

    private func urlFromChoice(_ choice: [String: Any]) -> URL? {
        if let files = choice["Files"] as? [[String: Any]] {
            for file in files {
                if let url = urlFromValue(file["relative"] ?? file["url"]) {
                    return url
                }
            }
        }
        guard let config = choice["Configuration"] as? Data,
              let inner = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any]
        else { return nil }
        if let url = inner["url"] as? [String: Any] {
            return urlFromValue(url["relative"] ?? url["url"])
        }
        return urlFromValue(inner["relative"] ?? inner["url"])
    }

    private func urlFromValue(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        if raw.hasPrefix("file:"), let url = URL(string: raw) { return url }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return URL(string: raw)
    }

    private func saveOriginalImage(_ image: NSImage, displayID: CGDirectDisplayID) {
        let dest = originals.appendingPathComponent("\(displayID)-latest.jpg")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        else { return }
        try? data.write(to: dest, options: .atomic)
        UserDefaults.standard.set(dest, forKey: originalCopyKey(displayID))
    }

    private func originalCopy(for screen: NSScreen) -> URL? {
        UserDefaults.standard.url(forKey: originalCopyKey(screen.displayID))
    }

    private func paint(_ source: NSImage, for screen: NSScreen, style: CoverStyle) -> Data? {
        let scale = screen.backingScaleFactor
        let pxW = max(1, Int((screen.frame.width * scale).rounded()))
        let pxH = max(1, Int((screen.frame.height * scale).rounded()))
        let bar = screen.menuBarOverlayHeight * scale
        let bounds = CGRect(x: 0, y: 0, width: pxW, height: pxH)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: pxW,
                height: pxH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(bounds)

        var proposed = NSRect(origin: .zero, size: source.size)
        if let cg = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            let iw = CGFloat(cg.width)
            let ih = CGFloat(cg.height)
            if iw > 0, ih > 0 {
                let fill = max(CGFloat(pxW) / iw, CGFloat(pxH) / ih)
                let dw = iw * fill
                let dh = ih * fill
                let dx = (CGFloat(pxW) - dw) / 2
                let dy = (CGFloat(pxH) - dh) / 2
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: dx, y: dy, width: dw, height: dh))
            }
        }

        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        if style.hideNotch {
            ctx.fill(CGRect(x: 0, y: CGFloat(pxH) - bar, width: CGFloat(pxW), height: bar))
        }

        guard let out = ctx.makeImage() else { return nil }
        return jpegData(from: out, scale: scale)
    }

    private func jpegData(from image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72 * scale
        let jfif: [CFString: Any] = [
            kCGImagePropertyJFIFVersion: [1, 2],
            kCGImagePropertyJFIFDensityUnit: 1,
            kCGImagePropertyJFIFXDensity: dpi,
            kCGImagePropertyJFIFYDensity: dpi
        ]
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyJFIFDictionary: jfif,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// macOS 27 wallpaper uses scaleNone. A 2x JPEG at 72 DPI is twice the screen in points, so
    /// only the top-left quadrant shows.
    private func jpegMatchingScreenPoints(_ data: Data, screen: NSScreen) -> Data? {
        guard let source = NSImage(data: data) else { return nil }
        let size = screen.frame.size
        let pxW = max(1, Int(size.width.rounded()))
        let pxH = max(1, Int(size.height.rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: pxW,
                height: pxH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        var proposed = NSRect(origin: .zero, size: source.size)
        if let cg = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
        }
        guard let out = ctx.makeImage() else { return nil }
        return jpegData(from: out, scale: 1)
    }

    /// Coarse greyscale thumbnail of everything below the menu bar, used to tell whether the
    /// wallpaper on screen is still the one we painted.
    private func contentSignature(of image: NSImage) -> [UInt8]? {
        let width = 16
        let height = 12
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              cg.width > 0, cg.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }

        let iw = CGFloat(cg.width)
        let ih = CGFloat(cg.height)
        let fill = max(CGFloat(width) / iw, CGFloat(height) / ih)
        let dw = iw * fill
        let dh = ih * fill
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: (CGFloat(width) - dw) / 2, y: (CGFloat(height) - dh) / 2, width: dw, height: dh))

        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        // Row 0 holds the menu bar strip, which is black in our output but not in a raw source.
        return (width..<(width * height)).map { pixels[$0] }
    }

    private func signaturesMatch(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        var total = 0
        for index in lhs.indices {
            total += abs(Int(lhs[index]) - Int(rhs[index]))
        }
        return total / lhs.count <= 10
    }

    private func fingerprint(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(modified)"
    }

    private func pruneOldFiles(keeping newest: URL, displayID: CGDirectDisplayID) {
        let prefix = "wallpaper-\(displayID)-"
        let keep: Set<String> = [
            newest.lastPathComponent,
            "wallpaper-\(displayID)-a.jpg",
            "wallpaper-\(displayID)-b.jpg"
        ]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "jpg" && url.lastPathComponent.hasPrefix(prefix) {
            if !keep.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func purgeJunk() {
        let files = (try? FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)) ?? []
        for url in files where isJunk(url) {
            try? FileManager.default.removeItem(at: url)
        }
        let painted = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in painted where isJunk(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isAppSupportFile(_ url: URL) -> Bool {
        url.path.contains("/Application Support/Inkbar/")
            || url.path.contains("/Application Support/Notchless/")
    }

    private func isManaged(_ url: URL) -> Bool {
        isAppSupportFile(url)
            && url.lastPathComponent.range(of: #"^wallpaper-\d+-(a|b|\d+)\.jpg$"#, options: .regularExpression) != nil
    }

    private func isOriginalCopy(_ url: URL) -> Bool {
        url.path.contains("/Application Support/Inkbar/originals/")
            || url.path.contains("/Application Support/Notchless/originals/")
    }

    private func isJunk(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.contains("inkbar-test")
            || name == "wallpaper-restored.jpg"
            || url.path.contains("/private/tmp/inkbar")
    }

    /// Another notch hider already burned a black strip into these files, so they must never
    /// become the wallpaper we restore to.
    private func isForeignPainted(_ url: URL) -> Bool {
        url.path.contains("/Application Support/TopNotch/")
    }

    /// macOS flashes this file while the wallpaper picker settles. It is not the user's choice.
    private func isSystemPlaceholder(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("defaultdesktop.") { return true }
        if name == "wallpaper-restored.jpg" { return true }
        return url.path.contains("/System/Library/CoreServices/DefaultDesktop")
    }

    private func dropPlaceholderOriginals() {
        for screen in NSScreen.screens {
            if let copy = originalCopy(for: screen),
               let image = loadImage(from: copy),
               isNearSolid(image)
            {
                try? FileManager.default.removeItem(at: copy)
                UserDefaults.standard.removeObject(forKey: originalCopyKey(screen.displayID))
                log("dropped blank original \(copy.lastPathComponent)")
            }
            guard let original = rememberedOriginal(for: screen),
                  isSystemPlaceholder(original) || isForeignPainted(original)
            else { continue }
            UserDefaults.standard.removeObject(forKey: originalKey(screen))
            UserDefaults.standard.removeObject(forKey: sourceMarkKey(screen))
            if let copy = originalCopy(for: screen) {
                try? FileManager.default.removeItem(at: copy)
                UserDefaults.standard.removeObject(forKey: originalCopyKey(screen.displayID))
            }
            log("dropped placeholder original \(original.lastPathComponent)")
        }
    }

    private func originalKey(_ screen: NSScreen) -> String {
        "inkbar.originalWallpaper.\(screen.displayID)"
    }

    private func originalCopyKey(_ displayID: CGDirectDisplayID) -> String {
        "inkbar.originalCopy.\(displayID)"
    }

    private func managedKey(_ screen: NSScreen) -> String {
        "inkbar.managedWallpaper.\(screen.displayID)"
    }

    private func sourceMarkKey(_ screen: NSScreen) -> String {
        "inkbar.paintedSource.\(screen.displayID)"
    }

    private func setManagedURL(_ url: URL?, for screen: NSScreen) {
        UserDefaults.standard.set(url, forKey: managedKey(screen))
    }

    private func logOnce(_ displayID: CGDirectDisplayID, _ message: String) {
        let now = Date().timeIntervalSince1970
        if let last = lastFailureLog[displayID], now - last < 30 { return }
        lastFailureLog[displayID] = now
        log(message)
    }

    private func log(_ message: String) {
        NSLog("Inkbar: %@", message)
        let line = "\(Date()): \(message)\n"
        let url = folder.appendingPathComponent("debug.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    private static func migrateSupportFolder(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
            return
        }
        try? fm.createDirectory(
            at: new.appendingPathComponent("originals", isDirectory: true),
            withIntermediateDirectories: true
        )
        let items = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items {
            let dest = new.appendingPathComponent(item.lastPathComponent)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let nested = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for file in nested {
                    let nestedDest = dest.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: nestedDest.path) {
                        try? fm.moveItem(at: file, to: nestedDest)
                    }
                }
            } else if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: item, to: dest)
            }
        }
        try? fm.removeItem(at: old)
    }

    private static func rewriteStoredPaths(replacing old: String, with new: String) {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("inkbar.") {
            if let url = value as? URL, url.path.contains(old) {
                defaults.set(URL(fileURLWithPath: url.path.replacingOccurrences(of: old, with: new)), forKey: key)
            } else if let path = value as? String, path.contains(old) {
                defaults.set(path.replacingOccurrences(of: old, with: new), forKey: key)
            }
        }
    }

    private enum Keys {
        static let folderBookmark = "inkbar.wallpaperFolderBookmark"
        static let folderPath = "inkbar.wallpaperFolderPath"
    }
}
