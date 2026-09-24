import Foundation

public enum AyuSendWithoutSoundOption: Int32, Codable {
    case never = 0
    case always = 1
    case whenGhostModeIsOn = 2
}

public enum AyuPeerIdDisplay: Int32, Codable {
    case hidden = 0
    case botApi = 1
    case telegram = 2
}

/// Full settings payload. Adding a field here is safe: decoding uses
/// per-field defaults, so older settings files keep loading.
public struct AyuSettingsData: Codable, Equatable {
    // MARK: Ghost mode
    public var sendReadMessages: Bool = true
    public var sendReadStories: Bool = true
    public var sendOnlinePackets: Bool = true
    public var sendUploadProgress: Bool = true
    public var sendTypingStatus: Bool = true
    public var sendOfflinePacketAfterOnline: Bool = false
    public var markReadAfterAction: Bool = true
    public var useScheduledMessages: Bool = false
    public var sendWithoutSound: AyuSendWithoutSoundOption = .never
    public var suggestGhostModeBeforeViewingStory: Bool = true

    // MARK: History / local archive
    public var saveDeletedMessages: Bool = true
    public var saveMessagesHistory: Bool = true
    public var saveForBots: Bool = false
    public var saveDeletedMedia: Bool = true
    /// Keep view-once and timer photos/videos/voice after they "expire".
    public var saveSelfDestructingMedia: Bool = true
    public var historyRetentionDays: Int32 = 0 // 0 == forever

    // MARK: Chat appearance
    /// Optional text shown before the time of kept deleted / edited messages.
    public var deletedMark: String = ""
    public var editedMark: String = ""
    /// AyuGram-style trash / pencil icons next to the time.
    public var showDeletedIcon: Bool = true
    public var showEditedIcon: Bool = true
    public var showDeletedMessages: Bool = true
    public var semiTransparentDeletedMessages: Bool = false
    public var showMessageSeconds: Bool = false
    public var showPeerId: AyuPeerIdDisplay = .botApi
    public var messageBubbleRadius: Int32 = 16
    /// Avatar corner radius as a percentage of the avatar's size: 50 is a circle, 0 a square.
    public var avatarRoundness: Int32 = 50
    public var hideAllChatsFolder: Bool = false
    public var disableStories: Bool = false
    public var disableAds: Bool = true
    public var hideNotificationCounters: Bool = false
    public var collapseSimilarChannels: Bool = true

    // MARK: Behaviour
    public var disableOpenLinkWarning: Bool = false
    public var disableGreetingSticker: Bool = false
    public var stickerConfirmation: Bool = false
    public var gifConfirmation: Bool = false
    public var voiceConfirmation: Bool = false
    public var roundConfirmation: Bool = false
    public var unlimitedRecentStickers: Bool = false
    public var localPremium: Bool = false
    /// Show locally added gifts in the user's own profile ("skin changer").
    public var localGifts: Bool = false

    // MARK: Ayu extras (not present in WndrGram Desktop)
    /// Do not let a chat be marked read when the app is opened from a notification.
    public var keepUnreadOnNotificationOpen: Bool = false
    /// Blur the app contents while it sits in the app switcher.
    public var privacyScreenInAppSwitcher: Bool = false
    /// Hide message contents from screenshots and screen recordings.
    public var streamerMode: Bool = false
    /// Require Face ID to reveal the locally archived deleted messages.
    public var lockMessageArchive: Bool = false

    // MARK: Deleted message look
    /// Opacity of kept deleted messages, in percent, when dimming is on.
    public var deletedMessageOpacity: Int32 = 55

    public var ghostModeActive: Bool = false

    public init() {}

    // Explicit decoder so a missing or unknown key never fails the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AyuSettingsData()
        func b(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            return ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? fallback
        }
        func i(_ key: CodingKeys, _ fallback: Int32) -> Int32 {
            return ((try? c.decodeIfPresent(Int32.self, forKey: key)) ?? nil) ?? fallback
        }
        func s(_ key: CodingKeys, _ fallback: String) -> String {
            return ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? fallback
        }

        self.sendReadMessages = b(.sendReadMessages, d.sendReadMessages)
        self.sendReadStories = b(.sendReadStories, d.sendReadStories)
        self.sendOnlinePackets = b(.sendOnlinePackets, d.sendOnlinePackets)
        self.sendUploadProgress = b(.sendUploadProgress, d.sendUploadProgress)
        self.sendTypingStatus = b(.sendTypingStatus, d.sendTypingStatus)
        self.sendOfflinePacketAfterOnline = b(.sendOfflinePacketAfterOnline, d.sendOfflinePacketAfterOnline)
        self.markReadAfterAction = b(.markReadAfterAction, d.markReadAfterAction)
        self.useScheduledMessages = b(.useScheduledMessages, d.useScheduledMessages)
        self.sendWithoutSound = AyuSendWithoutSoundOption(rawValue: i(.sendWithoutSound, d.sendWithoutSound.rawValue)) ?? d.sendWithoutSound
        self.suggestGhostModeBeforeViewingStory = b(.suggestGhostModeBeforeViewingStory, d.suggestGhostModeBeforeViewingStory)

