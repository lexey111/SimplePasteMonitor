import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

// MARK: - What the widget can show

/// A picture off the pasteboard, already scaled down for display.
nonisolated struct ClipImage: @unchecked Sendable {   // CGImage is immutable
    let cgImage: CGImage
    /// Full size of the original, not of the scaled-down copy we draw.
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64?
    /// "HEIC", "PNG" — the representation we actually decoded.
    let format: String
    /// Set when the picture came from a copied file rather than image data.
    let fileName: String?
}

nonisolated struct ClipText: Sendable {
    /// The head of the text — more than any window will show, far less than
    /// a pasted log file can be.
    let preview: String
    let characterCount: Int
    let lineCount: Int
}

nonisolated struct ClipFile: Sendable, Identifiable {
    let url: URL
    let byteCount: Int64?
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

nonisolated enum ClipContent: Sendable {
    case empty
    case image(ClipImage)
    case text(ClipText)
    case files([ClipFile])
    /// Marked secret by its sender — password managers do this. Never read.
    case concealed
    /// Nothing we know how to draw; the type list is all there is to show.
    case other
    /// Types are on the pasteboard but the data didn't come: access was
    /// refused, or the sending device gave up.
    case unreadable

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

// MARK: - Reading

/// Turns a pasteboard into `ClipContent`. Everything here runs off the main
/// thread, because reading can block for seconds: with Universal Clipboard the
/// Mac is first told only *which types* the phone has, and the bytes travel
/// when somebody asks for them. That somebody is us — so this wait is the
/// "has it arrived yet" the widget exists to show.
nonisolated enum ClipLoader {
    static let remoteMarker = "com.apple.is-remote-clipboard"
    /// nspasteboard.org conventions, honoured by password managers and
    /// clipboard tools.
    static let concealedMarker = "org.nspasteboard.ConcealedType"
    static let sourceMarker = "org.nspasteboard.source"

    enum Plan: Sendable {
        /// Decided from the type list alone; no data needs to be read.
        case done(ClipContent)
        case image(type: String)
        case text
        case files
    }

    private static let textTypes: Set<String> = [
        "public.utf8-plain-text", "public.utf16-plain-text", "public.plain-text",
        "public.utf16-external-plain-text", "NSStringPboardType",
        "public.rtf", "public.html", "public.url",
    ]

    static func plan(for types: [String]) -> Plan {
        if types.isEmpty { return .done(.empty) }
        if types.contains(concealedMarker) { return .done(.concealed) }
        // Finder puts the file's icon on the pasteboard as an image too; the
        // file is what was copied.
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return .files }

        // The sender lists its richest representation first, so the first
        // type we recognise decides: a phone screenshot leads with images,
        // while text from an office suite is still text even though it also
        // ships a PNG of itself further down the list.
        let decodable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        for type in types {
            if decodable.contains(type) { return .image(type: type) }
            if textTypes.contains(type) { return .text }
        }
        return .done(.other)
    }

    /// Bundle id of the app that says it put this here.
    static func source(from name: NSPasteboard.Name) -> String? {
        NSPasteboard(name: name).string(forType: NSPasteboard.PasteboardType(sourceMarker))
    }

    static func load(_ plan: Plan, from name: NSPasteboard.Name) -> ClipContent {
        let pasteboard = NSPasteboard(name: name)
        switch plan {
        case .done(let content): return content
        case .image(let type):   return image(type: type, from: pasteboard)
        case .text:              return text(from: pasteboard)
        case .files:             return files(from: pasteboard)
        }
    }

    // Only the one representation we are going to draw is read. Asking for
    // every type would make the sender render all of them — a pasteboard
    // full of promises can be expensive to cash.
    private static func image(type: String, from pasteboard: NSPasteboard) -> ClipContent {
        guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) else {
            return .unreadable
        }
        guard let image = decode(CGImageSourceCreateWithData(data as CFData, nil),
                                 byteCount: Int64(data.count),
                                 format: label(for: type),
                                 fileName: nil)
        else { return .other }
        return .image(image)
    }

    private static func text(from pasteboard: NSPasteboard) -> ClipContent {
        var string = pasteboard.string(forType: .string)
        if string == nil, let rtf = pasteboard.data(forType: .rtf) {
            string = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
        }
        if string == nil { string = pasteboard.string(forType: .URL) }
        guard let string else { return .unreadable }

        var lines = string.isEmpty ? 0 : 1
        for byte in string.utf8 where byte == 0x0A { lines += 1 }
        if string.hasSuffix("\n") { lines -= 1 }
        return .text(ClipText(preview: String(string.prefix(4000)),
                              characterCount: string.count,
                              lineCount: lines))
    }

    private static func files(from pasteboard: NSPasteboard) -> ClipContent {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return .unreadable }

        // One image file: show the picture, it's what you'd want to check.
        if urls.count == 1, let url = urls.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let image = decode(CGImageSourceCreateWithURL(url as CFURL, nil),
                              byteCount: fileSize(url),
                              format: label(for: type.identifier),
                              fileName: url.lastPathComponent) {
            return .image(image)
        }
        return .files(urls.map { url in
            // Resolved first: a symlink reports its own size (Safari.app in
            // /Applications is one, into the system cryptex — "54 bytes").
            let values = try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            return ClipFile(url: url,
                            byteCount: values?.fileSize.map(Int64.init),
                            isDirectory: values?.isDirectory ?? false)
        })
    }

    private static func decode(_ source: CGImageSource?, byteCount: Int64?,
                               format: String, fileName: String?) -> ClipImage? {
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // EXIF orientations 5–8 are a quarter turn: stored width is shown height.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int,
           (5...8).contains(orientation) {
            swap(&width, &height)
        }
        // Decoded at display size, not full size: a phone screenshot is
        // 3–4 MP, and a full decode of each one would be wasted on a widget.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return ClipImage(cgImage: cgImage, pixelWidth: width, pixelHeight: height,
                         byteCount: byteCount, format: format, fileName: fileName)
    }

    private static func label(for type: String) -> String {
        UTType(type)?.preferredFilenameExtension?.uppercased() ?? type
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
}

