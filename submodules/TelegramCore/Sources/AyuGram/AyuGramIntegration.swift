import Foundation
import Postbox
import SwiftSignalKit
import AyuSettings
import AyuMessageArchive

/// Wires AyuGram into the parts of the stack that only TelegramCore can reach.
///
/// Call this once per process, as early as possible and before any account is
/// loaded: the Postbox hooks must be in place before the first sync pass, or
/// messages deleted during that pass are lost.
public func initializeAyuGram(containerPath: String) {
    let containerURL = URL(fileURLWithPath: containerPath, isDirectory: true)
    AyuSettings.shared.configure(containerURL: containerURL)
    AyuMessageArchive.shared.configure(containerURL: containerURL)

    AyuMessageArchiveBotClassifier.isBot = { peer in
        if let user = peer as? TelegramUser {
            return user.botInfo != nil
        }
        return false
    }

    PostboxMessageDeletionHook.willDelete = { transaction, messageIds in
        guard AyuSettings.current.saveDeletedMessages else {
            return
        }
        for id in messageIds {
            // Only cloud messages are worth keeping: local/pending ones were
            // never delivered, and secret chats are excluded deliberately.
            guard id.namespace == Namespaces.Message.Cloud else {
                continue
            }
            guard id.peerId.namespace != Namespaces.Peer.SecretChat else {
                continue
            }
            guard let message = transaction.getMessage(id) else {
                continue
            }
            AyuMessageArchive.shared.record(message, reason: .deleted)
        }
    }

    PostboxMessageDeletionHook.filterDeletions = { transaction, messageIds in
        let settings = AyuSettings.current
        guard settings.saveDeletedMessages && settings.showDeletedMessages else {
            return messageIds
        }
        let timestamp = Int32(Date().timeIntervalSince1970)
        var idsToDelete: [MessageId] = []
        var idsToRetain: [MessageId] = []
        for id in messageIds {
            guard id.namespace == Namespaces.Message.Cloud,
                  id.peerId.namespace != Namespaces.Peer.SecretChat,
                  let message = transaction.getMessage(id)
            else {
                idsToDelete.append(id)
                continue
            }
            // Already retained once: this deletion is the user clearing it for
            // real, so let it through.
            if message.isAyuDeleted {
                idsToDelete.append(id)
                continue
            }
            if !settings.saveForBots, let author = message.author as? TelegramUser, author.botInfo != nil {
                idsToDelete.append(id)
                continue
            }
            idsToRetain.append(id)
        }
        for id in idsToRetain {
            transaction.updateMessage(id) { message in
                var attributes = message.attributes
                attributes.append(AyuDeletedMessageAttribute(timestamp: timestamp))
                return .update(StoreMessage(
                    id: message.id,
                    // Preserve the stable id so the row keeps its place in the
                    // history list instead of animating in as a new message.
                    customStableId: message.stableId,
                    globallyUniqueId: message.globallyUniqueId,
                    groupingKey: message.groupingKey,
                    threadId: message.threadId,
                    timestamp: message.timestamp,
                    flags: StoreMessageFlags(message.flags),
                    tags: message.tags,
                    globalTags: message.globalTags,
                    localTags: message.localTags,
                    forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init),
                    authorId: message.author?.id,
                    text: message.text,
                    attributes: attributes,
                    media: message.media
                ))
            }
        }
        return idsToDelete
    }

    PostboxMessageDeletionHook.willUpdate = { _, message, update in
        guard AyuSettings.current.saveMessagesHistory else {
            return
        }
        guard case let .update(updated) = update else {
            return
        }
        guard message.id.namespace == Namespaces.Message.Cloud else {
            return
        }
        guard message.id.peerId.namespace != Namespaces.Peer.SecretChat else {
            return
        }
        // Postbox routes many non-edit changes (read marks, media fetch state,
        // reactions) through updateMessage, so archive only genuine text edits.
        guard updated.text != message.text else {
            return
        }
        let revision = AyuMessageArchive.shared.nextRevision(for: message.id)
        AyuMessageArchive.shared.record(message, reason: .edited, revision: revision)
    }
}

public extension AyuSettingsData {
    /// Whether a message should be sent silently, given the current mode.
    var shouldSendSilently: Bool {
        switch self.sendWithoutSound {
        case .never:
            return false
        case .always:
            return true
        case .whenGhostModeIsOn:
            return self.isGhostModeEnabled
        }
    }
}