        self.saveDeletedMessages = b(.saveDeletedMessages, d.saveDeletedMessages)
        self.saveMessagesHistory = b(.saveMessagesHistory, d.saveMessagesHistory)
        self.saveForBots = b(.saveForBots, d.saveForBots)
        self.saveDeletedMedia = b(.saveDeletedMedia, d.saveDeletedMedia)
        self.saveSelfDestructingMedia = b(.saveSelfDestructingMedia, d.saveSelfDestructingMedia)
        self.historyRetentionDays = i(.historyRetentionDays, d.historyRetentionDays)

        // The old default was a broom emoji; the icon replaces it now.
        let storedDeletedMark = s(.deletedMark, d.deletedMark)
        self.deletedMark = storedDeletedMark == "\u{1F9F9}" ? "" : storedDeletedMark
        self.showDeletedIcon = b(.showDeletedIcon, d.showDeletedIcon)
        self.showEditedIcon = b(.showEditedIcon, d.showEditedIcon)
        self.editedMark = s(.editedMark, d.editedMark)
        self.showDeletedMessages = b(.showDeletedMessages, d.showDeletedMessages)
        self.semiTransparentDeletedMessages = b(.semiTransparentDeletedMessages, d.semiTransparentDeletedMessages)
        self.showMessageSeconds = b(.showMessageSeconds, d.showMessageSeconds)
        self.showPeerId = AyuPeerIdDisplay(rawValue: i(.showPeerId, d.showPeerId.rawValue)) ?? d.showPeerId
        self.messageBubbleRadius = i(.messageBubbleRadius, d.messageBubbleRadius)
        self.avatarRoundness = max(0, min(50, i(.avatarRoundness, d.avatarRoundness)))
        self.hideAllChatsFolder = b(.hideAllChatsFolder, d.hideAllChatsFolder)
        self.disableStories = b(.disableStories, d.disableStories)
        self.disableAds = b(.disableAds, d.disableAds)
        self.hideNotificationCounters = b(.hideNotificationCounters, d.hideNotificationCounters)
        self.collapseSimilarChannels = b(.collapseSimilarChannels, d.collapseSimilarChannels)

        self.disableOpenLinkWarning = b(.disableOpenLinkWarning, d.disableOpenLinkWarning)
        self.disableGreetingSticker = b(.disableGreetingSticker, d.disableGreetingSticker)
        self.stickerConfirmation = b(.stickerConfirmation, d.stickerConfirmation)
        self.gifConfirmation = b(.gifConfirmation, d.gifConfirmation)
        self.voiceConfirmation = b(.voiceConfirmation, d.voiceConfirmation)
        self.roundConfirmation = b(.roundConfirmation, d.roundConfirmation)
        self.unlimitedRecentStickers = b(.unlimitedRecentStickers, d.unlimitedRecentStickers)
        self.localPremium = b(.localPremium, d.localPremium)
        self.localGifts = b(.localGifts, d.localGifts)

        self.keepUnreadOnNotificationOpen = b(.keepUnreadOnNotificationOpen, d.keepUnreadOnNotificationOpen)
        self.privacyScreenInAppSwitcher = b(.privacyScreenInAppSwitcher, d.privacyScreenInAppSwitcher)
        self.streamerMode = b(.streamerMode, d.streamerMode)
        self.lockMessageArchive = b(.lockMessageArchive, d.lockMessageArchive)

        self.deletedMessageOpacity = max(10, min(100, i(.deletedMessageOpacity, d.deletedMessageOpacity)))

        self.ghostModeActive = b(.ghostModeActive, d.ghostModeActive)
    }
}

public extension AyuSettingsData {
    /// Ghost mode is "on" exactly when every outgoing presence signal is muted.
    /// Derived rather than stored, so toggling an individual switch updates it.
    var isGhostModeEnabled: Bool {
        return !self.sendReadMessages
            && !self.sendOnlinePackets
            && !self.sendUploadProgress
            && !self.sendTypingStatus
            && !self.sendReadStories
    }

    mutating func setGhostMode(_ enabled: Bool) {
        self.sendReadMessages = !enabled
        self.sendOnlinePackets = !enabled
        self.sendUploadProgress = !enabled
        self.sendTypingStatus = !enabled
        self.sendReadStories = !enabled
        self.ghostModeActive = enabled
    }
}
