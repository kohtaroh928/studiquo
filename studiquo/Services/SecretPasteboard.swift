import UIKit
import UniformTypeIdentifiers

/// Somewhere to write items; `UIPasteboard` is the real one.
protocol PasteboardWriting {
    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])
}

extension UIPasteboard: PasteboardWriting {}

/// Copying a secret or short-lived pairing code.
///
/// A plain `UIPasteboard.general.string = …` stays until something replaces it,
/// is sent to the student's other devices by Universal Clipboard, and can be read
/// by any app that pastes. `SecretPasteboard` always sets an expiration date, and
/// defaults to keeping the item on this device only unless cross-device pasting
/// (such as pasting an MCP pairing code onto a Mac) is intended.
enum SecretPasteboard {
    static let lifetime: TimeInterval = 60

    static func copy(
        _ secret: String,
        localOnly: Bool = true,
        expiresAt: Date? = nil,
        to pasteboard: PasteboardWriting = UIPasteboard.general,
        now: Date = Date()
    ) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: secret]],
            options: [
                .localOnly: localOnly,
                .expirationDate: expiresAt ?? now.addingTimeInterval(lifetime),
            ]
        )
    }
}
