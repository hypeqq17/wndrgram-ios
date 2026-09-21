import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AyuSettings
import AyuMessageArchive

// AyuGram carries its own strings: they are not part of the upstream
// localization file, so the screen uses literals rather than
// `presentationData.strings`.

private final class AyuGramSettingsArguments {
    let updateSettings: ((inout AyuSettingsData) -> Void) -> Void
    let clearArchive: () -> Void

    init(
        updateSettings: @escaping ((inout AyuSettingsData) -> Void) -> Void,
        clearArchive: @escaping () -> Void
    ) {
        self.updateSettings = updateSettings
        self.clearArchive = clearArchive
    }
}

private enum AyuGramSettingsSection: Int32 {
    case ghost
    case archive
    case appearance
    case behaviour
    case privacy
    case maintenance
}

private enum AyuGramSettingsEntry: ItemListNodeEntry {
    case ghostHeader
    case ghostMaster(Bool)
    case ghostReadMessages(Bool)
    case ghostReadStories(Bool)
    case ghostOnline(Bool)
    case ghostTyping(Bool)
    case ghostUploadProgress(Bool)
    case ghostOfflineAfterOnline(Bool)
    case ghostFooter

    case archiveHeader
    case archiveDeleted(Bool)
    case archiveEdits(Bool)
    case archiveMedia(Bool)
    case archiveForBots(Bool)
    case archiveRetention(Int32)
    case archiveFooter

    case appearanceHeader
    case appearanceShowDeleted(Bool)
    case appearanceDimDeleted(Bool)
    case appearanceMessageSeconds(Bool)
    case appearanceShowPeerId(AyuPeerIdDisplay)
    case appearanceBubbleRadius(Int32)
    case appearanceHideAllChatsFolder(Bool)
    case appearanceDisableStories(Bool)
    case appearanceDisableAds(Bool)

    case behaviourHeader
    case behaviourDisableLinkWarning(Bool)
    case behaviourDisableGreeting(Bool)
    case behaviourStickerConfirmation(Bool)
    case behaviourVoiceConfirmation(Bool)
    case behaviourUnlimitedStickers(Bool)

    case privacyHeader
    case privacyKeepUnread(Bool)
    case privacyAppSwitcher(Bool)
    case privacyStreamerMode(Bool)
    case privacyFooter

    case maintenanceUsage(String)
    case maintenanceClear

    var section: ItemListSectionId {
        switch self {
        case .ghostHeader, .ghostMaster, .ghostReadMessages, .ghostReadStories, .ghostOnline, .ghostTyping, .ghostUploadProgress, .ghostOfflineAfterOnline, .ghostFooter:
            return AyuGramSettingsSection.ghost.rawValue
        case .archiveHeader, .archiveDeleted, .archiveEdits, .archiveMedia, .archiveForBots, .archiveRetention, .archiveFooter:
            return AyuGramSettingsSection.archive.rawValue
        case .appearanceHeader, .appearanceShowDeleted, .appearanceDimDeleted, .appearanceMessageSeconds, .appearanceShowPeerId, .appearanceBubbleRadius, .appearanceHideAllChatsFolder, .appearanceDisableStories, .appearanceDisableAds:
            return AyuGramSettingsSection.appearance.rawValue
        case .behaviourHeader, .behaviourDisableLinkWarning, .behaviourDisableGreeting, .behaviourStickerConfirmation, .behaviourVoiceConfirmation, .behaviourUnlimitedStickers:
            return AyuGramSettingsSection.behaviour.rawValue
        case .privacyHeader, .privacyKeepUnread, .privacyAppSwitcher, .privacyStreamerMode, .privacyFooter:
            return AyuGramSettingsSection.privacy.rawValue
        case .maintenanceUsage, .maintenanceClear:
            return AyuGramSettingsSection.maintenance.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .ghostHeader: return 0
        case .ghostMaster: return 1
        case .ghostReadMessages: return 2
        case .ghostReadStories: return 3
        case .ghostOnline: return 4
        case .ghostTyping: return 5
        case .ghostUploadProgress: return 6
        case .ghostOfflineAfterOnline: return 7
        case .ghostFooter: return 8

        case .archiveHeader: return 20
        case .archiveDeleted: return 21
        case .archiveEdits: return 22
        case .archiveMedia: return 23
        case .archiveForBots: return 24
        case .archiveRetention: return 25
        case .archiveFooter: return 26

        case .appearanceHeader: return 40
        case .appearanceShowDeleted: return 41
        case .appearanceDimDeleted: return 42
        case .appearanceMessageSeconds: return 43
        case .appearanceShowPeerId: return 44
        case .appearanceBubbleRadius: return 45
        case .appearanceHideAllChatsFolder: return 46
        case .appearanceDisableStories: return 47
        case .appearanceDisableAds: return 48

        case .behaviourHeader: return 60
        case .behaviourDisableLinkWarning: return 61
        case .behaviourDisableGreeting: return 62
        case .behaviourStickerConfirmation: return 63
        case .behaviourVoiceConfirmation: return 64
        case .behaviourUnlimitedStickers: return 65

        case .privacyHeader: return 80
        case .privacyKeepUnread: return 81
        case .privacyAppSwitcher: return 82
        case .privacyStreamerMode: return 83
        case .privacyFooter: return 84

        case .maintenanceUsage: return 100
        case .maintenanceClear: return 101
        }
    }

