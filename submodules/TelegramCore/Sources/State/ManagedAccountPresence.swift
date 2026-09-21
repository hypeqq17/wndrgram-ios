import Foundation
import TelegramApi
import Postbox
import SwiftSignalKit
import MtProtoKit
import AyuSettings

private typealias SignalKitTimer = SwiftSignalKit.Timer


private final class AccountPresenceManagerImpl {
    private let queue: Queue
    private let network: Network
    let isPerformingUpdate = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    private var shouldKeepOnlinePresenceDisposable: Disposable?
    private var ghostModeDisposable: Disposable?
    private let currentRequestDisposable = MetaDisposable()
    private var onlineTimer: SignalKitTimer?
    
    private var wasOnline: Bool = false
    
    init(queue: Queue, shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        self.queue = queue
        self.network = network
        
        self.shouldKeepOnlinePresenceDisposable = (shouldKeepOnlinePresence
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let `self` = self else {
                return
            }
            if self.wasOnline != value {
                self.wasOnline = value
                self.updatePresence(value)
            }
        })

        // Enabling ghost mode while already online has to take effect at once,
        // otherwise the server keeps reporting the user online for a minute.
        self.ghostModeDisposable = (AyuSettings.shared.signal
        |> map { $0.sendOnlinePackets }
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] sendOnlinePackets in
            guard let strongSelf = self else {
                return
            }
            if !sendOnlinePackets && strongSelf.wasOnline {
                strongSelf.updatePresence(false)
            } else if sendOnlinePackets && strongSelf.wasOnline {
                strongSelf.updatePresence(true)
            }
        })
    }

    deinit {
        assert(self.queue.isCurrent())
        self.ghostModeDisposable?.dispose()
        self.shouldKeepOnlinePresenceDisposable?.dispose()
        self.currentRequestDisposable.dispose()
        self.onlineTimer?.invalidate()
    }
    
    private func updatePresence(_ isOnline: Bool) {
        let settings = AyuSettings.current
        if !settings.sendOnlinePackets {
            // Ghost mode: never announce presence. Stop the keep-alive timer so
            // a previously scheduled refresh cannot leak an online packet.
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            if isOnline {
                return
            }
            if !settings.sendOfflinePacketAfterOnline {
                return
            }
            // Fall through: the user asked for a single offline packet so the
            // server stops reporting them as online.
        }

        let request: Signal<Api.Bool, MTRpcError>
        if isOnline {
            let timer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updatePresence(true)
            }, queue: self.queue)
            self.onlineTimer = timer
            timer.start()
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolFalse))
        } else {
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        }
        self.isPerformingUpdate.set(true)
        self.currentRequestDisposable.set((request
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> deliverOn(self.queue)).start(completed: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isPerformingUpdate.set(false)
        }))
    }
}

final class AccountPresenceManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountPresenceManagerImpl>
    
    init(shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: self.queue, generate: {
            return AccountPresenceManagerImpl(queue: queue, shouldKeepOnlinePresence: shouldKeepOnlinePresence, network: network)
        })
    }
    
    func isPerformingUpdate() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isPerformingUpdate.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
}
