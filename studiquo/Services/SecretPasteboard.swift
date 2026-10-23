import UIKit
import UniformTypeIdentifiers

/// Somewhere to write items; `UIPasteboard` is the real one.
protocol PasteboardWriting {
    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])
}

extension UIPasteboard: PasteboardWriting {}

/// Copying a secret (the MCP connection token).
///
/// A plain `UIPasteboard.general.string = …` stays until something replaces it,
/// is sent to the student's other devices by Universal Clipboard, and can be read
/// by any app that pastes. A secret is copied for this device only and for a
/// short while.
enum SecretPasteboard {
    static let lifetime: TimeInterval = 60

    static func copy(
        _ secret: String,
        to pasteboard: PasteboardWriting = UIPasteboard.general,
        now: Date = Date()
    ) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: secret]],
            options: [
                .localOnly: true,
                .expirationDate: now.addingTimeInterval(lifetime),
            ]
        )
    }
}
