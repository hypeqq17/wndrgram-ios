import Foundation
import Postbox
import SwiftSignalKit
import AyuSettings
import AyuMessageArchive
import TelegramApi

/// Wires WndrGram into the parts of the stack that only TelegramCore can reach.
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
        // The user deleting something themselves is never overridden: it
        // goes to the local archive through `willDelete`, but leaves the chat.
        if AyuDeletionScope.isUserInitiated {
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
            // Already retained: the server repeating the deletion (difference
            // replays, channel resyncs) must neither drop nor re-stamp it.
            if message.isAyuDeleted {
                continue
            }
            if !settings.saveForBots, let author = message.author as? TelegramUser, author.botInfo != nil {
                idsToDelete.append(id)
                continue
            }
            // Service messages ("X joined", pinned notices) are noise once
            // deleted; WndrGram Desktop drops them too.
            if message.media.contains(where: { $0 is TelegramMediaAction }) {
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

/// Marks deletions the user asked for, so the retention hook lets them through.
///
/// Only touched on the Postbox queue, from inside a transaction, and the hook
/// runs synchronously within that same call, so a plain counter is enough.
enum AyuDeletionScope {
    fileprivate static var depth: Int = 0

    static var isUserInitiated: Bool {
        return depth > 0
    }
}

func ayuPerformUserInitiatedDeletion(_ f: () -> Void) {
    AyuDeletionScope.depth += 1
    defer {
        AyuDeletionScope.depth -= 1
    }
    f()
}

/// Adds the "silent" flag to outgoing messages when the user configured
/// WndrGram to send without sound.
func ayuApplySilentSending(peerId: PeerId, messages: [(Bool, EnqueueMessage)]) -> [(Bool, EnqueueMessage)] {
    guard AyuSettings.current.shouldSendSilently else {
        return messages
    }
    if peerId.namespace == Namespaces.Peer.SecretChat {
        return messages
    }
    return messages.map { flag, message in
        return (flag, message.withUpdatedAttributes { attributes in
            if attributes.contains(where: { $0 is NotificationInfoMessageAttribute }) {
                return attributes
            }
            var attributes = attributes
            attributes.append(NotificationInfoMessageAttribute(flags: .muted))
            return attributes
        })
    }
}

/// How many recent stickers are kept locally. Telegram trims to 20; WndrGram's
/// "unlimited" option keeps a much longer tail.
var ayuRecentStickersLimit: Int {
    return AyuSettings.current.unlimitedRecentStickers ? 200 : 20
}

/// WndrGram "send as scheduled": in ghost mode, outgoing messages are sent as
/// scheduled a few seconds ahead, so the server does not bring the account
/// online when they are delivered.
func ayuApplyScheduledSending(peerId: PeerId, accountPeerId: PeerId, messages: [(Bool, EnqueueMessage)]) -> [(Bool, EnqueueMessage)] {
    let settings = AyuSettings.current
    guard settings.useScheduledMessages && settings.isGhostModeEnabled else {
        return messages
    }
    if peerId.namespace == Namespaces.Peer.SecretChat || peerId == accountPeerId {
        return messages
    }
    let scheduleTime = Int32(Date().timeIntervalSince1970) + 12
    return messages.map { flag, message in
        return (flag, message.withUpdatedAttributes { attributes in
            if attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute || $0 is OutgoingQuickReplyMessageAttribute }) {
                return attributes
            }
            var attributes = attributes
            attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: nil))
            return attributes
        })
    }
}

/// WndrGram "read after action": with read receipts off, replying in a chat
/// still sends one read receipt for it, like the desktop client does.
func ayuReadAfterAction(transaction: Transaction, account: Account, peerId: PeerId) {
    let settings = AyuSettings.current
    guard !settings.sendReadMessages && settings.markReadAfterAction else {
        return
    }
    guard let peer = transaction.getPeer(peerId) else {
        return
    }
    let signal: Signal<Void, NoError>
    if peerId.namespace == Namespaces.Peer.CloudChannel {
        guard let inputChannel = apiInputChannel(peer) else {
            return
        }
        signal = account.network.request(Api.functions.channels.readHistory(channel: inputChannel, maxId: Int32.max - 1))
        |> map { _ -> Void in
            return Void()
        }
        |> `catch` { _ -> Signal<Void, NoError> in
            return .complete()
        }
    } else if peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.CloudGroup {
        guard let inputPeer = apiInputPeer(peer) else {
            return
        }
        signal = account.network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: Int32.max - 1))
        |> map { _ -> Void in
            return Void()
        }
        |> `catch` { _ -> Signal<Void, NoError> in
            return .complete()
        }
    } else {
        return
    }
    let _ = signal.start()
}

/// The icon badge a notification should set: zero when WndrGram's "hide
/// notification counters" is on. Used by the notification service extension.
public func ayuNotificationBadge(_ value: Int) -> Int {
    return AyuSettings.current.hideNotificationCounters ? 0 : value
}
