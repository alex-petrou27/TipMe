import UIKit

/// The physical feedback behind every tap, confirm, and landed payment.
///
/// A share extension has no dedicated "haptics are heavy" restriction the
/// way it does for memory (see `ShareViewController`'s own docstring) --
/// `UIFeedbackGenerator` is cheap and works identically inside an extension,
/// so this is shared rather than app-only. Centralised here so a tap
/// anywhere in the product feels like the same product, and so a future
/// change (e.g. respecting a "reduce haptics" preference) has one place to
/// happen.
enum Haptics {
    /// A light tick -- a preset amount picked, a primary button pressed.
    /// Deliberately fired on intent, not on outcome; see `success`/`error`.
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// A firmer knock for a more consequential press -- confirming with
    /// Face ID, right before the biometric prompt appears.
    static func confirm() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Money actually moved. Reserved for the one moment that deserves it --
    /// firing this anywhere else would cheapen it.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
