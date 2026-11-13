import Darwin
import Foundation

public struct NoteInfo: Equatable {
    public let name: String
    public let modified: Date
}

public enum NoteStoreError: Error, Equatable {
    case invalidName
    case exists
}

/// Whether the open note's text is on disk, for the icon beside the title.
public enum SaveState {
    case saved
    /// Typed but not written yet; a save is on its way.
    case editing
    /// The last write failed; the next edit or flush tries again.
    case failed
}

/// Notes are the `.md` files directly inside `folder`, and a file's name is its note's name.
///
/// Losing text is the worst failure, so text only ever moves forward:
/// - Writes are atomic, and a failed write keeps the text unsaved, to be tried again.
/// - A file changed elsewhere since it was read is never overwritten; the text goes to a
///   conflict copy instead.
/// - Before a note's file is overwritten, its current contents are copied to `backups`, at most
///   once per `backupInterval` per note. Backups older than 30 days are deleted on launch.
/// - Renames never replace another file, and deleted notes go to the Trash.
///
/// Everything runs on the main thread: the files are small, and one thread keeps saving simple.
public final class NoteStore {
    public private(set) var folder: URL
    public let backups: URL?
    public private(set) var current: String?
    public private(set) var text = ""
    public var saveDelay: TimeInterval = 0.3
    public var backupInterval: TimeInterval = 10 * 60
    /// A message for the footer, or nil to clear it.
    public var onStatus: (String?) -> Void = { _ in }
    /// A note has a new name: the user renamed it, it followed its first line, or its text was
    /// saved to a conflict copy, which is the open note from then on.
    public var onRenamed: (_ from: String, _ to: String) -> Void = { _, _ in }
    public var onSaveState: (SaveState) -> Void = { _ in }
    public private(set) var saveState = SaveState.saved {
        didSet { if saveState != oldValue { onSaveState(saveState) } }
    }

    private struct Stamp: Equatable {
        let date: Date
        let size: Int
    }

    private var dirty: Bool { saveState != .saved }
    private var stamp: Stamp?
    /// The open note's text as last read from or written to its file.
    private var savedText = ""
    private var pending: DispatchWorkItem?
    private var statusShown = false
    private var lastBackup: [String: Date] = [:]

    public init(folder: URL, backups: URL? = nil) {
        self.folder = folder
        self.backups = backups
        pruneBackups()
    }

    /// True while the open note has text that isn't on disk, such as after a failed write.
    public var hasUnsavedChanges: Bool { dirty }

    public func url(_ name: String) -> URL {
        folder.appendingPathComponent(name + ".md", isDirectory: false)
    }

