import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import TelegramUIPreferences
import AyuSettings
import AyuMessageArchive

// The WndrGram settings screen, opened from the "WndrGram" settings row and by
// tapping the Settings tab ten times.
//
// It looks like any other Telegram settings list (theme colours, inset grouped
// sections, headers and footers) but is built from plain UIKit controls,
// because it needs sliders, text fields and segmented controls that the
// ItemList framework does not offer.

private let ayuMenuHaptic = HapticFeedback()

private struct AyuMenuPalette {
    let accent: UIColor
    let background: UIColor
    let card: UIColor
    let separator: UIColor
    let text: UIColor
    let secondaryText: UIColor
    let sectionHeader: UIColor
    let destructive: UIColor

    init(theme: PresentationTheme) {
        let list = theme.list
        self.accent = list.itemAccentColor
        self.background = list.blocksBackgroundColor
        self.card = list.itemBlocksBackgroundColor
        self.separator = list.itemBlocksSeparatorColor
        self.text = list.itemPrimaryTextColor
        self.secondaryText = list.freeTextColor
        self.sectionHeader = list.sectionHeaderTextColor
        self.destructive = list.itemDestructiveColor
    }
}

private enum AyuMenuRow {
    case toggle(title: String, subtitle: String?, get: (AyuSettingsData) -> Bool, set: (inout AyuSettingsData, Bool) -> Void)
    case slider(title: String, range: ClosedRange<Float>, step: Float, format: (Float) -> String, get: (AyuSettingsData) -> Float, set: (inout AyuSettingsData, Float) -> Void)
    case segmented(title: String, options: [String], get: (AyuSettingsData) -> Int, set: (inout AyuSettingsData, Int) -> Void)
    case text(title: String, placeholder: String, get: (AyuSettingsData) -> String, set: (inout AyuSettingsData, String) -> Void)
    case info(title: String, value: () -> String)
    case color(title: String, get: (AyuSettingsData) -> Int32, set: (inout AyuSettingsData, Int32) -> Void)
    case button(title: String, destructive: Bool, action: () -> Void)
}

private struct AyuMenuGroup {
    let title: String
    let footer: String?
    let rows: [AyuMenuRow]
}

public final class AyuMenuController: ViewController {
    private let context: AccountContext
    private let openDebugMenu: (() -> Void)?

    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    private var settings = AyuSettings.current
    private var settingsDisposable: Disposable?
    private var archiveDisposable: Disposable?

    private var groups: [AyuMenuGroup] = []

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    /// Pushes the current settings into the visible controls without
    /// rebuilding them, so a slider being dragged is not torn down.
    private var refreshers: [(AyuSettingsData) -> Void] = []

