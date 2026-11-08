import SwiftUI

struct ClipView: View {
    @ObservedObject var watcher: ClipboardWatcher
    @ObservedObject var state: WidgetState
    let toggleHistory: () -> Void
    let openPrivacySettings: () -> Void

    /// A history row waiting for its confirming second click.
    @State private var armedEntryID: UUID?

    static let sidebarWidth: CGFloat = 140

    var body: some View {
        HStack(spacing: 0) {
            if state.showHistory {
                historyColumn
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
            }
            mainColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(windowBackground)
        .contentShape(Rectangle())
        // The whole window is the handle: on macOS 27 an NSHostingView no
        // longer offers its background for isMovableByWindowBackground.
        .gesture(WindowDragGesture())
    }

    private var windowBackground: some View {
        ZStack {
            // All but invisible, and there for the mouse: clicks on fully
            // transparent pixels fall through the window, and the rounded
            // corners are exactly where you grab to resize.
            Color.black.opacity(0.001)
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(white: 0.12, opacity: 0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            Group {
                // The wait replaces the previous clipboard rather than sitting
                // on top of it, so the old one can't be mistaken for the new.
                // Only once it is slow enough to see, though: a local copy
                // lands in milliseconds and should not flash a spinner.
                if let since = watcher.pendingSince {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        let elapsed = context.date.timeIntervalSince(since)
                        if elapsed > 0.15 { receivingView(elapsed: elapsed) } else { contentView }
                    }
                } else {
                    contentView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if watcher.access == .ask {
                askBanner
            } else if watcher.pendingSince == nil, let footer = footerText {
                // Hidden while receiving: the type list is already the new
                // clipboard's, the content still the old one's.
                Text(verbatim: footer)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(watcher.types.joined(separator: "\n"))
            }
        }
        .padding(EdgeInsets(top: 7, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - History

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sidebarToggle
                Text("history")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                Spacer(minLength: 0)
            }
            .frame(height: 16)

            if watcher.history.isEmpty {
                Text("nothing yet")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(watcher.history) { entry in
                            historyRow(entry, isCurrent: entry.id == watcher.currentEntryID)
                        }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 9, trailing: 8))
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func historyRow(_ entry: ClipEntry, isCurrent: Bool) -> some View {
        let isArmed = armedEntryID == entry.id
        // Not .disabled for the current one: that greys it out, and "now"
        // would read as "unavailable". A click on it just does nothing.
        return Button { historyClicked(entry, isCurrent: isCurrent) } label: {
            HStack(spacing: 6) {
                historyThumb(entry)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: isArmed ? "replace?" : entry.title)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(isArmed ? .orange : .white.opacity(isCurrent ? 0.9 : 0.7))
                        .lineLimit(1)
                        // File names keep their extension; text keeps its start.
                        .truncationMode(entry.fileURL != nil ? .middle : .tail)
                    HStack(spacing: 3) {
                        if isArmed {
                            Text("click again")
                        } else {
                            // Seconds: a burst of copies lands in one minute.
                            Text(Self.clock.string(from: entry.date))
                            if entry.isRemote { Image(systemName: "ipad.and.iphone") }
                        }
                    }
                    .lineLimit(1)
                    // Green and highlighted is the one on the clipboard now;
                    // a "now" label didn't fit beside seconds and the phone icon.
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(isArmed ? .orange.opacity(0.8)
                                     : isCurrent ? Self.green.opacity(0.8) : .white.opacity(0.35))
                }
                Spacer(minLength: 0)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(isArmed ? Color.orange.opacity(0.12)
                      : isCurrent ? Color.white.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(entry.title)\n\(historyHint(isCurrent: isCurrent))")
    }

    /// One click puts an entry back — unless what it would replace isn't in
    /// history itself (a password, a type history can't hold, something
    /// still arriving). Then the first click arms the row and only a second
    /// one replaces; left alone, the row disarms after a few seconds.
    private func historyClicked(_ entry: ClipEntry, isCurrent: Bool) {
        guard !isCurrent else { return }
        if watcher.currentIsKept || armedEntryID == entry.id {
            armedEntryID = nil
            watcher.restore(entry)
            return
        }
        armedEntryID = entry.id
        let id = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if armedEntryID == id { armedEntryID = nil }
        }
    }

    private func historyHint(isCurrent: Bool) -> String {
        if isCurrent { return "on the clipboard now" }
        if watcher.currentIsKept { return "click to put it back on the clipboard" }
        return "what's on the clipboard now isn't kept in history — click twice to replace it"
    }

    @ViewBuilder
    private func historyThumb(_ entry: ClipEntry) -> some View {
        if let thumbnail = entry.thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let url = entry.fileURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            ZStack {
                Color.white.opacity(0.06)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    private var sidebarToggle: some View {
        Button(action: toggleHistory) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(state.showHistory ? 0.6 : 0.35))
        }
        .buttonStyle(.plain)
        .help(state.showHistory ? "Hide history" : "Show history")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            if !state.showHistory { sidebarToggle }
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(kindLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
            if watcher.isRemote {
                Image(systemName: "ipad.and.iphone")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer(minLength: 4)
            if let changedAt = watcher.changedAt {
                Text(Self.clock.string(from: changedAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(height: 16)
    }

    private var kindLabel: String {
        if watcher.pendingSince != nil { return watcher.isRemote ? "receiving" : "reading" }
        switch watcher.content {
        case .empty:            return "empty"
        case .image(let image): return image.fileName == nil ? "image" : "image file"
        case .text:             return "text"
        case .files(let files): return files.count == 1 ? "file" : "\(files.count) files"
        case .concealed:        return "concealed"
        case .other:            return "other"
        case .unreadable:       return "no data"
        }
    }

    private var dotColor: Color {
        if watcher.pendingSince != nil { return .yellow }
        switch watcher.content {
        case .empty:      return .white.opacity(0.25)
        case .unreadable: return .orange
        default:          return Self.green
        }
    }

    private static let green = Color(red: 0x1D / 255, green: 0xB9 / 255, blue: 0x54 / 255)

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch watcher.content {
        case .empty:
            placeholder("clipboard is empty", systemImage: "clipboard")
        case .image(let image):
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text):
            // Not a viewer: the head of the text, cut with an ellipsis where
            // the window ends.
            Text(verbatim: text.preview.isEmpty ? "(empty string)" : text.preview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(text.preview.isEmpty ? 0.4 : 0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .files(let files):
            filesView(files)
        case .concealed:
            placeholder("marked secret by its sender\n(password manager) — not shown", systemImage: "lock.fill")
        case .other:
            typesView
        case .unreadable:
            unreadableView
        }
    }

    private func filesView(_ files: [ClipFile]) -> some View {
        let shown = 8
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(files.prefix(shown)) { file in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(verbatim: file.name)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let size = file.byteCount, !file.isDirectory {
                        Text(Self.bytes(size)).foregroundColor(.white.opacity(0.35))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
            if files.count > shown {
                Text("+ \(files.count - shown) more")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    /// For anything we can't draw: what Pasteboard Viewer's sidebar would
    /// show, without the sidebar.
    private var typesView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(watcher.types, id: \.self) { type in
                Text(verbatim: type)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var unreadableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .foregroundColor(.orange.opacity(0.7))
            Text(watcher.access == .alwaysDeny
                 ? "clipboard access is denied"
                 : "the data didn't come through")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            if watcher.access == .alwaysDeny {
                Button("Privacy Settings", action: openPrivacySettings)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func receivingView(elapsed: TimeInterval) -> some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(watcher.isRemote ? "receiving from iPhone / iPad" : "reading")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            Text(String(format: "%.1f s", elapsed))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.yellow.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.25))
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// With "Ask", macOS puts up a dialog on every read — on a monitor, that
    /// is every time anything is copied.
    private var askBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9))
                .foregroundColor(.yellow.opacity(0.7))
            Text("macOS asks on every copy")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.yellow.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Always Allow…", action: openPrivacySettings)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.yellow)
        }
    }

    // MARK: - Footer

    private var footerText: String? {
        var parts: [String] = []
        switch watcher.content {
        case .image(let image):
            if let name = image.fileName { parts.append(name) }
            parts.append(image.format)
            parts.append("\(image.pixelWidth)×\(image.pixelHeight)")
            if let bytes = image.byteCount { parts.append(Self.bytes(bytes)) }
        case .text(let text):
            parts.append("\(text.characterCount) chars")
            if text.lineCount > 1 { parts.append("\(text.lineCount) lines") }
        case .files(let files):
            let total = files.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.byteCount ?? 0) }
            if total > 0 { parts.append(Self.bytes(total)) }
        case .other:
            parts.append(watcher.types.count == 1 ? "1 type" : "\(watcher.types.count) types")
        default:
            break
        }
        // Several items (several photos shared at once) — we show the first.
        if case .files = watcher.content {} else if watcher.itemCount > 1 {
            parts.append("1 of \(watcher.itemCount)")
        }
        if let wait = watcher.lastWait, watcher.isRemote || wait > 0.3 {
            parts.append(String(format: "⇣ %.1f s", wait))
        }
        if watcher.isRestored {
            parts.append("restored")
        } else if let source = watcher.sourceName {
            parts.append(source)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Formatting

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()


    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