    static func <(lhs: AyuGramSettingsEntry, rhs: AyuGramSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AyuGramSettingsArguments

        func toggle(_ title: String, _ value: Bool, _ apply: @escaping (inout AyuSettingsData, Bool) -> Void) -> ListViewItem {
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.updateSettings { settings in
                    apply(&settings, updatedValue)
                }
            })
        }

        switch self {
        case .ghostHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "GHOST MODE", sectionId: self.section)
        case let .ghostMaster(value):
            return toggle("Ghost Mode", value) { settings, value in
                settings.setGhostMode(value)
            }
        case let .ghostReadMessages(value):
            return toggle("Send Read Receipts", value) { settings, value in
                settings.sendReadMessages = value
            }
        case let .ghostReadStories(value):
            return toggle("Mark Stories as Viewed", value) { settings, value in
                settings.sendReadStories = value
            }
        case let .ghostOnline(value):
            return toggle("Send Online Status", value) { settings, value in
                settings.sendOnlinePackets = value
            }
        case let .ghostTyping(value):
            return toggle("Send Typing Status", value) { settings, value in
                settings.sendTypingStatus = value
            }
        case let .ghostUploadProgress(value):
            return toggle("Send Upload Progress", value) { settings, value in
                settings.sendUploadProgress = value
            }
        case let .ghostOfflineAfterOnline(value):
            return toggle("Send Offline Packet After Going Ghost", value) { settings, value in
                settings.sendOfflinePacketAfterOnline = value
            }
        case .ghostFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("With Ghost Mode on, chats and stories are still marked read on this device, but nothing is reported to the other side."), sectionId: self.section)

        case .archiveHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "LOCAL MESSAGE ARCHIVE", sectionId: self.section)
        case let .archiveDeleted(value):
            return toggle("Keep Deleted Messages", value) { settings, value in
                settings.saveDeletedMessages = value
            }
        case let .archiveEdits(value):
            return toggle("Keep Edit History", value) { settings, value in
                settings.saveMessagesHistory = value
            }
        case let .archiveMedia(value):
            return toggle("Keep Media of Deleted Messages", value) { settings, value in
                settings.saveDeletedMedia = value
            }
        case let .archiveForBots(value):
            return toggle("Include Bots", value) { settings, value in
                settings.saveForBots = value
            }
        case let .archiveRetention(days):
            let label = days == 0 ? "Forever" : "\(days) days"
            return ItemListDisclosureItem(presentationData: presentationData, title: "Keep For", label: label, sectionId: self.section, style: .blocks, action: {
                // Cycles through the same windows AyuGram Desktop offers.
                let options: [Int32] = [0, 7, 30, 90, 365]
                let index = options.firstIndex(of: days) ?? 0
                let next = options[(index + 1) % options.count]
                arguments.updateSettings { settings in
                    settings.historyRetentionDays = next
                }
            })
        case .archiveFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Deleted messages stay on this device only. They are never uploaded anywhere."), sectionId: self.section)

        case .appearanceHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "APPEARANCE", sectionId: self.section)
        case let .appearanceShowDeleted(value):
            return toggle("Show Deleted Messages in Chat", value) { settings, value in
                settings.showDeletedMessages = value
            }
        case let .appearanceDimDeleted(value):
            return toggle("Dim Deleted Messages", value) { settings, value in
                settings.semiTransparentDeletedMessages = value
            }
        case let .appearanceMessageSeconds(value):
            return toggle("Show Seconds in Timestamps", value) { settings, value in
                settings.showMessageSeconds = value
            }
        case let .appearanceShowPeerId(mode):
            let label: String
            switch mode {
            case .hidden: label = "Hidden"
            case .botApi: label = "Bot API"
            case .telegram: label = "Telegram"
            }
            return ItemListDisclosureItem(presentationData: presentationData, title: "Show Peer ID", label: label, sectionId: self.section, style: .blocks, action: {
                let next: AyuPeerIdDisplay
                switch mode {
                case .hidden: next = .botApi
                case .botApi: next = .telegram
                case .telegram: next = .hidden
                }
                arguments.updateSettings { settings in
                    settings.showPeerId = next
                }
            })
        case let .appearanceBubbleRadius(radius):
            return ItemListDisclosureItem(presentationData: presentationData, title: "Bubble Corner Radius", label: "\(radius)", sectionId: self.section, style: .blocks, action: {
                let options: [Int32] = [0, 6, 10, 16, 20]
                let index = options.firstIndex(of: radius) ?? 3
                let next = options[(index + 1) % options.count]
                arguments.updateSettings { settings in
                    settings.messageBubbleRadius = next
                }
            })
        case let .appearanceHideAllChatsFolder(value):
            return toggle("Hide \"All Chats\" Folder", value) { settings, value in
                settings.hideAllChatsFolder = value
            }
        case let .appearanceDisableStories(value):
            return toggle("Hide Stories", value) { settings, value in
                settings.disableStories = value
            }
        case let .appearanceDisableAds(value):
            return toggle("Hide Sponsored Messages", value) { settings, value in
                settings.disableAds = value
            }

        case .behaviourHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "BEHAVIOUR", sectionId: self.section)
        case let .behaviourDisableLinkWarning(value):
            return toggle("Skip Link Open Warning", value) { settings, value in
                settings.disableOpenLinkWarning = value
            }
        case let .behaviourDisableGreeting(value):
            return toggle("Disable Greeting Sticker", value) { settings, value in
                settings.disableGreetingSticker = value
            }
        case let .behaviourStickerConfirmation(value):
            return toggle("Confirm Before Sending Stickers", value) { settings, value in
                settings.stickerConfirmation = value
            }
        case let .behaviourVoiceConfirmation(value):
            return toggle("Confirm Before Sending Voice Messages", value) { settings, value in
                settings.voiceConfirmation = value
            }
        case let .behaviourUnlimitedStickers(value):
            return toggle("Unlimited Recent Stickers", value) { settings, value in
                settings.unlimitedRecentStickers = value
            }

        case .privacyHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "PRIVACY", sectionId: self.section)
        case let .privacyKeepUnread(value):
            return toggle("Keep Chats Unread When Opened From a Notification", value) { settings, value in
                settings.keepUnreadOnNotificationOpen = value
            }
        case let .privacyAppSwitcher(value):
            return toggle("Hide Contents in App Switcher", value) { settings, value in
                settings.privacyScreenInAppSwitcher = value
            }
        case let .privacyStreamerMode(value):
            return toggle("Streamer Mode", value) { settings, value in
                settings.streamerMode = value
            }
        case .privacyFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Streamer Mode hides message contents from screenshots and screen recordings."), sectionId: self.section)

        case let .maintenanceUsage(text):
            return ItemListDisclosureItem(presentationData: presentationData, title: "Archive Size", label: text, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case .maintenanceClear:
            return ItemListActionItem(presentationData: presentationData, title: "Clear Local Archive", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.clearArchive()
            })
        }
    }
}