// MARK: - Watching

/// Polls the pasteboard and publishes what is on it.
///
/// Polling is the only way: macOS posts no notification when the pasteboard
/// changes. `changeCount` is a cheap integer read, so four times a second
/// costs nothing and keeps the delay below what anyone would notice.
@MainActor
final class ClipboardWatcher: ObservableObject {
    @Published private(set) var content: ClipContent = .empty
    @Published private(set) var types: [String] = []
    @Published private(set) var itemCount = 0
    /// Came over Universal Clipboard from an iPhone or iPad.
    @Published private(set) var isRemote = false
    /// The app that put it there, when it says so (nspasteboard.org marker).
    @Published private(set) var sourceName: String?
    @Published private(set) var changedAt: Date?
    /// Set while the data for the latest change is still being read.
    @Published private(set) var pendingSince: Date?
    /// How long the data took to become readable, once it has.
    @Published private(set) var lastWait: TimeInterval?
    @Published private(set) var access: NSPasteboard.AccessBehavior = .default

    /// Called when a new clipboard is ready to look at — after the data
    /// arrived, not when it was announced, so a sound means "it's here".
    var onArrival: (() -> Void)?

    let pasteboard: NSPasteboard
    private var seenChangeCount = -1
    /// Bumped by every refresh; a read that finishes under an older one is
    /// stale. Not the change count: a late-types refresh keeps that.
    private var generation = 0
    /// Until when the type list is re-checked at an unchanged change count.
    private var settleUntil = Date.distantPast
    private var timer: Timer?
    private var ticks = 0

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func start() {
        refresh(announce: false)   // what was already there is not news
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common, so the widget keeps updating while a menu is open or a
        // window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        ticks += 1
        if ticks % 8 == 0 { checkAccess() }
        if pasteboard.changeCount != seenChangeCount {
            refresh(announce: true)
            return
        }
        // Writers clear first and write after, and only the clearing counts
        // as a change: clearContents() bumps changeCount, writeObjects() does
        // not. A poll landing between the two sees an empty pasteboard under
        // the new count and, going by the count alone, would show "empty"
        // until the next copy. So for a moment after each change, the type
        // list itself is compared too.
        if Date() < settleUntil, (pasteboard.types?.map(\.rawValue) ?? []) != types {
            refresh(announce: true)
        }
    }

    /// The user can flip the permission in System Settings at any time; when
    /// it starts allowing what it refused, read again rather than make them
    /// copy something new to find out.
    private func checkAccess() {
        let now = pasteboard.accessBehavior
        guard now != access else { return }
        access = now
        if case .unreadable = content, now == .alwaysAllow {
            refresh(announce: false)
        }
    }

    private func refresh(announce: Bool) {
        seenChangeCount = pasteboard.changeCount
        generation += 1
        let generation = generation
        settleUntil = Date().addingTimeInterval(1.5)
        access = pasteboard.accessBehavior

        // Type lists are metadata and stay on the main thread. Anything that
        // reads data — even the few bytes of the source marker — goes to the
        // background: it can wait on a phone, or on a privacy prompt.
        let types = pasteboard.types?.map(\.rawValue) ?? []
        self.types = types
        itemCount = pasteboard.pasteboardItems?.count ?? 0
        isRemote = types.contains(ClipLoader.remoteMarker)
        changedAt = Date()
        lastWait = nil

        let plan = ClipLoader.plan(for: types)
        let wantsSource = types.contains(ClipLoader.sourceMarker)
        let started = Date()
        pendingSince = started
        let name = pasteboard.name
        Task {
            let (content, source) = await Task.detached(priority: .userInitiated) {
                (ClipLoader.load(plan, from: name),
                 wantsSource ? ClipLoader.source(from: name) : nil)
            }.value
            // A newer refresh may have started while this one was in flight;
            // it owns the widget now.
            guard self.generation == generation else { return }
            self.content = content
            self.sourceName = self.appName(source)
            self.pendingSince = nil
            self.lastWait = Date().timeIntervalSince(started)
            // An emptied clipboard is not an arrival — and it is also the
            // first half of every ordinary copy, which would beep twice.
            if announce, !content.isEmpty { self.onArrival?() }
        }
    }

    private func appName(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
