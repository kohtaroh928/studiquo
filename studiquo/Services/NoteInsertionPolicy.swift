import Foundation

/// Decides which pane a note-insertion tool (photo, text, shapes, ...) acts
/// on while the editor is split. Independent of `NoteEditorView` so the rule
/// can be unit tested without building the editor hierarchy.
enum NoteInsertionPolicy {
    /// - A pane showing a note wins over one that does not (web, chat, deck,
    ///   photo library...), whichever was touched last.
    /// - When both show notes, the one touched last wins.
    /// - nil when neither pane can take an insertion.
    static func targetPane(
        lastActive: PhotoStudyPane,
        primaryShowsNote: Bool,
        secondaryShowsNote: Bool
    ) -> PhotoStudyPane? {
        switch (primaryShowsNote, secondaryShowsNote) {
        case (true, true): return lastActive
        case (true, false): return .primary
        case (false, true): return .secondary
        case (false, false): return nil
        }
    }
}