private func ayuGramSettingsEntries(settings: AyuSettingsData, archiveSize: String) -> [AyuGramSettingsEntry] {
    var entries: [AyuGramSettingsEntry] = []

    entries.append(.ghostHeader)
    entries.append(.ghostMaster(settings.isGhostModeEnabled))
    entries.append(.ghostReadMessages(settings.sendReadMessages))
    entries.append(.ghostReadStories(settings.sendReadStories))
    entries.append(.ghostOnline(settings.sendOnlinePackets))
    entries.append(.ghostTyping(settings.sendTypingStatus))
    entries.append(.ghostUploadProgress(settings.sendUploadProgress))
    entries.append(.ghostOfflineAfterOnline(settings.sendOfflinePacketAfterOnline))
    entries.append(.ghostFooter)

    entries.append(.archiveHeader)
    entries.append(.archiveDeleted(settings.saveDeletedMessages))
    entries.append(.archiveEdits(settings.saveMessagesHistory))
    if settings.saveDeletedMessages {
        entries.append(.archiveMedia(settings.saveDeletedMedia))
    }
    entries.append(.archiveForBots(settings.saveForBots))
    entries.append(.archiveRetention(settings.historyRetentionDays))
    entries.append(.archiveFooter)

    entries.append(.appearanceHeader)
    entries.append(.appearanceShowDeleted(settings.showDeletedMessages))
    if settings.showDeletedMessages {
        entries.append(.appearanceDimDeleted(settings.semiTransparentDeletedMessages))
    }
    entries.append(.appearanceMessageSeconds(settings.showMessageSeconds))
    entries.append(.appearanceShowPeerId(settings.showPeerId))
    entries.append(.appearanceBubbleRadius(settings.messageBubbleRadius))
    entries.append(.appearanceHideAllChatsFolder(settings.hideAllChatsFolder))
    entries.append(.appearanceDisableStories(settings.disableStories))
    entries.append(.appearanceDisableAds(settings.disableAds))

    entries.append(.behaviourHeader)
    entries.append(.behaviourDisableLinkWarning(settings.disableOpenLinkWarning))
    entries.append(.behaviourDisableGreeting(settings.disableGreetingSticker))
    entries.append(.behaviourStickerConfirmation(settings.stickerConfirmation))
    entries.append(.behaviourVoiceConfirmation(settings.voiceConfirmation))
    entries.append(.behaviourUnlimitedStickers(settings.unlimitedRecentStickers))

    entries.append(.privacyHeader)
    entries.append(.privacyKeepUnread(settings.keepUnreadOnNotificationOpen))
    entries.append(.privacyAppSwitcher(settings.privacyScreenInAppSwitcher))
    entries.append(.privacyStreamerMode(settings.streamerMode))
    entries.append(.privacyFooter)

    entries.append(.maintenanceUsage(archiveSize))
    entries.append(.maintenanceClear)

    return entries
}

private func formatArchiveSize(_ bytes: Int64) -> String {
    if bytes <= 0 {
        return "Empty"
    }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

public func ayuGramSettingsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController) -> Void)?

    let arguments = AyuGramSettingsArguments(
        updateSettings: { modify in
            AyuSettings.shared.update(modify)
        },
        clearArchive: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let controller = textAlertController(
                context: context,
                title: "Clear Local Archive",
                text: "All locally kept deleted messages and edit history will be removed from this device. This cannot be undone.",
                actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: {
                        AyuMessageArchive.shared.clearAll()
                    })
                ]
            )
            presentControllerImpl?(controller)
        }
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        AyuSettings.shared.signal,
        AyuMessageArchive.shared.version.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, settings, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let archiveSize = formatArchiveSize(AyuMessageArchive.shared.diskUsage())

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("AyuGram"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: ayuGramSettingsEntries(settings: settings, archiveSize: archiveSize),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
