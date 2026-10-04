import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Resolves and caches process icons from executable paths. `NSWorkspace`
/// already caches icon images internally, but this avoids repeated lookups on
/// every menubar refresh and keeps a generic fallback for path-less processes.
///
/// The cache is bounded (`NSCache`, count-limited and pressure-evicted) so that
/// rendering the full process list — which can touch hundreds of distinct
/// executables — does not leave hundreds of `NSImage`s macperfmonitor once the window
/// is closed and the app returns to its menubar-only idle state.
@MainActor
final class ProcessIconProvider {
    static let shared = ProcessIconProvider()

    private let cache = NSCache<NSString, NSImage>()
    private let rowCache = NSCache<NSString, NSImage>()
    /// Generic executable icon for processes with no usable path. Deliberately
    /// NOT this app's own icon (`NSImage.applicationIconName`), which made every
    /// path-less or exited-and-deleted process masquerade as this app.
    private let fallback = NSWorkspace.shared.icon(for: .unixExecutable)

    init() {
        cache.countLimit = 256
        rowCache.countLimit = 256
    }

    /// The icon pre-rendered as 16 pt bitmaps (1x and 2x), for the Processes
    /// table's rows. A workspace icon is an IconServices image that renders
    /// lazily, so every newly created `NSImageView` asked IconServices for a
    /// placeholder first, about a tenth of the main-thread time spent opening
    /// the Processes tab. A plain bitmap draws immediately, and is rendered
    /// once per executable rather than once per row view.
    func rowIcon(forPath path: String?) -> NSImage {
        let key = (path ?? "") as NSString
        if let cached = rowCache.object(forKey: key) { return cached }
        let source = icon(forPath: path)
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return source }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        rowCache.setObject(image, forKey: key)
        return image
    }

    func icon(forPath path: String?) -> NSImage {
        guard let path, !path.isEmpty else { return fallback }
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = resolveIcon(forExecutablePath: path)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Resolve the best icon for a process's executable path. When the
    /// executable lives inside an application bundle, the bundle's icon (the
    /// recognisable app icon, e.g. Safari's) is used rather than the generic
    /// Unix-executable icon that `icon(forFile:)` returns for the inner Mach-O
    /// at `\u{2026}/Contents/MacOS/Safari`. Bare executables and daemons fall back to
    /// whatever generic icon the workspace provides for the file itself.
    private func resolveIcon(forExecutablePath path: String) -> NSImage {
        if let bundlePath = enclosingAppBundlePath(path),
            FileManager.default.fileExists(atPath: bundlePath)
        {
            return NSWorkspace.shared.icon(forFile: bundlePath)
        }
        // An exited process's binary can be gone entirely (uninstalled app,
        // temporary tool); asking the workspace for a missing file yields a
        // blank-document icon, so prefer the honest generic-executable one.
        guard FileManager.default.fileExists(atPath: path) else { return fallback }
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// The path of the outermost `.app` bundle enclosing `path`, or nil when the
    /// executable is not inside one. The outermost bundle is chosen so a process
    /// buried in a helper sub-app (for example a browser's renderer helper at
    /// `Chrome.app/\u{2026}/Chrome Helper.app/\u{2026}`) still shows the recognisable parent
    /// application's icon rather than a blank helper icon.
    private func enclosingAppBundlePath(_ path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components[0...index]))
    }

    /// Drops all cached icons. Called when the main window closes so the icons
    /// pulled in to render the process list do not linger while the app sits
    /// idle in the menubar.
    func purge() {
        cache.removeAllObjects()
        rowCache.removeAllObjects()
    }
}
