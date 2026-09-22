import Foundation
import UIKit
import SwiftSignalKit
import UIKitRuntimeUtils
import AyuSettings

/// Implements WndrGram's two window-level privacy toggles:
///
/// - *Hide contents in app switcher*: a blur covers the window while the app
///   is inactive, so the snapshot iOS takes for the switcher shows nothing.
/// - *Streamer mode*: the root layer is marked capture-protected (the same
///   mechanism secret chats use for media), and a cover is shown while the
///   screen is being recorded or mirrored.
final class AyuPrivacyShield {
    private weak var window: UIWindow?
    private weak var protectedView: UIView?
    private var coverView: UIVisualEffectView?
    private var settingsDisposable: Disposable?
    private var observers: [NSObjectProtocol] = []
    private var isInactive = false
    private var currentSettings = AyuSettings.current
    private var appliedCaptureProtection = false

    init(window: UIWindow, protectedView: UIView) {
        self.window = window
        self.protectedView = protectedView

        self.settingsDisposable = (AyuSettings.shared.signal
        |> deliverOnMainQueue).start(next: { [weak self] settings in
            guard let self else {
                return
            }
            self.currentSettings = settings
            self.update()
        })

        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.update()
        }))
    }

    deinit {
        self.settingsDisposable?.dispose()
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applicationWillResignActive() {
        self.isInactive = true
        self.update()
    }

    func applicationDidBecomeActive() {
        self.isInactive = false
        self.update()
    }

    private func update() {
        let settings = self.currentSettings

        if let protectedView = self.protectedView, self.appliedCaptureProtection != settings.streamerMode {
            self.appliedCaptureProtection = settings.streamerMode
            setLayerDisableScreenshots(protectedView.layer, settings.streamerMode)
        }

        var showCover = false
        if settings.privacyScreenInAppSwitcher && self.isInactive {
            showCover = true
        }
        if settings.streamerMode && UIScreen.main.isCaptured {
            showCover = true
        }
        self.setCoverVisible(showCover)
    }

    private func setCoverVisible(_ visible: Bool) {
        guard let window = self.window else {
            return
        }
        if visible {
            if self.coverView == nil {
                let coverView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
                coverView.frame = window.bounds
                coverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

                let label = UILabel()
                label.text = "WndrGram"
                label.font = UIFont.systemFont(ofSize: 28.0, weight: .bold)
                label.textColor = UIColor.label.withAlphaComponent(0.6)
                label.sizeToFit()
                label.center = CGPoint(x: coverView.bounds.midX, y: coverView.bounds.midY)
                label.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
                coverView.contentView.addSubview(label)

                self.coverView = coverView
            }
            if let coverView = self.coverView, coverView.superview !== window {
                coverView.frame = window.bounds
                window.addSubview(coverView)
            }
            if let coverView = self.coverView {
                window.bringSubviewToFront(coverView)
            }
        } else if let coverView = self.coverView {
            coverView.removeFromSuperview()
        }
    }
}
