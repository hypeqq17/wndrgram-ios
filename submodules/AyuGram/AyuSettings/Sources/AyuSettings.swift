import Foundation
import SwiftSignalKit

/// Process-wide access point for AyuGram settings.
///
/// TelegramCore reads this from network queues on every outgoing presence
/// packet, so reads must be lock-free and cheap: the current value is kept in
/// an atomic snapshot and only writes take the serial queue.
public final class AyuSettings {
    public static let shared = AyuSettings()

    private let queue = Queue(name: "com.ayugram.settings")
    private let lock = NSLock()
    private var value: AyuSettingsData
    private let promise: ValuePromise<AyuSettingsData>
    private var storeURL: URL?
    private var darwinObserverInstalled = false

    private static let darwinNotificationName = "com.ayugram.settings.changed" as CFString

    private init() {
        let initial = AyuSettingsData()
        self.value = initial
        self.promise = ValuePromise<AyuSettingsData>(initial, ignoreRepeated: true)
    }

    /// Point the store at the shared app-group container so the main app, the
    /// notification service and the share extension all see the same settings.
    /// Safe to call more than once; the first call wins unless the path changes.
    public func configure(containerURL: URL) {
        let url = containerURL.appendingPathComponent("ayugram-settings.json")
        self.queue.sync {
            self.storeURL = url
            if let loaded = self.loadFromDisk(url: url) {
                self.setValueLocked(loaded, persist: false, notifyOtherProcesses: false)
            } else {
                // First launch with this container: seed it with the defaults.
                self.persist(self.currentValue, to: url)
            }
        }
        self.installDarwinObserverIfNeeded()
    }

    /// The current settings. Cheap enough to call on hot paths.
    public var currentValue: AyuSettingsData {
        self.lock.lock()
        let result = self.value
        self.lock.unlock()
        return result
    }

    /// Reactive stream of settings, delivering the current value immediately.
    public var signal: Signal<AyuSettingsData, NoError> {
        return self.promise.get()
    }

    public func update(_ modify: @escaping (inout AyuSettingsData) -> Void) {
        self.queue.async {
            var updated = self.currentValue
            modify(&updated)
            guard updated != self.currentValue else {
                return
            }
            self.setValueLocked(updated, persist: true, notifyOtherProcesses: true)
        }
    }

    public func setGhostMode(_ enabled: Bool) {
        self.update { settings in
            settings.setGhostMode(enabled)
        }
    }

    public func toggleGhostMode() {
        self.update { settings in
            settings.setGhostMode(!settings.isGhostModeEnabled)
        }
    }

    public func resetToDefaults() {
        self.queue.async {
            self.setValueLocked(AyuSettingsData(), persist: true, notifyOtherProcesses: true)
        }
    }

    // MARK: - Persistence

    private func setValueLocked(_ newValue: AyuSettingsData, persist: Bool, notifyOtherProcesses: Bool) {
        self.lock.lock()
        self.value = newValue
        self.lock.unlock()
        self.promise.set(newValue)

        if persist, let url = self.storeURL {
            self.persist(newValue, to: url)
        }
        if notifyOtherProcesses {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(AyuSettings.darwinNotificationName),
                nil,
                nil,
                true
            )
        }
    }

    private func loadFromDisk(url: URL) -> AyuSettingsData? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(AyuSettingsData.self, from: data)
    }

    private func persist(_ value: AyuSettingsData, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return
        }
        // Atomic write: a crash mid-write must not leave a truncated file that
        // would silently reset every setting on the next launch.
        try? data.write(to: url, options: .atomic)
    }

    private func reloadFromDisk() {
        self.queue.async {
            guard let url = self.storeURL, let loaded = self.loadFromDisk(url: url) else {
                return
            }
            guard loaded != self.currentValue else {
                return
            }
            self.setValueLocked(loaded, persist: false, notifyOtherProcesses: false)
        }
    }

    private func installDarwinObserverIfNeeded() {
        guard !self.darwinObserverInstalled else {
            return
        }
        self.darwinObserverInstalled = true
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else {
                    return
                }
                let settings = Unmanaged<AyuSettings>.fromOpaque(observer).takeUnretainedValue()
                settings.reloadFromDisk()
            },
            AyuSettings.darwinNotificationName,
            nil,
            .deliverImmediately
        )
    }
}

/// Convenience for the many call sites that only need one flag.
public extension AyuSettings {
    static var current: AyuSettingsData {
        return AyuSettings.shared.currentValue
    }
}
