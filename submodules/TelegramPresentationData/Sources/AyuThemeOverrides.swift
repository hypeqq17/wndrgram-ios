import Foundation
import UIKit
import SwiftSignalKit
import AyuSettings

// WndrGram palette editor backend: any colour of the active theme can be
// replaced. The theme is serialized with the regular theme coder, the
// overridden keys are patched and the text is decoded back into a theme.

/// One colour entry of an encoded theme.
public struct AyuThemeColorEntry {
    /// Dot separated path, e.g. "chat.message.outgoing.bubble.withWp.fill".
    public let path: String
    /// "aarrggbb".
    public let value: String
}

private func ayuWalkEncodedTheme(_ text: String, _ visit: (String, String) -> String?) -> String {
    var stack: [String] = []
    var output: [String] = []
    for rawLine in text.components(separatedBy: "\n") {
        guard let colon = rawLine.firstIndex(of: ":") else {
            output.append(rawLine)
            continue
        }
        let indent = rawLine.prefix(while: { $0 == " " }).count
        let depth = indent / 2
        if stack.count > depth {
            stack.removeLast(stack.count - depth)
        }
        let key = rawLine[rawLine.startIndex ..< colon].trimmingCharacters(in: .whitespaces)
        let value = rawLine[rawLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            stack.append(key)
            output.append(rawLine)
            continue
        }
        let path = (stack + [key]).joined(separator: ".")
        if let replacement = visit(path, value) {
            output.append(String(repeating: " ", count: indent) + key + ": " + replacement)
        } else {
            output.append(rawLine)
        }
    }
    return output.joined(separator: "\n")
}

private func ayuIsColorValue(_ value: String) -> Bool {
    return value.count == 8 && value.allSatisfy { $0.isHexDigit }
}

/// All colour entries of a theme, in theme order.
public func ayuThemeColorEntries(_ theme: PresentationTheme) -> [AyuThemeColorEntry] {
    guard let text = encodePresentationTheme(theme) else {
        return []
    }
    var result: [AyuThemeColorEntry] = []
    let _ = ayuWalkEncodedTheme(text, { path, value in
        if ayuIsColorValue(value) {
            result.append(AyuThemeColorEntry(path: path, value: value))
        }
        return nil
    })
    return result
}

/// Set when overrides could not be applied; the palette screen shows it.
public var ayuThemeOverrideLastError: String?

private var ayuOverrideCache: (source: PresentationTheme, overrides: [String: String], result: PresentationTheme)?
private let ayuOverrideLock = NSLock()

/// Applies the user's colour overrides to a theme. Returns the theme itself
/// when there is nothing to override or decoding fails.
public func ayuApplyThemeOverrides(_ theme: PresentationTheme) -> PresentationTheme {
    let overrides = AyuSettings.current.themeOverrides
    if overrides.isEmpty {
        return theme
    }
    ayuOverrideLock.lock()
    if let cache = ayuOverrideCache, cache.source === theme, cache.overrides == overrides {
        ayuOverrideLock.unlock()
        return cache.result
    }
    ayuOverrideLock.unlock()

    guard let text = encodePresentationTheme(theme) else {
        ayuThemeOverrideLastError = "Не удалось прочитать текущую тему"
        return theme
    }
    let patched = ayuWalkEncodedTheme(text, { path, value in
        if let replacement = overrides[path], ayuIsColorValue(value), ayuIsColorValue(replacement) {
            return replacement
        }
        return nil
    })
    guard let data = patched.data(using: .utf8), let result = makePresentationTheme(data: data) else {
        ayuThemeOverrideLastError = "Не удалось собрать тему с новыми цветами"
        return theme
    }
    ayuOverrideLock.lock()
    ayuOverrideCache = (theme, overrides, result)
    ayuOverrideLock.unlock()
    return result
}

/// Fires whenever the overrides change so presentation data is rebuilt.
public let ayuThemeOverridesSignal: Signal<[String: String], NoError> = AyuSettings.shared.signal
|> map { $0.themeOverrides }
|> distinctUntilChanged
