import Foundation

/// Strips "zalgo" text: stacks of combining marks piled onto one character.
/// At most one combining mark is kept per base character, which leaves normal
/// accents alone. Returns nil when there was nothing to strip.
public func ayuStripZalgo(_ text: String) -> String? {
    var result = String.UnicodeScalarView()
    var marksOnCurrentBase = 0
    var removed = 0
    for scalar in text.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark:
            marksOnCurrentBase += 1
            if marksOnCurrentBase > 1 {
                removed += 1
                continue
            }
        default:
            marksOnCurrentBase = 0
        }
        result.append(scalar)
    }
    // A couple of stray marks is not zalgo; only rewrite real stacks.
    return removed >= 3 ? String(result) : nil
}
