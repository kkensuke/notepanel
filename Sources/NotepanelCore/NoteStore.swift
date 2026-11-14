import Darwin
import Foundation

public struct NoteInfo: Equatable {
    public let name: String
    public let modified: Date
}

/// One of a note's earlier versions: its text when it was kept.
public struct NoteVersion: Equatable {
    public let date: Date
    public let text: String
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

/// Notes are the `.md` files directly inside `folder`, and a file's name is its note's name. A
/// note's history is the folder of the same name in `history`.
///
/// Losing text is the worst failure, so text only ever moves forward:
/// - Writes are atomic, and a failed write keeps the text unsaved, to be tried again.
/// - A file changed elsewhere since it was read is never overwritten; the text goes to a
///   conflict copy instead.
/// - Before a note's file is overwritten, its current contents are kept as a version, at most
///   once per `versionInterval` per note. The versions are then thinned (`versionsToKeep`).
/// - Renames never replace another file, and deleted notes go to the Trash.
///
/// Everything runs on the main thread: the files are small, and one thread keeps saving simple.
public final class NoteStore {
    /// Holds `Notes`, `History` and settings.json, so that the three move and sync together.
    public private(set) var dataFolder: URL
    public var folder: URL { dataFolder.appendingPathComponent("Notes", isDirectory: true) }
    public var history: URL { dataFolder.appendingPathComponent("History", isDirectory: true) }
    public private(set) var current: String?
    public private(set) var text = ""
    public var saveDelay: TimeInterval = 0.3
    public var versionInterval: TimeInterval = 10 * 60
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

    public init(dataFolder: URL) {
        self.dataFolder = dataFolder
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
            keepVersion(name)
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
            setAsideHistory(target)
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
        setAsideHistory(name)
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
    /// Returns the name the note had, which saving may have changed. Its history stays under the
    /// same name, so a note put back from the Trash finds it again.
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

    /// Saves the open note into the old data folder, then forgets it.
    public func setFolder(_ newFolder: URL) {
        flush()
        dataFolder = newFolder
        closeCurrent()
    }

    /// Shows a message in the footer until the next successful save.
    public func notify(_ message: String) {
        report(message)
    }

    // MARK: - History

    /// A note's earlier versions with their text, newest first. Any that isn't UTF-8 text is
    /// left out.
    public func versions(of name: String) -> [NoteVersion] {
        versions(in: historyFolder(name)).compactMap { version in
            guard let data = try? Data(contentsOf: version.url), let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return NoteVersion(date: version.date, text: text)
        }
    }

    /// How long versions a week apart are kept, from the data folder's settings.json. It's read
    /// each time, so a change made on another Mac counts once the file has synced.
    public var keepHistory: KeepHistory {
        KeepHistory(settings: try? Data(contentsOf: settingsFile))
    }

    /// Saves how long to keep versions. With a limit, the versions now past it go at once, from
    /// every folder in `history`, including those of notes that are gone.
    public func setKeepHistory(_ keep: KeepHistory) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["keepHistory": keep.rawValue], options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        try data.write(to: settingsFile, options: .atomic)
        guard keep.limit != nil else { return }
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: history, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        for folder in folders where (try? folder.resourceValues(forKeys: keys).isDirectory) == true {
            thin(folder)
        }
    }

    // MARK: - Private

    private var settingsFile: URL {
        dataFolder.appendingPathComponent("settings.json", isDirectory: false)
    }

    private func historyFolder(_ name: String) -> URL {
        history.appendingPathComponent(name, isDirectory: true)
    }

    /// Renames the file after the first line of the saved text, numbering it if the name is
    /// taken. If that fails, the text is still saved; only the name lags behind.
    private func renameToFirstLine(_ name: String) {
        guard let title = titleFromText(text), !isNumbered(name, base: title) else { return }
        let new = makeUniqueName(title) { exists($0) && !isSameFile(name, $0) }
        guard move(name, to: new) else { return }
        current = new
        stamp = fileStamp(new)
        onRenamed(name, new)
    }

    /// Keeps the note's file as it is now as a version, unless it's empty or the newest version
    /// is recent, then thins the note's versions. The newest version is read from the folder
    /// rather than remembered, so it holds after a restart or a rename, and counts a version
    /// another Mac kept. A failed copy doesn't stop the save: the note itself matters more.
    private func keepVersion(_ name: String) {
        guard let size = fileStamp(name)?.size, size > 0 else { return }
        let folder = historyFolder(name)
        let now = Date()
        if let newest = versions(in: folder).first?.date, now.timeIntervalSince(newest) < versionInterval { return }
        let copy = makeUniqueName(versionName(now)) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0 + ".md").path)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(contentsOf: url(name)).write(
                to: folder.appendingPathComponent(copy + ".md"), options: .withoutOverwriting)
        } catch {
            return
        }
        thin(folder, now: now)
    }

    /// The versions in a history folder, newest first: the `.md` files `versionName` named.
    /// Anything else in the folder is left alone.
    private func versions(in folder: URL) -> [(url: URL, date: Date)] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { file -> (url: URL, date: Date)? in
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "md", let date = versionDate(name) else { return nil }
            return (file, date)
        }
        .sorted { $0.date > $1.date }
    }

    private func thin(_ folder: URL, now: Date = Date()) {
        let all = versions(in: folder)
        let kept = versionsToKeep(all.map(\.date), now: now, limit: keepHistory.limit)
        for version in all where !kept.contains(version.date) {
            try? FileManager.default.removeItem(at: version.url)
        }
    }

    /// Moves the history folder under `name` aside, to `name (old 2026-11-14 2208)`, as a note
    /// takes the name. Names never clash in `folder`, so a history folder under a new name was
    /// left by a note that's gone: deleted, or renamed in Finder. If moving it fails, the new
    /// note's versions join the old ones, but none are lost.
    private func setAsideHistory(_ name: String) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: historyFolder(name).path) else { return }
        let aside = makeUniqueName(oldHistoryName(name, date: Date())) {
            manager.fileExists(atPath: self.historyFolder($0).path)
        }
        _ = Darwin.rename(historyFolder(name).path, historyFolder(aside).path)
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

    /// Renames a note's file, then its history folder, after moving a gone note's history out of
    /// the way. A change only in case finds the same history folder under both names on a
    /// case-insensitive volume, so that one is just renamed.
    private func move(_ old: String, to new: String) -> Bool {
        guard Darwin.rename(url(old).path, url(new).path) == 0 else { return false }
        if !isSameItem(historyFolder(old), historyFolder(new)) { setAsideHistory(new) }
        _ = Darwin.rename(historyFolder(old).path, historyFolder(new).path)
        return true
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    private func isSameFile(_ a: String, _ b: String) -> Bool {
        isSameItem(url(a), url(b))
    }

    private func isSameItem(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
            let y = try? b.resourceValues(forKeys: key).fileResourceIdentifier
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
