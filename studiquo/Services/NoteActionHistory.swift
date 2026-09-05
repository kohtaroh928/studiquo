import Foundation
import SwiftData

/// Undo/redo for everything on a page that isn't ink.
///
/// Ink already had its own history, keyed by page and holding whole
/// `InkDrawing` snapshots — see `DrawingHistoryStore`. That covers strokes
/// well and nothing else, so adding a shape, adding a page or deleting one
/// left the undo button with nothing to do. This is the other half: a single
/// ordered stack of reversible actions.
///
/// Entries are closures rather than model snapshots because the operations
/// differ too much to share one shape — deleting a page and nudging a photo
/// have nothing in common except being undoable.
///
/// The two stores are kept separate rather than merged. Merging would mean
/// re-expressing every stroke as a closure pair and giving up the per-page
/// keying that lets two canvases show the same page without fighting over one
/// stack. Instead each records *when* its newest undoable step happened, and
/// the button undoes whichever is more recent — so from the student's side
/// there is one history, in the order they worked.
@MainActor
final class NoteActionHistory {
    static let shared = NoteActionHistory()

    private struct Entry {
        let at: Date
        let undo: () -> Void
        let redo: () -> Void
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    /// The last request acted on. Two panes can both answer one button press;
    /// without this the second would pop the stack again and skip a step.
    private var lastHandledRequest: UUID?

    private static let depthLimit = 100

    private init() {}

    /// When the newest undoable action happened, or `nil` when there is none.
    var lastUndoDate: Date? { undoStack.last?.at }
    var lastRedoDate: Date? { redoStack.last?.at }

    /// - Parameters:
    ///   - undo: puts the note back the way it was.
    ///   - redo: performs the action again.
    func record(undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoStack.append(Entry(at: .now, undo: undo, redo: redo))
        if undoStack.count > Self.depthLimit { undoStack.removeFirst() }
        // A new action invalidates anything that was undone before it, the
        // same way it does in every other editor.
        redoStack.removeAll()
    }

    @discardableResult
    func undo(requestID: UUID) -> Bool {
        guard claim(requestID), let entry = undoStack.popLast() else { return false }
        entry.undo()
        redoStack.append(Entry(at: .now, undo: entry.undo, redo: entry.redo))
        return true
    }

    @discardableResult
    func redo(requestID: UUID) -> Bool {
        guard claim(requestID), let entry = redoStack.popLast() else { return false }
        entry.redo()
        undoStack.append(Entry(at: .now, undo: entry.undo, redo: entry.redo))
        return true
    }

    private func claim(_ requestID: UUID) -> Bool {
        guard lastHandledRequest != requestID else { return false }
        lastHandledRequest = requestID
        return true
    }
}

// MARK: - Recording helpers

/// Holds whichever object currently stands for a recorded one.
///
/// A deleted SwiftData object cannot be brought back; redo has to insert a
/// fresh one. Later entries in the stack still refer to "that element", so
/// they point at this box instead of at an object that may no longer exist,
/// and the box is repointed each time the object is recreated.
@MainActor
final class ElementSlot {
    var element: PageElement?
    init(_ element: PageElement?) { self.element = element }
}

@MainActor
final class PageSlot {
    var page: NotePage?
    init(_ page: NotePage?) { self.page = page }
}

/// Everything needed to rebuild a `PageElement` that has been deleted.
struct PageElementSnapshot {
    var kind: PageElementKind
    var text: String
    var imageData: Data?
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    var rotation: Double
    var colorHex: String
    var isLocked: Bool
    var layerIndex: Double

    @MainActor
    init(_ element: PageElement) {
        kind = element.kind
        text = element.text
        imageData = element.imageData
        centerX = element.centerX
        centerY = element.centerY
        width = element.width
        height = element.height
        rotation = element.rotation
        colorHex = element.colorHex
        isLocked = element.isLocked
        layerIndex = element.layerIndex
    }

    @MainActor
    func makeElement() -> PageElement {
        let element = PageElement(
            kind: kind,
            text: text,
            imageData: imageData,
            centerX: centerX,
            centerY: centerY,
            width: width,
            height: height,
            rotation: rotation,
            colorHex: colorHex
        )
        element.isLocked = isLocked
        element.layerIndex = layerIndex
        return element
    }

    /// Writes the snapshot back over an element that still exists — the undo
    /// path for a move, resize or rotate, where nothing was created or
    /// destroyed.
    @MainActor
    func apply(to element: PageElement) {
        element.kind = kind
        element.text = text
        element.imageData = imageData
        element.centerX = centerX
        element.centerY = centerY
        element.width = width
        element.height = height
        element.rotation = rotation
        element.colorHex = colorHex
        element.isLocked = isLocked
        element.layerIndex = layerIndex
    }
}

/// Everything needed to rebuild a deleted `NotePage`, ink included.
struct NotePageSnapshot {
    var order: Int
    var templateRawValue: String
    var paperColorHex: String
    var pageWidth: Double
    var pageHeight: Double
    var drawingData: Data?
    var backgroundImageData: Data?
    var recognizedText: String
    var inkReferenceWidth: Double
    var elements: [PageElementSnapshot]

    @MainActor
    init(_ page: NotePage) {
        order = page.order
        templateRawValue = page.templateRawValue
        paperColorHex = page.paperColorHex
        pageWidth = page.pageWidth
        pageHeight = page.pageHeight
        drawingData = page.drawingData
        backgroundImageData = page.backgroundImageData
        recognizedText = page.recognizedText
        inkReferenceWidth = page.inkReferenceWidth
        elements = page.allElements.map(PageElementSnapshot.init)
    }

    @MainActor
    func makePage(in context: ModelContext, notebook: Notebook) -> NotePage {
        let page = NotePage(order: order)
        page.templateRawValue = templateRawValue
        page.paperColorHex = paperColorHex
        page.pageWidth = pageWidth
        page.pageHeight = pageHeight
        page.drawingData = drawingData
        page.backgroundImageData = backgroundImageData
        page.recognizedText = recognizedText
        page.inkReferenceWidth = inkReferenceWidth
        page.notebook = notebook
        context.insert(page)
        for snapshot in elements {
            let element = snapshot.makeElement()
            element.page = page
            page.addElement(element)
            context.insert(element)
        }
        return page
    }
}
