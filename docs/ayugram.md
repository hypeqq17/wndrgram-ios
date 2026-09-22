# WndrGram for iOS

User-facing name: **WndrGram** (display name in `Telegram/BUILD` and
`*.lproj/InfoPlist.strings`). Internal module names keep the `Ayu` prefix.
App icons are the AyuGram icon set, dropped into the existing `.alticon`
folders and `Telegram.icon` (single full-bleed layer).


A port of [AyuGram Desktop](https://github.com/AyuGram/AyuGramDesktop)'s behaviour
onto the Telegram-iOS codebase. There is no official AyuGram for iOS; this is a
fork that reimplements its features in Swift rather than reusing any of the
C++/Qt code.

## Modules

| Module | Purpose |
| --- | --- |
| `submodules/AyuGram/AyuSettings` | Settings model + process-wide store. Foundation and SwiftSignalKit only, so `TelegramCore` and `Postbox` can depend on it. |
| `submodules/AyuGram/AyuMessageArchive` | Append-only local archive of deleted messages and edit revisions. |
| `submodules/TelegramCore/Sources/AyuGram/` | Wiring: installs the Postbox hooks and the bot classifier. |
| `submodules/SettingsUI/Sources/AyuGramSettingsController.swift` | The AyuGram settings screen. |

`initializeAyuGram(containerPath:)` must run once per process, right after
`initializeAccountManagement()` and **before** any account loads — the Postbox
hooks have to be installed before the first sync pass, or messages deleted
during it are lost. It is called from `AppDelegate` and from the notification
service extension.

Settings live in `<appGroup>/telegram-data/ayugram-settings.json` and are shared
between the app and its extensions; changes are broadcast with a Darwin
notification so every process reloads.

## Ghost mode

Each outgoing presence signal is suppressed at its own source in `TelegramCore`,
so nothing is intercepted at the MTProto layer and no request is faked:

| Signal | Gate | File |
| --- | --- | --- |
| `account.updateStatus` | `sendOnlinePackets` | `State/ManagedAccountPresence.swift` |
| `messages.setTyping` (typing, recording, choosing sticker) | `sendTypingStatus` | `State/ManagedLocalInputActivities.swift` |
| `messages.setTyping` (upload progress) | `sendUploadProgress` | `State/ManagedLocalInputActivities.swift` |
| `messages.readHistory`, `channels.readHistory` | `sendReadMessages` | `State/SynchronizePeerReadState.swift` |
| `messages.readDiscussion`, `messages.readSavedHistory` | `sendReadMessages` | `TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift`, `ReplyThreadHistory.swift` |
| `messages.readReactions` | `sendReadMessages` | `State/ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations.swift` |
| `stories.readStories`, `stories.incrementStoryViews` | `sendReadStories` | `State/ManagedSynchronizeViewStoriesOperations.swift`, `TelegramEngine/Messages/Stories.swift` |

Two deliberate exceptions: marking a dialog **unread** still reaches the server
(it is an explicit user action, not a receipt), and `speakingInGroupCall` is
never suppressed because participation is already public and muting it only
breaks the call UI.

`sendOfflinePacketAfterOnline` is the one case where enabling ghost mode *sends*
something: a single `updateStatus(offline: true)`, so the server stops
advertising the user as online.

## Keeping deleted messages

Rather than rendering deleted messages from a side store, the fork keeps them in
Postbox. `PostboxMessageDeletionHook` (in `Postbox`, dependency-free) exposes
three seams that `TelegramCore` fills in:

- `willDelete` — archive the message before it goes.
- `filterDeletions` — return the subset that is actually deleted. AyuGram drops
  the id from that subset and instead stamps the message with
  `AyuDeletedMessageAttribute`, so it stays in the history, keeps its stable id,
  its media, and its place in search.
- `willUpdate` — capture the previous revision when a message's text changes.

The attribute is also what makes retention idempotent: a message that already
carries it is deleted for real on the next attempt, so the user can still remove
it from their own device.

Secret chats and non-cloud (local/pending) messages are never retained.

The parallel `AyuMessageArchive` still exists and holds the same records plus
edit revisions. It is what survives a "delete for everyone" the user performs
themselves, and what the settings screen reports the size of.

`PostboxMessageDeletionHook.swift` is picked up by Postbox's existing
`Sources/**/*.swift` glob and deliberately has no dependencies beyond
Foundation, so Postbox stays at the bottom of the module graph — and note that
Postbox builds with `-warnings-as-errors`.

## AyuGram menu

`SettingsUI/Sources/AyuMenuController.swift` is a Telegram-styled settings
list (theme colours, inset grouped sections) built from UIKit controls so it
can offer switches, sliders, segmented controls and text fields. It opens from
the "AyuGram" settings row and from tapping the Settings tab ten times (which
used to open Telegram's debug menu; that is now a button at the bottom).
Config also exports/imports the settings JSON via the clipboard.

Wired in this pass: deleted-message dimming with adjustable opacity
(`ChatMessageItemView.setupItem`), send-without-sound (`EnqueueMessage.swift`),
skip hidden-link warning (`SharedAccountContext`, `TextLinkHandling`), app
switcher blur and streamer mode (`TelegramUI/Sources/AyuPrivacyShield.swift`).
User-initiated deletions are exempt from in-chat retention
(`ayuPerformUserInitiatedDeletion`).

## Building

The build only runs on macOS. This tree came from a GitHub zip (upstream
commit `6ad963e5b62d354da79040f388ae2b9132fb17b8`) and has **empty submodule
folders**; `wndrgram-mac-build.sh` clones upstream at that commit with all
submodules, rsyncs this tree on top and builds with Telegram's test signing
(`build-system/fake-codesigning`, imported via `ImportCertificates.py`).
`--device` produces a test-signed `release_arm64` IPA meant to be re-signed
with Sideloadly/AltStore. The GitHub workflow does the same and uploads the IPA.

## Not yet ported

- Per-account ghost mode (currently one global setting).
- The deleted-message *filter* UI (AyuGram's per-chat filters / shadow bans).
- Message-shot, translation providers, custom app icons.
- Every `AyuSettingsData` field is now exposed and wired (see below).

Every option shown in `AyuMenuController` is wired: bubble radius writes
through to Telegram's own `chatBubbleSettings`; peer id is a row in
`PeerInfoProfileItems.infoItems`; send confirmations are
`ChatControllerImpl.ayuConfirmSend` (stickers, GIFs) and a forced preview in
`dismissMediaRecorder` (voice, round video); greeting sticker is
`ChatEmptyNode`; recent stickers limit is `ayuRecentStickersLimit`; keep
unread from notification is `AyuNotificationOpenState` +
`ChatControllerImpl.ayuSuppressReadHistory`; send-as-scheduled and
read-after-action are `ayuApplyScheduledSending` / `ayuReadAfterAction` in
`EnqueueMessage.swift`; counters are the tab badge (`ChatListController`), the
icon badge (`AppDelegate.resetBadge`) and `ayuNotificationBadge` in the
notification extension; similar channels are dropped in `ChatHistoryListNode`;
the story ghost prompt is `ChatListControllerImpl.openStories`; local premium
is `AccountContextImpl.isPremium`; avatar roundness is `ayuAvatarPath` in
`AvatarNode` (photos, letters, masks); the archive browser with optional
Face ID lock is `SettingsUI/Sources/AyuArchiveController.swift`.
