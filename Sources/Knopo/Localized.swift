import Foundation

/// A localized UI string whose key needs no explaining - "Cut", "Delete Block".
///
/// No `comment:` parameter on purpose: `scripts/l10n-extract.sh` still harvests
/// the key through a wrapper, but drops a comment passed to one. When a
/// translator needs context - an ambiguous word, a placeholder, a key two
/// screens share - call `String(localized:comment:)` directly.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}
