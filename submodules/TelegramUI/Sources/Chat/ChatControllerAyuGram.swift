import Foundation
import UIKit
import Display
import TelegramCore
import Postbox
import PresentationDataUtils
import AccountContext

extension ChatControllerImpl {
    /// WndrGram's "confirm before sending" gate.
    ///
    /// Returns `true` when the caller should go ahead now. Otherwise an alert
    /// is shown and, if the user confirms, `perform` re-runs the original send
    /// with the gate bypassed.
    func ayuConfirmSend(enabled: Bool, text: String, perform: @escaping () -> Void) -> Bool {
        if !enabled || self.ayuSendConfirmationBypass {
            return true
        }
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        self.present(textAlertController(context: self.context, title: nil, text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: "Отправить", action: { [weak self] in
                guard let self else {
                    return
                }
                self.ayuSendConfirmationBypass = true
                perform()
                self.ayuSendConfirmationBypass = false
            })
        ]), in: .window(.root))
        return false
    }
}

/// Hands "this chat was opened from a notification" from the app delegate to
/// the chat controller that ends up showing it. Main thread only.
enum AyuNotificationOpenState {
    private static var pendingPeerId: PeerId?
    private static var pendingTimestamp: Double = 0.0

    static func markPending(peerId: PeerId) {
        self.pendingPeerId = peerId
        self.pendingTimestamp = CFAbsoluteTimeGetCurrent()
    }

    /// True once, for the first chat of that peer opened shortly after.
    static func consume(peerId: PeerId) -> Bool {
        guard let pending = self.pendingPeerId, pending == peerId else {
            return false
        }
        self.pendingPeerId = nil
        return CFAbsoluteTimeGetCurrent() - self.pendingTimestamp < 30.0
    }
}
