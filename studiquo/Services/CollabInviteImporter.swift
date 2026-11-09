import Foundation

/// Turns the room state of a document someone shared with this person into a
/// local `TextDocument`, the step that was missing between accepting a
/// collaboration invite and being able to open the document (see
/// `DocumentCollabService` and `CollabInvitesSection`).
///
/// The room tracks only plain paragraph text per block, keyed by the block's
/// `order`. So the imported document keeps each paragraph at the same `order`
/// the room uses (that is what lets later change proposals anchor to the right
/// paragraph) and carries over list markers and paragraph styles. Tables,
/// images, equations and page breaks are not in the room and are not imported.
enum CollabInviteImporter {
    static func title(inviterName: String?) -> String {
        guard let name = inviterName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return L("共有された文書")
        }
        return L("\(name)さんの共有文書")
    }

    /// The paragraph blocks of `state`, already carrying the room's ordering.
    static func makeBlocks(from state: DocumentCollabService.RoomState) -> [DocumentBlock] {
        state.blocks
            .filter { $0.kind == DocumentBlockKind.paragraph.rawValue }
            .sorted { $0.order < $1.order }
            .map { source in
                let block = DocumentBlock(order: source.order, kind: .paragraph)
                block.bodyData = DocumentBody.encode(
                    NSAttributedString(string: source.text, attributes: DocumentBody.defaultAttributes())
                )
                block.listKindRawValue = source.listKind
                block.listLevel = source.listLevel
                block.paragraphStyleRawValue = source.paragraphStyle
                return block
            }
    }

    /// A new, not yet inserted document bound to `roomID`, so that the editor's
    /// existing propose/review flow works for the invited person.
    static func makeDocument(
        roomID: String, inviterName: String?, state: DocumentCollabService.RoomState
    ) -> TextDocument {
        let document = TextDocument(title: title(inviterName: inviterName))
        let blocks = makeBlocks(from: state)
        for block in blocks { block.document = document }
        document.blocks = blocks
        // The blocks are the source of truth; no migration from `bodyData`.
        document.isMigratedToBlocks = true
        let whole = DocumentBlockText.joinedText(of: blocks)
        document.bodyData = DocumentBody.encode(whole)
        document.plainText = whole.string
        for block in state.blocks {
            if block.kind == "header" || block.kind == "footer", !block.text.isEmpty {
                document.headerFooter(block.kind == "header" ? .header : .footer).text = block.text
            }
        }
        document.collabRoomID = roomID
        return document
    }
}
