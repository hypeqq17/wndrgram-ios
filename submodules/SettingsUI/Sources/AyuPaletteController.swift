import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AyuSettings

// WndrGram palette editor: every colour of the active theme in one list,
// each one replaceable with a colour picker. Overrides live in AyuSettings
// and are applied on top of whatever theme is selected.

private let ayuPaletteSectionTitles: [String: String] = [
    "intro": "Экран входа",
    "passcode": "Код-пароль",
    "rootController": "Панели и вкладки",
    "list": "Списки и настройки",
    "chatList": "Список чатов",
    "chat": "Чат",
    "actionSheet": "Меню действий",
    "contextMenu": "Контекстное меню",
    "inAppNotification": "Уведомления в приложении",
    "chart": "Графики"
]

private struct AyuPaletteSection {
    let key: String
    let title: String
    var entries: [AyuThemeColorEntry]
}

private func ayuColor(fromHex hex: String) -> UIColor {
    let value = UInt32(hex, radix: 16) ?? 0
    let a = CGFloat((value >> 24) & 0xff) / 255.0
    let r = CGFloat((value >> 16) & 0xff) / 255.0
    let g = CGFloat((value >> 8) & 0xff) / 255.0
    let b = CGFloat(value & 0xff) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
}

private func ayuHex(from color: UIColor) -> String {
    var r: CGFloat = 0.0, g: CGFloat = 0.0, b: CGFloat = 0.0, a: CGFloat = 0.0
    if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
        var white: CGFloat = 0.0
        color.getWhite(&white, alpha: &a)
        r = white
        g = white
        b = white
    }
    func c(_ v: CGFloat) -> UInt32 {
        return UInt32(max(0.0, min(1.0, v)) * 255.0 + 0.5)
    }
    return String(format: "%08x", (c(a) << 24) | (c(r) << 16) | (c(g) << 8) | c(b))
}

