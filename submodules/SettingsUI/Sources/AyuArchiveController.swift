import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import LocalAuthentication
import TelegramCore
import TelegramPresentationData
import AccountContext
import LocalizedPeerData
import AyuSettings
import AyuMessageArchive

// Browser for WndrGram's local archive: deleted messages and edit history,
// grouped by chat. Optionally locked behind Face ID / passcode.

/// Opens the archive, asking for Face ID first when the lock is enabled.
public func presentAyuArchive(context: AccountContext, push: @escaping (ViewController) -> Void) {
    let open = {
        push(AyuArchiveController(context: context, peerId: nil))
    }
    guard AyuSettings.current.lockMessageArchive else {
        open()
        return
    }
    let authContext = LAContext()
    var error: NSError?
    guard authContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
        // No passcode on the device: nothing to lock with.
        open()
        return
    }
    authContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Доступ к архиву удалённых сообщений", reply: { success, _ in
        DispatchQueue.main.async {
            if success {
                open()
            }
        }
    })
}

private struct AyuArchivePeerRow {
    let peerId: EnginePeer.Id
    let title: String
    let deletedCount: Int
    let editedCount: Int
    let lastTimestamp: Int32
}

final class AyuArchiveController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    /// nil lists chats; otherwise lists the messages of that chat.
    private let peerId: EnginePeer.Id?

    private var presentationData: PresentationData
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()

    private var peerRows: [AyuArchivePeerRow] = []
    private var messages: [AyuArchivedMessage] = []
    private var titlesDisposable: Disposable?
    private var versionDisposable: Disposable?

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    init(context: AccountContext, peerId: EnginePeer.Id?, title: String? = nil) {
        self.context = context
        self.peerId = peerId
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData, style: .glass))

        self.title = title ?? "Архив сообщений"
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.titlesDisposable?.dispose()
        self.versionDisposable?.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNodeDidLoad()
    }

    override func displayNodeDidLoad() {
        super.displayNodeDidLoad()

        let theme = self.presentationData.theme.list
        self.displayNode.backgroundColor = theme.blocksBackgroundColor
        self.tableView.backgroundColor = theme.blocksBackgroundColor
        self.tableView.separatorColor = theme.itemBlocksSeparatorColor
        self.tableView.contentInsetAdjustmentBehavior = .never
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.displayNode.view.addSubview(self.tableView)

        self.emptyLabel.text = "Здесь пока пусто"
        self.emptyLabel.textColor = theme.freeTextColor
        self.emptyLabel.font = UIFont.systemFont(ofSize: 17.0)
        self.emptyLabel.textAlignment = .center
        self.displayNode.view.addSubview(self.emptyLabel)

        self.versionDisposable = (AyuMessageArchive.shared.version.get()
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.reload()
        })
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.tableView.frame = CGRect(origin: CGPoint(), size: layout.size)
        let insets = UIEdgeInsets(top: self.cleanNavigationHeight, left: 0.0, bottom: max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom), right: 0.0)
        if self.tableView.contentInset != insets {
            self.tableView.contentInset = insets
            self.tableView.verticalScrollIndicatorInsets = insets
            self.tableView.contentOffset = CGPoint(x: 0.0, y: -insets.top)
        }
        self.emptyLabel.frame = CGRect(x: 16.0, y: layout.size.height * 0.4, width: layout.size.width - 32.0, height: 24.0)
    }

    private func reload() {
        if let peerId = self.peerId {
            self.messages = AyuMessageArchive.shared.messages(peerId: peerId).sorted(by: { $0.archivedTimestamp > $1.archivedTimestamp })
            self.emptyLabel.isHidden = !self.messages.isEmpty
            self.tableView.reloadData()
            return
        }

        let peerIds = AyuMessageArchive.shared.archivedPeerIds()
        var rows: [AyuArchivePeerRow] = []
        for peerId in peerIds {
            let archived = AyuMessageArchive.shared.messages(peerId: peerId)
            if archived.isEmpty {
                continue
            }
            rows.append(AyuArchivePeerRow(
                peerId: peerId,
                title: "\(peerId.id._internalGetInt64Value())",
                deletedCount: archived.filter { $0.reason == .deleted }.count,
                editedCount: archived.filter { $0.reason == .edited }.count,
                lastTimestamp: archived.map(\.archivedTimestamp).max() ?? 0
            ))
        }
        rows.sort(by: { $0.lastTimestamp > $1.lastTimestamp })
        self.peerRows = rows
        self.emptyLabel.isHidden = !rows.isEmpty
        self.tableView.reloadData()

        self.titlesDisposable?.dispose()
        self.titlesDisposable = (self.context.engine.data.get(EngineDataMap(
            rows.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0.peerId) }
        ))
        |> deliverOnMainQueue).start(next: { [weak self] peers in
            guard let self else {
                return
            }
            self.peerRows = self.peerRows.map { row in
                guard let maybePeer = peers[row.peerId], let peer = maybePeer else {
                    return row
                }
                return AyuArchivePeerRow(peerId: row.peerId, title: peer.compactDisplayTitle, deletedCount: row.deletedCount, editedCount: row.editedCount, lastTimestamp: row.lastTimestamp)
            }
            self.tableView.reloadData()
        })
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.peerId == nil ? self.peerRows.count : self.messages.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if self.peerId == nil && !self.peerRows.isEmpty {
            return "Хранится только на этом устройстве. Смахните влево, чтобы удалить архив чата."
        }
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let theme = self.presentationData.theme.list
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = theme.itemBlocksBackgroundColor
        cell.textLabel?.textColor = theme.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = theme.itemSecondaryTextColor
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0

        if self.peerId == nil {
            let row = self.peerRows[indexPath.row]
            cell.textLabel?.text = row.title
            var parts: [String] = []
            if row.deletedCount > 0 {
                parts.append("удалено: \(row.deletedCount)")
            }
            if row.editedCount > 0 {
                parts.append("правок: \(row.editedCount)")
            }
            cell.detailTextLabel?.text = parts.joined(separator: " · ")
            cell.accessoryType = .disclosureIndicator
        } else {
            let message = self.messages[indexPath.row]
            var text = message.text
            if text.isEmpty {
                text = message.media.isEmpty ? "(пусто)" : "📎 Медиа"
            } else if !message.media.isEmpty {
                text = "📎 " + text
            }
            cell.textLabel?.text = text
            let kind = message.reason == .deleted ? "🗑 Удалено" : "✏️ Версия \(message.revision + 1)"
            let direction = message.isOutgoing ? "исходящее" : "входящее"
            let date = self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.timestamp)))
            cell.detailTextLabel?.text = "\(kind) · \(direction) · \(date)"
            cell.selectionStyle = .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard self.peerId == nil else {
            return
        }
        let row = self.peerRows[indexPath.row]
        (self.navigationController as? NavigationController)?.pushViewController(AyuArchiveController(context: self.context, peerId: row.peerId, title: row.title))
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard self.peerId == nil else {
            return nil
        }
        let row = self.peerRows[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: self.presentationData.strings.Common_Delete, handler: { _, _, completion in
            AyuMessageArchive.shared.clear(peerId: row.peerId)
            completion(true)
        })
        return UISwipeActionsConfiguration(actions: [action])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard self.peerId != nil else {
            return nil
        }
        let text = self.messages[indexPath.row].text
        guard !text.isEmpty else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { _ in
            return UIMenu(title: "", children: [
                UIAction(title: "Копировать", image: UIImage(systemName: "doc.on.doc"), handler: { _ in
                    UIPasteboard.general.string = text
                })
            ])
        })
    }
}