    public init(context: AccountContext, openDebugMenu: (() -> Void)?) {
        self.context = context
        self.openDebugMenu = openDebugMenu
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData, style: .glass))

        self.title = "WndrGram"
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        self.groups = self.makeGroups()

        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            guard let self else {
                return
            }
            let previousTheme = self.presentationData.theme
            self.presentationData = presentationData
            if previousTheme !== presentationData.theme {
                self.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
                self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: presentationData, style: .glass), transition: .immediate)
                if self.isNodeLoaded {
                    self.rebuild()
                }
            }
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
        self.settingsDisposable?.dispose()
        self.archiveDisposable?.dispose()
    }

    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        self.displayNodeDidLoad()
    }

    override public func displayNodeDidLoad() {
        super.displayNodeDidLoad()

        self.scrollView.alwaysBounceVertical = true
        self.scrollView.keyboardDismissMode = .interactive
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.displayNode.view.addSubview(self.scrollView)

        self.contentStack.axis = .vertical
        self.contentStack.spacing = 8.0
        self.contentStack.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.addSubview(self.contentStack)
        NSLayoutConstraint.activate([
            self.contentStack.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor),
            self.contentStack.leadingAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.leadingAnchor, constant: 16.0),
            self.contentStack.trailingAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.trailingAnchor, constant: -16.0),
            self.contentStack.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor)
        ])

        self.rebuild()

        self.settingsDisposable = (AyuSettings.shared.signal
        |> deliverOnMainQueue).start(next: { [weak self] settings in
            guard let self else {
                return
            }
            let previous = self.settings
            self.settings = settings
            if previous.messageBubbleRadius != settings.messageBubbleRadius {
                self.applyBubbleRadius(settings.messageBubbleRadius)
            }
            self.refreshValues()
        })
        self.archiveDisposable = (AyuMessageArchive.shared.version.get()
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.refreshValues()
        })
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        self.scrollView.frame = CGRect(origin: CGPoint(), size: layout.size)
        let bottomInset = max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom) + (layout.inputHeight ?? 0.0) + 24.0
        let insets = UIEdgeInsets(top: self.cleanNavigationHeight + 12.0, left: layout.safeInsets.left, bottom: bottomInset, right: layout.safeInsets.right)
        if self.scrollView.contentInset != insets {
            let wasAtTop = self.scrollView.contentOffset.y <= -self.scrollView.contentInset.top + 1.0
            self.scrollView.contentInset = insets
            self.scrollView.verticalScrollIndicatorInsets = insets
            if wasAtTop {
                self.scrollView.contentOffset = CGPoint(x: 0.0, y: -insets.top)
            }
        }
    }

    /// Recreates every row. Runs on load and on theme changes only.
    private func rebuild() {
        let palette = AyuMenuPalette(theme: self.presentationData.theme)
        self.displayNode.backgroundColor = palette.background
        self.scrollView.backgroundColor = palette.background

        for view in self.contentStack.arrangedSubviews {
            view.removeFromSuperview()
        }
        self.refreshers.removeAll()

        self.contentStack.addArrangedSubview(self.makeGhostHero(palette: palette))
        for group in self.groups {
            let groupView = self.makeGroup(group, palette: palette)
            self.contentStack.addArrangedSubview(groupView)
            self.contentStack.setCustomSpacing(24.0, after: groupView)
        }

        self.refreshValues()
    }

    private func refreshValues() {
        for refresh in self.refreshers {
            refresh(self.settings)
        }
    }

    // MARK: - Building blocks

    /// Big ghost-mode switch at the top: the setting people toggle most.
    private func makeGhostHero(palette: AyuMenuPalette) -> UIView {
        let card = UIView()
        card.backgroundColor = palette.card
        card.layer.cornerRadius = 26.0
        card.layer.cornerCurve = .continuous

        let iconBackground = UIView()
        iconBackground.layer.cornerRadius = 12.0
        iconBackground.layer.cornerCurve = .continuous
        let icon = UIImageView(image: UIImage(systemName: "eye.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.0, weight: .semibold)))
        icon.tintColor = .white
        icon.contentMode = .center

        let title = UILabel()
        title.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        title.textColor = palette.text
        title.text = "Режим призрака"
        let subtitle = UILabel()
        subtitle.font = UIFont.systemFont(ofSize: 13.0)
        subtitle.textColor = palette.secondaryText
        subtitle.numberOfLines = 0

        let toggle = UISwitch()
        toggle.onTintColor = palette.accent
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.ayuOn(.valueChanged) { [weak toggle] in
            guard let toggle else {
                return
            }
            ayuMenuHaptic.impact()
            AyuSettings.shared.setGhostMode(toggle.isOn)
        }

        for view in [iconBackground, icon, title, subtitle, toggle] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16.0),
            iconBackground.topAnchor.constraint(equalTo: card.topAnchor, constant: 16.0),
            iconBackground.widthAnchor.constraint(equalToConstant: 44.0),
            iconBackground.heightAnchor.constraint(equalToConstant: 44.0),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: 12.0),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 16.0),
            title.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8.0),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2.0),
            subtitle.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8.0),
            subtitle.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -16.0),
            card.bottomAnchor.constraint(greaterThanOrEqualTo: iconBackground.bottomAnchor, constant: 16.0),

            toggle.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16.0)
        ])

        self.refreshers.append { settings in
            let enabled = settings.isGhostModeEnabled
            if toggle.isOn != enabled {
                toggle.setOn(enabled, animated: true)
            }
            UIView.animate(withDuration: 0.2, animations: {
                iconBackground.backgroundColor = enabled ? palette.accent : palette.secondaryText
            })
            subtitle.text = enabled
                ? "Включён: прочтения, онлайн и «печатает» не отправляются"
                : "Выключен"
        }

        let wrapper = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: wrapper.topAnchor),
            card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -16.0)
        ])
        return wrapper
    }

    private func makeInsetLabel(_ label: UILabel) -> UIView {
        let wrapper = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrapper.topAnchor),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16.0),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -16.0)
        ])
        return wrapper
    }

    private func makeGroup(_ group: AyuMenuGroup, palette: AyuMenuPalette) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 7.0

        let header = UILabel()
        header.text = group.title.uppercased()
        header.font = UIFont.systemFont(ofSize: 13.0)
        header.textColor = palette.sectionHeader
        container.addArrangedSubview(self.makeInsetLabel(header))

        let card = UIStackView()
        card.axis = .vertical
        card.backgroundColor = palette.card
        card.layer.cornerRadius = 26.0
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        for (index, row) in group.rows.enumerated() {
            if index != 0 {
                let separatorWrapper = UIView()
                let separator = UIView()
                separator.backgroundColor = palette.separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separatorWrapper.addSubview(separator)
                NSLayoutConstraint.activate([
                    separatorWrapper.heightAnchor.constraint(equalToConstant: UIScreenPixel),
                    separator.topAnchor.constraint(equalTo: separatorWrapper.topAnchor),
                    separator.bottomAnchor.constraint(equalTo: separatorWrapper.bottomAnchor),
                    separator.leadingAnchor.constraint(equalTo: separatorWrapper.leadingAnchor, constant: 16.0),
                    separator.trailingAnchor.constraint(equalTo: separatorWrapper.trailingAnchor)
                ])
                card.addArrangedSubview(separatorWrapper)
            }
            card.addArrangedSubview(self.makeRow(row, palette: palette))
        }
        container.addArrangedSubview(card)

        if let footer = group.footer {
            let label = UILabel()
            label.text = footer
            label.numberOfLines = 0
            label.font = UIFont.systemFont(ofSize: 13.0)
            label.textColor = palette.secondaryText
            container.addArrangedSubview(self.makeInsetLabel(label))
        }
        return container
    }

    private func makeTitleLabel(_ text: String, palette: AyuMenuPalette) -> UIView {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 17.0)
        label.textColor = palette.text
        return self.withIcon(text, label)
    }

    /// Puts the row's coloured icon tile in front of `content`, like the
    /// rows of the iOS and Telegram settings screens.
    private func withIcon(_ title: String, _ content: UIView) -> UIView {
        guard let icon = ayuMenuIcons[title], let image = UIImage(systemName: icon.0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)) else {
            return content
        }
        let tile = UIView()
        tile.backgroundColor = UIColor(rgb: icon.1)
        tile.layer.cornerRadius = 7.0
        tile.layer.cornerCurve = .continuous
        let imageView = UIImageView(image: image)
        imageView.tintColor = .white
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(imageView)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 29.0),
            tile.heightAnchor.constraint(equalToConstant: 29.0),
            imageView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        let stack = UIStackView(arrangedSubviews: [tile, content])
        stack.alignment = .center
        stack.spacing = 12.0
        return stack
    }

    private func padded(_ content: UIView, vertical: CGFloat = 11.0) -> UIView {
        let wrapper = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -vertical),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16.0),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -16.0),
            wrapper.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0)
        ])
        return wrapper
    }

    private func makeRow(_ row: AyuMenuRow, palette: AyuMenuPalette) -> UIView {
        switch row {
        case let .toggle(title, subtitle, get, set):
            let texts = UIStackView(arrangedSubviews: [self.makeTitleLabel(title, palette: palette)])
            texts.axis = .vertical
            texts.spacing = 2.0
            if let subtitle {
                let label = UILabel()
                label.text = subtitle
                label.numberOfLines = 0
                label.font = UIFont.systemFont(ofSize: 13.0)
                label.textColor = palette.secondaryText
                texts.addArrangedSubview(label)
            }
            let toggle = UISwitch()
            toggle.onTintColor = palette.accent
            toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
            toggle.ayuOn(.valueChanged) { [weak toggle] in
                guard let toggle else {
                    return
                }
                ayuMenuHaptic.tap()
                let value = toggle.isOn
                AyuSettings.shared.update { settings in
                    set(&settings, value)
                }
            }
            let stack = UIStackView(arrangedSubviews: [texts, toggle])
            stack.alignment = .center
            stack.spacing = 12.0
            self.refreshers.append { settings in
                let value = get(settings)
                if toggle.isOn != value {
                    toggle.setOn(value, animated: true)
                }
            }
            return self.padded(stack)

        case let .slider(title, range, step, format, get, set):
            let valueLabel = UILabel()
            valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 17.0, weight: .regular)
            valueLabel.textColor = palette.secondaryText
            valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            let top = UIStackView(arrangedSubviews: [self.makeTitleLabel(title, palette: palette), valueLabel])
            top.spacing = 8.0

            let slider = UISlider()
            slider.minimumValue = range.lowerBound
            slider.maximumValue = range.upperBound
            slider.minimumTrackTintColor = palette.accent
            slider.maximumTrackTintColor = palette.separator
            slider.isContinuous = true
            var isDragging = false
            slider.ayuOn(.valueChanged) { [weak slider, weak valueLabel] in
                guard let slider else {
                    return
                }
                isDragging = true
                let snapped = (slider.value / step).rounded() * step
                valueLabel?.text = format(snapped)
            }
            slider.ayuOn([.touchUpInside, .touchUpOutside, .touchCancel]) { [weak slider] in
                guard let slider else {
                    return
                }
                isDragging = false
                let snapped = (slider.value / step).rounded() * step
                slider.setValue(snapped, animated: true)
                ayuMenuHaptic.tap()
                AyuSettings.shared.update { settings in
                    set(&settings, snapped)
                }
            }

            let stack = UIStackView(arrangedSubviews: [top, slider])
            stack.axis = .vertical
            stack.spacing = 8.0
            self.refreshers.append { settings in
                if isDragging {
                    return
                }
                let value = get(settings)
                slider.value = value
                valueLabel.text = format(value)
            }
            return self.padded(stack)

        case let .segmented(title, options, get, set):
            let control = UISegmentedControl(items: options)
            control.ayuOn(.valueChanged) { [weak control] in
                guard let control else {
                    return
                }
                ayuMenuHaptic.tap()
                let index = control.selectedSegmentIndex
                AyuSettings.shared.update { settings in
                    set(&settings, index)
                }
            }
            let stack = UIStackView(arrangedSubviews: [self.makeTitleLabel(title, palette: palette), control])
            stack.axis = .vertical
            stack.spacing = 10.0
            self.refreshers.append { settings in
                let index = get(settings)
                if control.selectedSegmentIndex != index {
                    control.selectedSegmentIndex = index
                }
            }
            return self.padded(stack)

        case let .text(title, placeholder, get, set):
            let field = UITextField()
            field.textColor = palette.secondaryText
            field.tintColor = palette.accent
            field.font = UIFont.systemFont(ofSize: 17.0)
            field.textAlignment = .right
            field.returnKeyType = .done
            field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: palette.secondaryText.withAlphaComponent(0.5)])
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 80.0).isActive = true
            field.ayuOn(.editingChanged) { [weak field] in
                let value = field?.text ?? ""
                AyuSettings.shared.update { settings in
                    set(&settings, value)
                }
            }
            field.ayuOn(.editingDidEndOnExit) { [weak field] in
                field?.resignFirstResponder()
            }
            let stack = UIStackView(arrangedSubviews: [self.makeTitleLabel(title, palette: palette), field])
            stack.alignment = .center
            stack.spacing = 12.0
            self.refreshers.append { settings in
                if !field.isFirstResponder {
                    field.text = get(settings)
                }
            }
            return self.padded(stack)

        case let .color(title, get, set):
            let presets: [Int32] = [0x8B5CF6, 0x007AFF, 0x34C759, 0xFF3B30, 0xFF9500, 0xFF2D55, 0x30B0C7, 0xFFD60A, 0xFFFFFF, 0x000000]
            let swatches = UIStackView()
            swatches.spacing = 6.0
            swatches.distribution = .fillEqually
            var buttons: [(UIButton, Int32)] = []
            for preset in presets {
                let button = UIButton(type: .custom)
                button.backgroundColor = UIColor(rgb: UInt32(bitPattern: preset))
                button.layer.cornerRadius = 13.0
                button.layer.borderColor = palette.separator.cgColor
                button.layer.borderWidth = 1.0
                button.heightAnchor.constraint(equalToConstant: 26.0).isActive = true
                button.ayuOn(.touchUpInside) {
                    ayuMenuHaptic.tap()
                    AyuSettings.shared.update { settings in
                        set(&settings, preset)
                    }
                }
                swatches.addArrangedSubview(button)
                buttons.append((button, preset))
            }
            let stack = UIStackView(arrangedSubviews: [self.makeTitleLabel(title, palette: palette), swatches])
            stack.axis = .vertical
            stack.spacing = 10.0
            if #available(iOS 14.0, *) {
                let well = UIColorWell()
                well.supportsAlpha = false
                well.addTarget(self, action: #selector(self.ayuColorWellChanged(_:)), for: .valueChanged)
                self.colorWellSetters[ObjectIdentifier(well)] = { value in
                    AyuSettings.shared.update { settings in
                        set(&settings, value)
                    }
                }
                let customRow = UIStackView(arrangedSubviews: [self.makeTitleLabel("Свой цвет", palette: palette), well])
                customRow.spacing = 12.0
                customRow.alignment = .center
                stack.addArrangedSubview(customRow)
                self.refreshers.append { settings in
                    well.selectedColor = UIColor(rgb: UInt32(bitPattern: get(settings)))
                }
            }
            self.refreshers.append { settings in
                let current = get(settings)
                for (button, preset) in buttons {
                    button.layer.borderWidth = preset == current ? 3.0 : 1.0
                    button.layer.borderColor = preset == current ? palette.accent.cgColor : palette.separator.cgColor
                }
            }
            return self.padded(stack)

        case let .info(title, value):
            let valueLabel = UILabel()
            valueLabel.font = UIFont.systemFont(ofSize: 17.0)
            valueLabel.textColor = palette.secondaryText
            valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            let stack = UIStackView(arrangedSubviews: [self.makeTitleLabel(title, palette: palette), valueLabel])
            stack.alignment = .center
            stack.spacing = 12.0
            self.refreshers.append { _ in
                valueLabel.text = value()
            }
            return self.padded(stack)

        case let .button(title, destructive, action):
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 17.0)
            button.contentHorizontalAlignment = .leading
            button.setTitleColor(destructive ? palette.destructive : palette.accent, for: .normal)
            button.ayuOn(.touchUpInside) {
                action()
            }
            return self.padded(self.withIcon(title, button))
        }
    }

    // MARK: - Actions

    /// Bubble corners are a stock Telegram appearance setting, so the slider
    /// writes through to it and every chat re-renders immediately.
    private func applyBubbleRadius(_ radius: Int32) {
        let _ = updatePresentationThemeSettingsInteractively(accountManager: self.context.sharedContext.accountManager, { current in
            let bubble = current.chatBubbleSettings
            return current.withUpdatedChatBubbleSettings(PresentationChatBubbleSettings(
                mainRadius: radius,
                auxiliaryRadius: min(bubble.auxiliaryRadius, max(radius, 2)),
                mergeBubbleCorners: bubble.mergeBubbleCorners
            ))
        }).start()
    }

    private func showAlert(title: String, text: String, actions: [TextAlertAction]) {
        self.present(textAlertController(context: self.context, title: title, text: text, actions: actions), in: .window(.root))
    }

    private func showNotice(_ text: String) {
        self.showAlert(title: "WndrGram", text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})])
    }

    private func exportSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(AyuSettings.current), let string = String(data: data, encoding: .utf8) else {
            return
        }
        UIPasteboard.general.string = string
        self.showNotice("Настройки скопированы в буфер обмена.")
    }

    private func importSettings() {
        guard let string = UIPasteboard.general.string, let data = string.data(using: .utf8), let imported = try? JSONDecoder().decode(AyuSettingsData.self, from: data) else {
            self.showNotice("В буфере обмена нет настроек WndrGram.")
            return
        }
        AyuSettings.shared.update { settings in
            settings = imported
        }
        self.showNotice("Настройки импортированы.")
    }

    private func confirmReset() {
        self.showAlert(title: "Сбросить настройки", text: "Все параметры WndrGram вернутся к значениям по умолчанию.", actions: [
            TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: "Сбросить", action: {
                AyuSettings.shared.resetToDefaults()
            })
        ])
    }

    private func confirmClearArchive() {
        self.showAlert(title: "Очистить архив", text: "Все сохранённые удалённые сообщения и история правок будут удалены с устройства. Это нельзя отменить.", actions: [
            TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: self.presentationData.strings.Common_Delete, action: {
                AyuMessageArchive.shared.clearAll()
            })
        ])
    }

    // MARK: - Content

    private var colorWellSetters: [ObjectIdentifier: (Int32) -> Void] = [:]

    @available(iOS 14.0, *)
    @objc private func ayuColorWellChanged(_ well: UIColorWell) {
        guard let color = well.selectedColor, let setter = self.colorWellSetters[ObjectIdentifier(well)] else {
            return
        }
        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        var a: CGFloat = 0.0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let value = (Int32(max(0.0, min(1.0, r)) * 255.0) << 16) | (Int32(max(0.0, min(1.0, g)) * 255.0) << 8) | Int32(max(0.0, min(1.0, b)) * 255.0)
        setter(value)
    }

    private func pushController(_ controller: ViewController) {
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }

    private func makeGroups() -> [AyuMenuGroup] {
        let context = self.context
        let percent: (Float) -> String = { "\(Int($0))%" }
        let points: (Float) -> String = { "\(Int($0))" }

        var groups: [AyuMenuGroup] = [
            AyuMenuGroup(title: "Режим призрака", footer: "Локально чаты и истории всё равно помечаются прочитанными — собеседник этого не видит.", rows: [
                .toggle(title: "Отправлять прочтения", subtitle: nil, get: { $0.sendReadMessages }, set: { $0.sendReadMessages = $1 }),
                .toggle(title: "Просмотры историй", subtitle: nil, get: { $0.sendReadStories }, set: { $0.sendReadStories = $1 }),
                .toggle(title: "Статус «онлайн»", subtitle: nil, get: { $0.sendOnlinePackets }, set: { $0.sendOnlinePackets = $1 }),
                .toggle(title: "Статус «печатает»", subtitle: "Также запись голосовых и выбор стикера", get: { $0.sendTypingStatus }, set: { $0.sendTypingStatus = $1 }),
                .toggle(title: "Прогресс загрузки", subtitle: nil, get: { $0.sendUploadProgress }, set: { $0.sendUploadProgress = $1 }),
                .toggle(title: "Уходить в офлайн сразу", subtitle: "Отправить offline при включении режима", get: { $0.sendOfflinePacketAfterOnline }, set: { $0.sendOfflinePacketAfterOnline = $1 }),
                .toggle(title: "Читать чат после ответа", subtitle: "Когда отвечаете, собеседник видит прочтение", get: { $0.markReadAfterAction }, set: { $0.markReadAfterAction = $1 }),
                .toggle(title: "Отправлять как отложенные", subtitle: "В призраке сообщения уходят через 12 секунд и не выдают онлайн", get: { $0.useScheduledMessages }, set: { $0.useScheduledMessages = $1 }),
                .toggle(title: "Спрашивать перед историей", subtitle: "Предлагать режим призрака перед просмотром", get: { $0.suggestGhostModeBeforeViewingStory }, set: { $0.suggestGhostModeBeforeViewingStory = $1 }),
                .segmented(title: "Отправлять без звука", options: ["Никогда", "Всегда", "В призраке"], get: { Int($0.sendWithoutSound.rawValue) }, set: { settings, index in
                    settings.sendWithoutSound = AyuSendWithoutSoundOption(rawValue: Int32(index)) ?? .never
                })
            ]),
            AyuMenuGroup(title: "Удалённые и изменённые", footer: "Всё хранится только на этом устройстве и никуда не выгружается.", rows: [
                .toggle(title: "Сохранять удалённые", subtitle: nil, get: { $0.saveDeletedMessages }, set: { $0.saveDeletedMessages = $1 }),
                .toggle(title: "Сохранять историю правок", subtitle: nil, get: { $0.saveMessagesHistory }, set: { $0.saveMessagesHistory = $1 }),
                .toggle(title: "Сохранять медиа", subtitle: nil, get: { $0.saveDeletedMedia }, set: { $0.saveDeletedMedia = $1 }),
                .toggle(title: "Одноразовые медиа", subtitle: "Фото, видео, кружки и голосовые с таймером не исчезают и открываются повторно", get: { $0.saveSelfDestructingMedia }, set: { $0.saveSelfDestructingMedia = $1 }),
                .toggle(title: "Включая ботов", subtitle: nil, get: { $0.saveForBots }, set: { $0.saveForBots = $1 }),
                .segmented(title: "Хранить", options: ["Всегда", "7 дн", "30 дн", "90 дн", "Год"], get: { settings in
                    return [0, 7, 30, 90, 365].firstIndex(of: settings.historyRetentionDays) ?? 0
                }, set: { settings, index in
                    let options: [Int32] = [0, 7, 30, 90, 365]
                    settings.historyRetentionDays = options[max(0, min(options.count - 1, index))]
                })
            ]),
            AyuMenuGroup(title: "Вид удалённых", footer: nil, rows: [
                .toggle(title: "Показывать в чате", subtitle: nil, get: { $0.showDeletedMessages }, set: { $0.showDeletedMessages = $1 }),
                .toggle(title: "Полупрозрачные", subtitle: nil, get: { $0.semiTransparentDeletedMessages }, set: { $0.semiTransparentDeletedMessages = $1 }),
                .slider(title: "Непрозрачность", range: 10 ... 100, step: 5, format: percent, get: { Float($0.deletedMessageOpacity) }, set: { $0.deletedMessageOpacity = Int32($1) }),
                .toggle(title: "Значок корзины у удалённых", subtitle: nil, get: { $0.showDeletedIcon }, set: { $0.showDeletedIcon = $1 }),
                .toggle(title: "Значок карандаша у изменённых", subtitle: nil, get: { $0.showEditedIcon }, set: { $0.showEditedIcon = $1 }),
                .text(title: "Метка удалённого", placeholder: "нет", get: { $0.deletedMark }, set: { $0.deletedMark = $1 }),
                .text(title: "Метка изменённого", placeholder: "нет", get: { $0.editedMark }, set: { $0.editedMark = $1 })
            ]),
            AyuMenuGroup(title: "Дизайн", footer: "Подсветка применяется ко всем стеклянным элементам Liquid Glass. Классические панели и хвостики применяются после перезапуска.", rows: [
                .slider(title: "Скорость анимаций", range: 25 ... 300, step: 25, format: { value in
                    return String(format: "%.2g×", Double(value) / 100.0)
                }, get: { Float($0.animationSpeed) }, set: { $0.animationSpeed = Int32($1) }),
                .toggle(title: "Классические панели (без стекла)", subtitle: "Старый стиль верхних панелей", get: { $0.classicNavigationBars }, set: { $0.classicNavigationBars = $1 }),
                .toggle(title: "Своя подсветка стекла", subtitle: nil, get: { $0.glassTintEnabled }, set: { $0.glassTintEnabled = $1 }),
                .color(title: "Цвет стекла", get: { $0.glassTintColor }, set: { $0.glassTintColor = $1 }),
                .slider(title: "Насыщенность стекла", range: 0 ... 100, step: 5, format: { "\(Int($0))%" }, get: { Float($0.glassTintAlpha) }, set: { $0.glassTintAlpha = Int32($1) })
            ]),
            AyuMenuGroup(title: "Внешний вид", footer: nil, rows: [
                .button(title: "Оформление и темы", destructive: false, action: { [weak self] in
                    self?.pushController(themeSettingsController(context: context))
                }),
                .button(title: "Создать свою тему (все цвета)", destructive: false, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.pushController(editThemeController(context: context, mode: .create(self.presentationData.theme, nil)))
                }),
                .toggle(title: "Время у каждого сообщения", subtitle: "Иначе время только у последнего в серии", get: { $0.showTimeOnEveryMessage }, set: { $0.showTimeOnEveryMessage = $1 }),
                .toggle(title: "Секунды во времени", subtitle: nil, get: { $0.showMessageSeconds }, set: { $0.showMessageSeconds = $1 }),
                .slider(title: "Скругление пузырей", range: 0 ... 20, step: 1, format: points, get: { Float($0.messageBubbleRadius) }, set: { $0.messageBubbleRadius = Int32($1) }),
                .slider(title: "Скругление аватарок", range: 0 ... 50, step: 5, format: { value in
                    return value >= 50 ? "Круг" : "\(Int(value))%"
                }, get: { Float($0.avatarRoundness) }, set: { $0.avatarRoundness = Int32($1) }),
                .segmented(title: "ID в профиле", options: ["Скрыт", "Bot API", "Telegram"], get: { Int($0.showPeerId.rawValue) }, set: { settings, index in
                    settings.showPeerId = AyuPeerIdDisplay(rawValue: Int32(index)) ?? .botApi
                }),
                .toggle(title: "Без хвостиков у пузырей", subtitle: "Нужен перезапуск", get: { $0.removeMessageTail }, set: { $0.removeMessageTail = $1 }),
                .toggle(title: "Раскрывать спойлеры", subtitle: "Текст и медиа под спойлером видны сразу", get: { $0.revealSpoilers }, set: { $0.revealSpoilers = $1 }),
                .toggle(title: "Фильтр «залго»-текста", subtitle: "Убирает нагромождения символов в сообщениях", get: { $0.filterZalgo }, set: { $0.filterZalgo = $1 }),
                .toggle(title: "Скрыть Premium-звёздочки", subtitle: "Значок Premium у других рядом с именем", get: { $0.hidePremiumBadges }, set: { $0.hidePremiumBadges = $1 }),
                .toggle(title: "Скрыть премиум-статусы", subtitle: "Эмодзи-статусы у других рядом с именем", get: { $0.hidePremiumStatuses }, set: { $0.hidePremiumStatuses = $1 }),
                .toggle(title: "Без чужих обоев в чатах", subtitle: "Обои, которые поставил собеседник", get: { $0.disableCustomBackgrounds }, set: { $0.disableCustomBackgrounds = $1 }),
                .toggle(title: "Реакции в каналах", subtitle: nil, get: { $0.showChannelReactions }, set: { $0.showChannelReactions = $1 }),
                .toggle(title: "Реакции в группах", subtitle: nil, get: { $0.showGroupReactions }, set: { $0.showGroupReactions = $1 }),
                .toggle(title: "Реакции в личных чатах", subtitle: nil, get: { $0.showPrivateReactions }, set: { $0.showPrivateReactions = $1 }),
                .toggle(title: "Скрыть папку «Все чаты»", subtitle: nil, get: { $0.hideAllChatsFolder }, set: { $0.hideAllChatsFolder = $1 }),
                .toggle(title: "Скрыть истории", subtitle: nil, get: { $0.disableStories }, set: { $0.disableStories = $1 }),
                .toggle(title: "Скрыть рекламу", subtitle: "Спонсорские сообщения в каналах", get: { $0.disableAds }, set: { $0.disableAds = $1 }),
                .toggle(title: "Скрыть похожие каналы", subtitle: "Блок рекомендаций в каналах", get: { $0.collapseSimilarChannels }, set: { $0.collapseSimilarChannels = $1 }),
                .toggle(title: "Скрыть счётчики", subtitle: "Значок на иконке и на вкладке «Чаты»", get: { $0.hideNotificationCounters }, set: { $0.hideNotificationCounters = $1 })
            ]),
            AyuMenuGroup(title: "Поведение", footer: nil, rows: [
                .toggle(title: "«Повторить» в меню сообщения", subtitle: "Отправить сообщение ещё раз от себя", get: { $0.showRepeatInContextMenu }, set: { $0.showRepeatInContextMenu = $1 }),
                .toggle(title: "«Детали» в меню сообщения", subtitle: "ID, даты, размер файла", get: { $0.showDetailsInContextMenu }, set: { $0.showDetailsInContextMenu = $1 }),
                .toggle(title: "Расшифровка голосовых без Premium", subtitle: "Распознавание речи прямо на iPhone, бесплатно и без лимитов", get: { $0.localVoiceTranscription }, set: { $0.localVoiceTranscription = $1 }),
                .toggle(title: "Перевод чатов на устройстве", subtitle: "Переводчик Apple, бесплатно, iOS 18+", get: { $0.localTranslation }, set: { $0.localTranslation = $1 }),
                .toggle(title: "Скорость 2.5× и 3×", subtitle: "Для голосовых, кружков и музыки", get: { $0.extendedPlaybackSpeeds }, set: { $0.extendedPlaybackSpeeds = $1 }),
                .toggle(title: "Без предупреждения о ссылках", subtitle: "Открывать скрытые ссылки сразу", get: { $0.disableOpenLinkWarning }, set: { $0.disableOpenLinkWarning = $1 }),
                .toggle(title: "Подтверждать стикеры", subtitle: nil, get: { $0.stickerConfirmation }, set: { $0.stickerConfirmation = $1 }),
                .toggle(title: "Подтверждать GIF", subtitle: nil, get: { $0.gifConfirmation }, set: { $0.gifConfirmation = $1 }),
                .toggle(title: "Подтверждать голосовые", subtitle: nil, get: { $0.voiceConfirmation }, set: { $0.voiceConfirmation = $1 }),
                .toggle(title: "Подтверждать кружки", subtitle: nil, get: { $0.roundConfirmation }, set: { $0.roundConfirmation = $1 }),
                .toggle(title: "Без приветственного стикера", subtitle: nil, get: { $0.disableGreetingSticker }, set: { $0.disableGreetingSticker = $1 }),
                .toggle(title: "Безлимит недавних стикеров", subtitle: nil, get: { $0.unlimitedRecentStickers }, set: { $0.unlimitedRecentStickers = $1 }),
                .toggle(title: "Локальный Premium", subtitle: "Открывает Premium-интерфейс только на этом устройстве. Нужен перезапуск.", get: { $0.localPremium }, set: { $0.localPremium = $1 })
            ]),
            AyuMenuGroup(title: "Приватность", footer: "Режим стримера скрывает интерфейс на скриншотах и записи экрана.", rows: [
                .toggle(title: "Размытие в переключателе приложений", subtitle: nil, get: { $0.privacyScreenInAppSwitcher }, set: { $0.privacyScreenInAppSwitcher = $1 }),
                .toggle(title: "Скрыть свой номер", subtitle: "В профиле и настройках. В режиме стримера скрыт всегда", get: { $0.hideOwnPhoneNumber }, set: { $0.hideOwnPhoneNumber = $1 }),
                .toggle(title: "Режим стримера", subtitle: nil, get: { $0.streamerMode }, set: { $0.streamerMode = $1 }),
                .toggle(title: "Не читать чат из уведомления", subtitle: nil, get: { $0.keepUnreadOnNotificationOpen }, set: { $0.keepUnreadOnNotificationOpen = $1 })
            ]),
            AyuMenuGroup(title: "Скинченджер подарков", footer: "Выбери любой подарок и «подари» его себе — он появится в твоём профиле бесплатно. Видно только на этом устройстве.", rows: [
                .toggle(title: "Локальные подарки в профиле", subtitle: nil, get: { $0.localGifts }, set: { $0.localGifts = $1 }),
                .button(title: "Добавить подарки", destructive: false, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    if !AyuSettings.current.localGifts {
                        AyuSettings.shared.update { settings in
                            settings.localGifts = true
                        }
                    }
                    self.pushController(context.sharedContext.makeGiftOptionsController(context: context, peerId: context.account.peerId, premiumOptions: [], hasBirthday: false, completion: nil))
                }),
                .info(title: "Добавлено подарков", value: {
                    return "\(AyuLocalGifts.count)"
                }),
                .button(title: "Удалить локальные подарки", destructive: true, action: {
                    AyuLocalGifts.removeAll()
                })
            ]),
            AyuMenuGroup(title: "Хранилище", footer: nil, rows: [
                .button(title: "Открыть архив сообщений", destructive: false, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    presentAyuArchive(context: self.context, push: { [weak self] controller in
                        let _ = (self?.navigationController as? NavigationController)?.pushViewController(controller)
                    })
                }),
                .toggle(title: "Face ID для архива", subtitle: nil, get: { $0.lockMessageArchive }, set: { $0.lockMessageArchive = $1 }),
                .info(title: "Размер архива", value: {
                    let bytes = AyuMessageArchive.shared.diskUsage()
                    if bytes <= 0 {
                        return "Пусто"
                    }
                    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                }),
                .button(title: "Очистить архив", destructive: true, action: { [weak self] in
                    self?.confirmClearArchive()
                })
            ])
        ]

        var configRows: [AyuMenuRow] = [
            .button(title: "Экспорт настроек в буфер", destructive: false, action: { [weak self] in
                self?.exportSettings()
            }),
            .button(title: "Импорт настроек из буфера", destructive: false, action: { [weak self] in
                self?.importSettings()
            }),
            .button(title: "Сбросить всё", destructive: true, action: { [weak self] in
                self?.confirmReset()
            })
        ]
        if let openDebugMenu = self.openDebugMenu {
            configRows.append(.button(title: "Отладочное меню Telegram", destructive: false, action: {
                openDebugMenu()
            }))
        }
        groups.append(AyuMenuGroup(title: "Конфигурация", footer: "Настройки — обычный JSON: им можно поделиться или сохранить в заметки.", rows: configRows))

        return groups
    }
}

