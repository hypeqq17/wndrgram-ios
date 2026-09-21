import Foundation
import Postbox
import SwiftSignalKit
import AyuSettings

/// Local, append-only archive of messages Telegram has dropped.
///
/// Layout is one framed file per peer (`<base>/ayu-archive/<peerId>.bin`),
/// each record being a 4-byte little-endian length followed by a Postbox blob.
/// Append-only keeps the write path cheap enough to run from inside a Postbox
/// deletion transaction, and a truncated tail (power loss mid-append) costs at
/// most the last record instead of the whole peer.
public final class AyuMessageArchive {
    public static let shared = AyuMessageArchive()

    private let writeQueue = Queue(name: "com.ayugram.archive.write")
    private let cacheLock = NSLock()
    private var baseURL: URL?
    private var cache: [PeerId: [AyuArchivedMessage]] = [:]
    private var loadedPeers = Set<PeerId>()

    /// Bumped on every write so chat UIs can invalidate cheaply.
    public let version = ValuePromise<Int32>(0, ignoreRepeated: false)
    private var versionValue: Int32 = 0

    private init() {}

    public func configure(containerURL: URL) {
        let directory = containerURL.appendingPathComponent("ayu-archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.cacheLock.lock()
        self.baseURL = directory
        self.cache.removeAll()
        self.loadedPeers.removeAll()
        self.cacheLock.unlock()

        let retentionDays = AyuSettings.current.historyRetentionDays
        if retentionDays > 0 {
            self.writeQueue.async {
                self.pruneOlderThan(days: retentionDays)
            }
        }
    }

    // MARK: - Writing

    /// Capture a message that is about to disappear. Cheap and synchronous:
    /// encoding happens on the caller thread, the file write is queued.
    public func record(_ message: Message, reason: AyuArchiveReason, revision: Int32 = 0) {
        let settings = AyuSettings.current
        switch reason {
        case .deleted:
            guard settings.saveDeletedMessages else {
                return
            }
        case .edited:
            guard settings.saveMessagesHistory else {
                return
            }
        }
        if !settings.saveForBots, let author = message.author, author.isBotOrService {
            return
        }
        // Outgoing messages the user deletes themselves are still archived:
        // AyuGram keeps both sides so an edited-then-deleted thread reads back
        // in full.
        let media = settings.saveDeletedMedia ? message.media : []
        let archived = AyuArchivedMessage(
            id: message.id,
            authorId: message.author?.id,
            timestamp: message.timestamp,
            archivedTimestamp: Int32(Date().timeIntervalSince1970),
            flags: message.flags,
            text: message.text,
            media: media,
            attributes: message.attributes,
            reason: reason,
            revision: revision
        )
        self.append(archived)
    }

    private func append(_ message: AyuArchivedMessage) {
        let payload = message.encoded()
        let peerId = message.id.peerId

        self.cacheLock.lock()
        if self.loadedPeers.contains(peerId) {
            self.cache[peerId, default: []].append(message)
        }
        self.versionValue += 1
        let version = self.versionValue
        let baseURL = self.baseURL
        self.cacheLock.unlock()
        self.version.set(version)

        guard let baseURL = baseURL else {
            // Not configured yet (extension launched before the main app set the
            // container). Dropping is correct: there is nowhere to put it.
            return
        }
        let url = baseURL.appendingPathComponent("\(peerId.toInt64()).bin")
        self.writeQueue.async {
            var frame = Data(count: 4)
            let length = UInt32(payload.count)
            frame.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: length.littleEndian, as: UInt32.self)
            }
            frame.append(payload)

            if let handle = try? FileHandle(forWritingTo: url) {
                defer {
                    handle.closeFile()
                }
                handle.seekToEndOfFile()
                handle.write(frame)
            } else {
                try? frame.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Reading

    /// Everything archived for a peer, oldest first.
    public func messages(peerId: PeerId) -> [AyuArchivedMessage] {
        self.cacheLock.lock()
        if self.loadedPeers.contains(peerId) {
            let result = self.cache[peerId] ?? []
            self.cacheLock.unlock()
            return result
        }
        let baseURL = self.baseURL
        self.cacheLock.unlock()

        guard let baseURL = baseURL else {
            return []
        }
        let loaded = AyuMessageArchive.readFile(at: baseURL.appendingPathComponent("\(peerId.toInt64()).bin"))

        self.cacheLock.lock()
        self.cache[peerId] = loaded
        self.loadedPeers.insert(peerId)
        self.cacheLock.unlock()
        return loaded
    }

    /// Ids of messages that were deleted in this peer, for fast per-row lookup
    /// while laying out the chat history.
    public func deletedMessageIds(peerId: PeerId) -> Set<MessageId> {
        var result = Set<MessageId>()
        for message in self.messages(peerId: peerId) where message.reason == .deleted {
            result.insert(message.id)
        }
        return result
    }

    /// Previous revisions of one message, oldest first.
    public func revisions(of id: MessageId) -> [AyuArchivedMessage] {
        return self.messages(peerId: id.peerId)
            .filter { $0.id == id && $0.reason == .edited }
            .sorted { $0.revision < $1.revision }
    }

    public func nextRevision(for id: MessageId) -> Int32 {
        return (self.revisions(of: id).last?.revision ?? -1) + 1
    }

    private static func readFile(at url: URL) -> [AyuArchivedMessage] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        var result: [AyuArchivedMessage] = []
        var offset = 0
        while offset + 4 <= data.count {
            // Assembled byte by byte rather than loaded as a UInt32: the
            // record boundary is not guaranteed to be 4-byte aligned.
            var lengthValue: UInt32 = 0
            for index in 0 ..< 4 {
                lengthValue |= UInt32(data[data.startIndex + offset + index]) << (8 * UInt32(index))
            }
            let length = Int(lengthValue)
            offset += 4
            // A short or absurd length means the tail was truncated; stop
            // rather than discarding the records that did survive.
            guard length > 0, offset + length <= data.count else {
                break
            }
            if let message = AyuArchivedMessage.decoded(from: data.subdata(in: offset ..< (offset + length))) {
                result.append(message)
            }
            offset += length
        }
        return result
    }

    // MARK: - Maintenance

    public func clear(peerId: PeerId) {
        self.cacheLock.lock()
        self.cache.removeValue(forKey: peerId)
        self.loadedPeers.remove(peerId)
        let baseURL = self.baseURL
        self.cacheLock.unlock()

        guard let baseURL = baseURL else {
            return
        }
        let url = baseURL.appendingPathComponent("\(peerId.toInt64()).bin")
        self.writeQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
        self.bumpVersion()
    }

    public func clearAll() {
        self.cacheLock.lock()
        self.cache.removeAll()
        self.loadedPeers.removeAll()
        let baseURL = self.baseURL
        self.cacheLock.unlock()

        guard let baseURL = baseURL else {
            return
        }
        self.writeQueue.async {
            let contents = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }
        self.bumpVersion()
    }

    /// Total size on disk, for the settings screen.
    public func diskUsage() -> Int64 {
        self.cacheLock.lock()
        let baseURL = self.baseURL
        self.cacheLock.unlock()
        guard let baseURL = baseURL else {
            return 0
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for url in contents {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Rewrite every peer file without records older than the retention window.
    private func pruneOlderThan(days: Int32) {
        self.cacheLock.lock()
        let baseURL = self.baseURL
        self.cacheLock.unlock()
        guard let baseURL = baseURL else {
            return
        }
        let cutoff = Int32(Date().timeIntervalSince1970) - days * 24 * 60 * 60
        let contents = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            let messages = AyuMessageArchive.readFile(at: url)
            let kept = messages.filter { $0.archivedTimestamp >= cutoff }
            if kept.count == messages.count {
                continue
            }
            if kept.isEmpty {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            var rewritten = Data()
            for message in kept {
                let payload = message.encoded()
                var length = UInt32(payload.count).littleEndian
                rewritten.append(Data(bytes: &length, count: 4))
                rewritten.append(payload)
            }
            try? rewritten.write(to: url, options: .atomic)
        }

        self.cacheLock.lock()
        self.cache.removeAll()
        self.loadedPeers.removeAll()
        self.cacheLock.unlock()
        self.bumpVersion()
    }

    private func bumpVersion() {
        self.cacheLock.lock()
        self.versionValue += 1
        let version = self.versionValue
        self.cacheLock.unlock()
        self.version.set(version)
    }
}

private extension Peer {
    var isBotOrService: Bool {
        // Kept structural so AyuMessageArchive does not need TelegramCore: a
        // bot or service account is any peer whose id namespace is a user but
        // that the caller flagged. TelegramCore refines this when it installs
        // the hook.
        return AyuMessageArchiveBotClassifier.isBot?(self) ?? false
    }
}

/// TelegramCore owns the notion of "bot", so it supplies the predicate.
public enum AyuMessageArchiveBotClassifier {
    public static var isBot: ((Peer) -> Bool)?
}