    /// Newest first. Subfolders, hidden files and links are not notes.
    public func list() -> [NoteInfo] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> NoteInfo? in
            guard url.pathExtension == "md",
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true, values.isSymbolicLink != true
            else { return nil }
            return NoteInfo(
                name: url.deletingPathExtension().lastPathComponent,
                modified: values.contentModificationDate ?? .distantPast)
        }
        .sorted { ($0.modified, $1.name) > ($1.modified, $0.name) }
    }

    public func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the open note, then opens `name`. Returns nil, and keeps the open note, if `name`
    /// isn't readable UTF-8 text.
    @discardableResult
    public func open(_ name: String) -> String? {
        flush()
        guard let content = read(name) else {
            report("Couldn’t open “\(name)”: it isn’t UTF-8 text, or it can’t be read.")
            return nil
        }
        current = name
        text = content
        savedText = content
        saveState = .saved
        stamp = fileStamp(name)
        return content
    }

    public func edit(_ newText: String) {
        guard current != nil, newText != text else { return }
        text = newText
        saveState = .editing
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Writes unsaved text now, then renames the file to follow the first line if it should.
    public func flush() {
        pending?.cancel()
        pending = nil
        guard dirty, let name = current else { return }
        var target = name
        if let known = stamp, let now = fileStamp(name), now != known {
            target = makeUniqueName(conflictName(name, date: Date())) { exists($0) }
        } else {
            backUp(name)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(target), options: .atomic)
        } catch {
            // Still dirty, so the next edit or flush tries again.
            saveState = .failed
            report("Couldn’t save: \(error.localizedDescription)")
            return
        }
        let follows = followsFirstLine(name: name, savedText: savedText)
        saveState = .saved
        savedText = text
        stamp = fileStamp(target)
        if target != name {
            current = target
            onRenamed(name, target)
            report("“\(name)” was changed in another app, so your text was saved as “\(target)”.")
            return
        }
        if statusShown {
            statusShown = false
            onStatus(nil)
        }
        if follows { renameToFirstLine(name) }
    }

    /// Picks up edits made elsewhere, unless this note has unsaved changes.
    /// Returns the new text, or nil if nothing changed.
    public func reloadIfChanged() -> String? {
        guard !dirty, let name = current, let now = fileStamp(name), now != stamp,
            let content = read(name)
        else { return nil }
        stamp = now
        savedText = content
        guard content != text else { return nil }
        text = content
        return content
    }

    /// Creates an empty note named `Untitled`, `Untitled 2`, … and opens it.
    public func create() throws -> String {
        flush()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = makeUniqueName("Untitled") { exists($0) }
        try Data().write(to: url(name), options: .withoutOverwriting)
        current = name
        text = ""
        savedText = ""
        saveState = .saved
        stamp = fileStamp(name)
        return name
    }

    /// Renames a note's file and returns the name used, which is the proposal trimmed.
    /// A name the user gives stops the file from following the note's first line.
    public func rename(_ name: String, to proposed: String) throws -> String {
        guard let new = validNoteName(proposed) else { throw NoteStoreError.invalidName }
        var old = name
        if old == current {
            flush()
            old = current ?? old  // Saving may have renamed it to follow its first line.
        }
        guard new != old else { return old }
        // A case-only change finds the same file on a case-insensitive volume, and is allowed.
        if exists(new), !isSameFile(old, new) { throw NoteStoreError.exists }
        guard move(old, to: new) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if old == current {
            current = new
            stamp = fileStamp(new)
        }
        onRenamed(old, new)
        return new
    }

    /// Moves a note to the Trash after saving it, so the Trash holds the latest text.
    /// Returns the name the note had, which saving may have changed.
    @discardableResult
    public func trash(_ name: String) throws -> String {
        var name = name
        if name == current {
            flush()
            name = current ?? name
        }
        try FileManager.default.trashItem(at: url(name), resultingItemURL: nil)
        if name == current { closeCurrent() }
        return name
    }

    /// Saves the open note into the old folder, then forgets it.
    public func setFolder(_ newFolder: URL) {
        flush()
        folder = newFolder
        lastBackup = [:]
        closeCurrent()
    }

    /// Shows a message in the footer until the next successful save.
    public func notify(_ message: String) {
        report(message)
    }

    // MARK: - Private

    /// Renames the file after the first line of the saved text, numbering it if the name is
    /// taken. If that fails, the text is still saved; only the name lags behind.
    private func renameToFirstLine(_ name: String) {
        guard let title = titleFromText(text), !isNumbered(name, base: title) else { return }
        let new = makeUniqueName(title) { exists($0) && !isSameFile(name, $0) }
        guard move(name, to: new) else { return }
        current = new
        stamp = fileStamp(new)
        lastBackup[new] = lastBackup.removeValue(forKey: name)
        onRenamed(name, new)
    }

    /// Copies the note's file as it is now into `backups`, unless it's empty or was copied
    /// recently. A failed copy doesn't stop the save: the note itself matters more.
    private func backUp(_ name: String) {
        guard let backups, let size = fileStamp(name)?.size, size > 0,
            Date().timeIntervalSince(lastBackup[name] ?? .distantPast) >= backupInterval
        else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let base = "\(formatter.string(from: Date())) \(name.prefix(100))"
        let copyName = makeUniqueName(base) {
            FileManager.default.fileExists(atPath: backups.appendingPathComponent($0 + ".md").path)
        }
        do {
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            // Written rather than copied, so the backup's date is when it was made.
            try Data(contentsOf: url(name)).write(
                to: backups.appendingPathComponent(copyName + ".md"), options: .withoutOverwriting)
            lastBackup[name] = Date()
        } catch {
            return
        }
    }

    private func pruneBackups() {
        guard let backups else { return }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let files =
            (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: Array(keys)))
            ?? []
        for file in files where file.pathExtension == "md" {
            if let date = try? file.resourceValues(forKeys: keys).contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func closeCurrent() {
        current = nil
        text = ""
        savedText = ""
        saveState = .saved
        stamp = nil
    }

    private func report(_ message: String) {
        statusShown = true
        onStatus(message)
    }

    private func move(_ old: String, to new: String) -> Bool {
        Darwin.rename(url(old).path, url(new).path) == 0
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    private func isSameFile(_ a: String, _ b: String) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let x = try? url(a).resourceValues(forKeys: key).fileResourceIdentifier,
            let y = try? url(b).resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return x.isEqual(y)
    }

    private func fileStamp(_ name: String) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url(name).path),
            let date = attributes[.modificationDate] as? Date,
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return Stamp(date: date, size: size.intValue)
    }
}