final class AyuPaletteController: ViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let context: AccountContext
    private var presentationData: PresentationData
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchBar = UISearchBar()

    private var allSections: [AyuPaletteSection] = []
    private var sections: [AyuPaletteSection] = []
    private var query: String = ""
    private var editingPath: String?
    private var presentationDataDisposable: Disposable?

    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData, style: .glass))

        self.title = "Палитра"
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Ещё", style: .plain, target: self, action: #selector(self.morePressed))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNodeDidLoad()
    }

    override func displayNodeDidLoad() {
        super.displayNodeDidLoad()

        self.tableView.contentInsetAdjustmentBehavior = .never
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.keyboardDismissMode = .onDrag
        self.displayNode.view.addSubview(self.tableView)

        self.searchBar.placeholder = "Поиск цвета (bubble, text, accent…)"
        self.searchBar.searchBarStyle = .minimal
        self.searchBar.delegate = self
        self.searchBar.autocapitalizationType = .none
        self.searchBar.autocorrectionType = .no
        self.searchBar.sizeToFit()
        self.tableView.tableHeaderView = self.searchBar

        self.applyTheme()
        self.reload()

        self.presentationDataDisposable = (self.context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            guard let self else {
                return
            }
            self.presentationData = presentationData
            self.applyTheme()
            self.reload()
            if let error = ayuThemeOverrideLastError {
                ayuThemeOverrideLastError = nil
                let alert = UIAlertController(title: "Цвет не применился", message: error, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.view.window?.rootViewController?.present(alert, animated: true)
            }
        })
    }

    private func applyTheme() {
        let theme = self.presentationData.theme.list
        self.displayNode.backgroundColor = theme.blocksBackgroundColor
        self.tableView.backgroundColor = theme.blocksBackgroundColor
        self.tableView.separatorColor = theme.itemBlocksSeparatorColor
        self.searchBar.tintColor = theme.itemAccentColor
        self.searchBar.searchTextField.textColor = theme.itemPrimaryTextColor
    }

    private func reload() {
        var byKey: [String: AyuPaletteSection] = [:]
        var order: [String] = []
        for entry in ayuThemeColorEntries(self.presentationData.theme) {
            let key = entry.path.components(separatedBy: ".").first ?? entry.path
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = AyuPaletteSection(key: key, title: ayuPaletteSectionTitles[key] ?? key, entries: [])
            }
            byKey[key]?.entries.append(entry)
        }
        self.allSections = order.compactMap { byKey[$0] }
        self.applyFilter()
    }

    private func applyFilter() {
        let query = self.query.lowercased()
        if query.isEmpty {
            self.sections = self.allSections
        } else {
            self.sections = self.allSections.compactMap { section in
                var section = section
                section.entries = section.entries.filter { $0.path.lowercased().contains(query) || section.title.lowercased().contains(query) }
                return section.entries.isEmpty ? nil : section
            }
        }
        self.tableView.reloadData()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.tableView.frame = CGRect(origin: CGPoint(), size: layout.size)
        let insets = UIEdgeInsets(top: self.cleanNavigationHeight, left: 0.0, bottom: max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom) + (layout.inputHeight ?? 0.0), right: 0.0)
        if self.tableView.contentInset != insets {
            let initial = self.tableView.contentInset.top == 0.0
            self.tableView.contentInset = insets
            self.tableView.scrollIndicatorInsets = insets
            if initial {
                self.tableView.contentOffset = CGPoint(x: 0.0, y: -insets.top)
            }
        }
    }

    // MARK: Search

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.query = searchText
        self.applyFilter()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int {
        return self.sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.sections[section].entries.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return self.sections[section].title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "c")
        let theme = self.presentationData.theme.list
        let entry = self.sections[indexPath.section].entries[indexPath.row]
        let isOverridden = AyuSettings.current.themeOverrides[entry.path] != nil

        var components = entry.path.components(separatedBy: ".")
        if components.count > 1 {
            components.removeFirst()
        }
        cell.backgroundColor = theme.itemBlocksBackgroundColor
        cell.textLabel?.text = components.joined(separator: " › ")
        cell.textLabel?.textColor = theme.itemPrimaryTextColor
        cell.textLabel?.font = UIFont.systemFont(ofSize: 15.0)
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.text = "#" + entry.value.uppercased() + (isOverridden ? "  •  изменён" : "")
        cell.detailTextLabel?.textColor = isOverridden ? theme.itemAccentColor : theme.itemSecondaryTextColor
        cell.detailTextLabel?.font = UIFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .regular)

        let swatch = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 30.0, height: 30.0))
        swatch.backgroundColor = ayuColor(fromHex: entry.value)
        swatch.layer.cornerRadius = 8.0
        swatch.layer.borderWidth = 1.0
        swatch.layer.borderColor = theme.itemBlocksSeparatorColor.cgColor
        cell.accessoryView = swatch
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = self.sections[indexPath.section].entries[indexPath.row]
        self.editingPath = entry.path
        if #available(iOS 14.0, *) {
            let picker = UIColorPickerViewController()
            picker.title = entry.path
            picker.supportsAlpha = true
            picker.selectedColor = ayuColor(fromHex: entry.value)
            let delegate = AyuPalettePickerDelegate(onColor: { [weak self] color in
                guard let self, let path = self.editingPath else {
                    return
                }
                let hex = ayuHex(from: color)
                AyuSettings.shared.update { $0.themeOverrides[path] = hex }
            })
            self.pickerDelegate = delegate
            picker.delegate = delegate
            self.view.window?.rootViewController?.present(picker, animated: true)
        } else {
            self.askHex(for: entry)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let entry = self.sections[indexPath.section].entries[indexPath.row]
        var actions: [UIContextualAction] = []
        if AyuSettings.current.themeOverrides[entry.path] != nil {
            actions.append(UIContextualAction(style: .destructive, title: "Сбросить", handler: { _, _, done in
                AyuSettings.shared.update { $0.themeOverrides[entry.path] = nil }
                done(true)
            }))
        }
        actions.append(UIContextualAction(style: .normal, title: "HEX", handler: { [weak self] _, _, done in
            self?.askHex(for: entry)
            done(true)
        }))
        return UISwipeActionsConfiguration(actions: actions)
    }

    // MARK: Editing

    private var pickerDelegate: AnyObject?

    private func askHex(for entry: AyuThemeColorEntry) {
        let alert = UIAlertController(title: entry.path, message: "RRGGBB или AARRGGBB", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = entry.value.uppercased()
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Готово", style: .default, handler: { _ in
            var text = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if text.hasPrefix("#") {
                text.removeFirst()
            }
            if text.count == 6 {
                text = "ff" + text
            }
            guard text.count == 8, UInt32(text, radix: 16) != nil else {
                return
            }
            AyuSettings.shared.update { $0.themeOverrides[entry.path] = text }
        }))
        self.view.window?.rootViewController?.present(alert, animated: true)
    }

    @objc private func morePressed() {
        let sheet = UIAlertController(title: "Палитра", message: "Изменено цветов: \(AyuSettings.current.themeOverrides.count)", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Скопировать палитру", style: .default, handler: { _ in
            let overrides = AyuSettings.current.themeOverrides
            if let data = try? JSONSerialization.data(withJSONObject: overrides, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
                UIPasteboard.general.string = "wndrgram-palette:" + text
            }
        }))
        sheet.addAction(UIAlertAction(title: "Вставить палитру из буфера", style: .default, handler: { _ in
            guard var text = UIPasteboard.general.string else {
                return
            }
            if text.hasPrefix("wndrgram-palette:") {
                text.removeFirst("wndrgram-palette:".count)
            }
            guard let data = text.data(using: .utf8), let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
                return
            }
            AyuSettings.shared.update { $0.themeOverrides = dict }
        }))
        sheet.addAction(UIAlertAction(title: "Сбросить все цвета", style: .destructive, handler: { _ in
            AyuSettings.shared.update { $0.themeOverrides = [:] }
        }))
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = self.view
            popover.sourceRect = CGRect(x: self.view.bounds.maxX - 40.0, y: 60.0, width: 1.0, height: 1.0)
        }
        self.view.window?.rootViewController?.present(sheet, animated: true)
    }
}

@available(iOS 14.0, *)
private final class AyuPalettePickerDelegate: NSObject, UIColorPickerViewControllerDelegate {
    private let onColor: (UIColor) -> Void

    init(onColor: @escaping (UIColor) -> Void) {
        self.onColor = onColor
    }

    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        self.onColor(viewController.selectedColor)
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        self.onColor(viewController.selectedColor)
    }
}