/// Closure-based control events that work on iOS 13 (`UIControl.addAction`
/// is iOS 14+). Handlers live as long as the control.
private final class AyuControlHandler: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() {
        self.action()
    }
}

private var ayuControlHandlersKey: UInt8 = 0

private extension UIControl {
    func ayuOn(_ events: UIControl.Event, _ action: @escaping () -> Void) {
        let handler = AyuControlHandler(action)
        self.addTarget(handler, action: #selector(AyuControlHandler.fire), for: events)
        var handlers = (objc_getAssociatedObject(self, &ayuControlHandlersKey) as? [AyuControlHandler]) ?? []
        handlers.append(handler)
        objc_setAssociatedObject(self, &ayuControlHandlersKey, handlers, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private let ayuMenuIcons: [String: (String, UInt32)] = [
    "Отправлять прочтения": ("checkmark.message.fill", 0x34C759),
    "Просмотры историй": ("eye.circle.fill", 0xFF9500),
    "Статус «онлайн»": ("dot.radiowaves.left.and.right", 0x30B0C7),
    "Статус «печатает»": ("ellipsis.bubble.fill", 0x007AFF),
    "Прогресс загрузки": ("arrow.up.circle.fill", 0x5856D6),
    "Уходить в офлайн сразу": ("moon.fill", 0x8E8E93),
    "Читать чат после ответа": ("arrowshape.turn.up.left.fill", 0x34C759),
    "Отправлять как отложенные": ("clock.fill", 0xFF9500),
    "Спрашивать перед историей": ("questionmark.circle.fill", 0xAF52DE),
    "Отправлять без звука": ("bell.slash.fill", 0xFF3B30),
    "Сохранять удалённые": ("trash.slash.fill", 0xFF3B30),
    "Сохранять историю правок": ("pencil.and.list.clipboard", 0xFF9500),
    "Сохранять медиа": ("photo.on.rectangle.angled", 0x007AFF),
    "Одноразовые медиа": ("flame.fill", 0xFF2D55),
    "Включая ботов": ("cpu.fill", 0x8E8E93),
    "Хранить": ("calendar", 0x5856D6),
    "Показывать в чате": ("text.bubble.fill", 0x007AFF),
    "Полупрозрачные": ("circle.lefthalf.filled", 0x8E8E93),
    "Непрозрачность": ("slider.horizontal.3", 0x8E8E93),
    "Значок корзины у удалённых": ("trash.fill", 0xFF3B30),
    "Значок карандаша у изменённых": ("pencil", 0xFF9500),
    "Метка удалённого": ("tag.fill", 0xFF3B30),
    "Метка изменённого": ("tag.fill", 0xFF9500),
    "Секунды во времени": ("stopwatch.fill", 0x30B0C7),
    "Время у каждого сообщения": ("clock.fill", 0x007AFF),
    "Классические панели (без стекла)": ("rectangle.topthird.inset.filled", 0x8E8E93),
    "Своя подсветка стекла": ("drop.fill", 0x5AC8FA),
    "Скорость анимаций": ("speedometer", 0xFF9500),
    "Скрыть Premium-звёздочки": ("star.circle", 0xAF52DE),
    "Цвет стекла": ("paintpalette.fill", 0xAF52DE),
    "Насыщенность стекла": ("circle.lefthalf.filled", 0x5856D6),
    "Расшифровка голосовых без Premium": ("waveform", 0xFF9500),
    "Перевод чатов на устройстве": ("character.bubble.fill", 0x007AFF),
    "Скорость 2.5× и 3×": ("hare.fill", 0xFF9500),
    "Скругление пузырей": ("bubble.left.fill", 0x007AFF),
    "Скругление аватарок": ("person.crop.circle.fill", 0xAF52DE),
    "ID в профиле": ("number.circle.fill", 0x5856D6),
    "Скрыть папку «Все чаты»": ("folder.fill", 0x007AFF),
    "Скрыть истории": ("circle.dashed", 0xFF9500),
    "Скрыть рекламу": ("megaphone.fill", 0xFF3B30),
    "Скрыть похожие каналы": ("rectangle.stack.fill", 0x8E8E93),
    "Скрыть счётчики": ("app.badge.fill", 0xFF3B30),
    "Оформление и темы": ("paintbrush.fill", 0x007AFF),
    "Создать свою тему (все цвета)": ("paintpalette.fill", 0xFF2D55),
    "Без предупреждения о ссылках": ("link", 0x007AFF),
    "Подтверждать стикеры": ("face.smiling.inverse", 0xFF9500),
    "Подтверждать GIF": ("sparkles.rectangle.stack.fill", 0x34C759),
    "Подтверждать голосовые": ("mic.fill", 0xFF3B30),
    "Подтверждать кружки": ("video.circle.fill", 0x5856D6),
    "Без приветственного стикера": ("hand.wave.fill", 0xFF9500),
    "Безлимит недавних стикеров": ("infinity", 0x30B0C7),
    "Локальный Premium": ("star.fill", 0xAF52DE),
    "Размытие в переключателе приложений": ("rectangle.on.rectangle", 0x8E8E93),
    "Режим стримера": ("video.slash.fill", 0xFF3B30),
    "Скрыть свой номер": ("phone.down.fill", 0x34C759),
    "Не читать чат из уведомления": ("bell.badge.fill", 0xFF9500),
    "Открыть архив сообщений": ("archivebox.fill", 0x5856D6),
    "Face ID для архива": ("faceid", 0x34C759),
    "Размер архива": ("internaldrive.fill", 0x8E8E93),
    "Очистить архив": ("trash.fill", 0xFF3B30),
    "Экспорт настроек в буфер": ("square.and.arrow.up.fill", 0x007AFF),
    "Импорт настроек из буфера": ("square.and.arrow.down.fill", 0x34C759),
    "Сбросить всё": ("arrow.counterclockwise", 0xFF3B30),
    "Отладочное меню Telegram": ("ladybug.fill", 0x8E8E93),
    "Без хвостиков у пузырей": ("bubble.left", 0x007AFF),
    "Скрыть премиум-статусы": ("star.slash.fill", 0xAF52DE),
    "Реакции в каналах": ("heart.fill", 0xFF2D55),
    "Реакции в группах": ("heart.fill", 0xFF9500),
    "Реакции в личных чатах": ("heart.fill", 0x34C759),
    "Без чужих обоев в чатах": ("photo.fill", 0x34C759),
    "Раскрывать спойлеры": ("eye.fill", 0x5856D6),
    "Фильтр «залго»-текста": ("textformat", 0x8E8E93),
    "«Повторить» в меню сообщения": ("arrow.2.squarepath", 0x34C759),
    "«Детали» в меню сообщения": ("info.circle.fill", 0x007AFF),
    "Локальные подарки в профиле": ("gift.fill", 0xFF2D55),
    "Добавить подарки": ("plus.circle.fill", 0x34C759),
    "Добавлено подарков": ("shippingbox.fill", 0xFF9500),
    "Удалить локальные подарки": ("trash.fill", 0xFF3B30)
]
