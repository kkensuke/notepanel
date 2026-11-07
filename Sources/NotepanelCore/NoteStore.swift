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

/// Notes are the `.md` files directly inside `folder`, and a file's name is its note's name.
/// Everything runs on the main thread: the files are small, and one thread keeps saving simple.
public final class NoteStore {
    public private(set) var folder: URL
    public private(set) var current: String?
    public private(set) var text = ""
    public var saveDelay: TimeInterval = 0.3
    /// A message for the footer, or nil to clear it.
    public var onStatus: (String?) -> Void = { _ in }
    /// The open note was saved under a new name because its file changed elsewhere.
    public var onConflict: (_ from: String, _ to: String) -> Void = { _, _ in }

    private struct Stamp: Equatable {
        let date: Date
        let size: Int
    }

    private var dirty = false
    private var stamp: Stamp?
    private var pending: DispatchWorkItem?
    private var statusShown = false

    public init(folder: URL) {
        self.folder = folder
    }

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
        dirty = false
        stamp = fileStamp(name)
        return content
    }

    public func edit(_ newText: String) {
        guard current != nil, newText != text else { return }
        text = newText
        dirty = true
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// Writes unsaved text now. A file changed elsewhere since it was read is never overwritten:
    /// the text goes to a new conflict file instead, which becomes the open note.
    public func flush() {
        pending?.cancel()
        pending = nil
        guard dirty, let name = current else { return }
        var target = name
        if let known = stamp, let now = fileStamp(name), now != known {
            target = makeUniqueName(conflictName(name, date: Date())) { exists($0) }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(target), options: .atomic)
        } catch {
            // Still dirty, so the next edit or flush tries again.
            report("Couldn’t save: \(error.localizedDescription)")
            return
        }
        dirty = false
        stamp = fileStamp(target)
        if target != name {
            current = target
            onConflict(name, target)
            report("“\(name)” was changed in another app, so your text was saved as “\(target)”.")
        } else if statusShown {
            statusShown = false
            onStatus(nil)
        }
    }

    /// Picks up edits made elsewhere, unless this note has unsaved changes.
    /// Returns the new text, or nil if nothing changed.
    public func reloadIfChanged() -> String? {
        guard !dirty, let name = current, let now = fileStamp(name), now != stamp,
            let content = read(name)
        else { return nil }
        stamp = now
        guard content != text else { return nil }
        text = content
        return content
    }

    /// Creates an empty note named `Untitled`, `Untitled 2`, … and opens it.
    public func create() throws -> String {
        flush()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = makeUniqueName("Untitled") { exists($0) }
        try Data().write(to: url(name), options: .atomic)
        current = name
        text = ""
        dirty = false
        stamp = fileStamp(name)
        return name
    }

    /// Renames a note's file and returns the name used, which is the proposal trimmed.
    public func rename(_ old: String, to proposed: String) throws -> String {
        guard let new = validNoteName(proposed) else { throw NoteStoreError.invalidName }
        guard new != old else { return old }
        // A case-only change finds the same file on a case-insensitive volume, and is allowed.
        if exists(new), !isSameFile(old, new) { throw NoteStoreError.exists }
        if old == current { flush() }
        guard Darwin.rename(url(old).path, url(new).path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if old == current {
            current = new
            stamp = fileStamp(new)
        }
        return new
    }

    /// Saves first, so the Trash holds the latest text.
    public func trash(_ name: String) throws {
        if name == current { flush() }
        try FileManager.default.trashItem(at: url(name), resultingItemURL: nil)
        if name == current { closeCurrent() }
    }

    /// Saves the open note into the old folder, then forgets it.
    public func setFolder(_ newFolder: URL) {
        flush()
        folder = newFolder
        closeCurrent()
    }

    /// Shows a message in the footer until the next successful save.
    public func notify(_ message: String) {
        report(message)
    }

    private func closeCurrent() {
        current = nil
        text = ""
        dirty = false
        stamp = nil
    }

    private func report(_ message: String) {
        statusShown = true
        onStatus(message)
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
