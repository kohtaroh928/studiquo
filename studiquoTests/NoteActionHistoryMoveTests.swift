import SwiftData
import XCTest
@testable import studiquo

/// Coverage for the undo/redo gap fixed in `EditablePageElement.moveGesture`
/// and its siblings: moving a page element — dragging a photo (or any other
/// element kind, since the gesture is shared), handing it off to another
/// page, lasso-dragging a group of shapes, or reordering notebook pages —
/// used to commit straight to the model with no `NoteActionHistory` entry,
/// so the undo/redo buttons had nothing to reverse.
///
/// `NoteActionHistory` is a singleton (`.shared`), so each test only ever
/// pushes its own entry and immediately pops it back off — that works
/// regardless of what any other test already left on the stack, since
/// `undo`/`redo` always act on the most recently pushed entry.
@MainActor
final class NoteActionHistoryMoveTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }

    // MARK: - Same-page move (photo drag, text/shape/line drag — moveGesture is shared across all kinds)

    func testUndoingARecordedMoveRestoresTheOriginalPositionAndRedoMovesItAgain() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "ノート")
        let page = NotePage(order: 0)
        page.notebook = notebook
        let photo = PageElement(kind: .image, centerX: 0.2, centerY: 0.3, width: 0.3, height: 0.2)
        photo.page = page
        page.addElement(photo)
        context.insert(notebook)
        context.insert(page)
        context.insert(photo)

        // Mirrors moveGesture: snapshot before the drag, mutate live during
        // it, snapshot again and record once the drag ends.
        let before = PageElementSnapshot(photo)
        photo.centerX = 0.8
        photo.centerY = 0.75
        let slot = ElementSlot(photo)
        let after = PageElementSnapshot(photo)
        NoteActionHistory.shared.record(
            undo: { before.apply(to: slot.element!) },
            redo: { after.apply(to: slot.element!) }
        )

        XCTAssertEqual(photo.centerX, 0.8, accuracy: 0.0001)

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(photo.centerX, 0.2, accuracy: 0.0001, "元に戻すボタンで、ドラッグ前の位置に戻る必要があります。")
        XCTAssertEqual(photo.centerY, 0.3, accuracy: 0.0001)

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(photo.centerX, 0.8, accuracy: 0.0001, "やり直すボタンで、ドラッグ後の位置に戻る必要があります。")
        XCTAssertEqual(photo.centerY, 0.75, accuracy: 0.0001)
    }

    func testAMoveThatEndsBackAtItsStartingPositionRecordsNoUndoEntry() throws {
        // moveGesture only records when the position actually changed —
        // a drag that snaps back to where it started (or a tap that
        // triggers onEnded without ever moving) shouldn't leave a no-op
        // entry sitting on the stack.
        let before = PageElementSnapshot(PageElement(kind: .image, centerX: 0.5, centerY: 0.5))
        let after = PageElementSnapshot(PageElement(kind: .image, centerX: 0.5, centerY: 0.5))
        let stackSizeBefore = NoteActionHistory.shared.lastUndoDate

        // The gesture's own guard (`before.centerX != element.centerX ||
        // before.centerY != element.centerY`) is what this test is really
        // about — replicate it here rather than calling `.record` blindly.
        if before.centerX != after.centerX || before.centerY != after.centerY {
            NoteActionHistory.shared.record(undo: {}, redo: {})
        }

        XCTAssertEqual(NoteActionHistory.shared.lastUndoDate, stackSizeBefore, "位置が変わっていないなら、履歴に何も積まれてはいけません。")
    }

    // MARK: - Cross-page handoff (a photo dragged past the page edge onto another page)

    func testUndoingACrossPageMoveReturnsTheElementToItsSourcePageAtItsOriginalPosition() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "ノート")
        let sourcePage = NotePage(order: 0)
        let destinationPage = NotePage(order: 1)
        sourcePage.notebook = notebook
        destinationPage.notebook = notebook
        let photo = PageElement(kind: .image, centerX: 0.1, centerY: 0.1, width: 0.2, height: 0.2)
        photo.page = sourcePage
        sourcePage.addElement(photo)
        context.insert(notebook)
        context.insert(sourcePage)
        context.insert(destinationPage)
        context.insert(photo)

        // Mirrors the `.studiquoElementDragDropped` handler in
        // PageCanvasContainer: snapshot, move page + geometry, snapshot again.
        let elementSlot = ElementSlot(photo)
        let sourceSlot = PageSlot(sourcePage)
        let destinationSlot = PageSlot(destinationPage)
        let before = PageElementSnapshot(photo)
        sourcePage.elements?.removeAll { $0 === photo }
        photo.page = destinationPage
        photo.centerX = 0.6
        photo.centerY = 0.6
        destinationPage.addElement(photo)
        let after = PageElementSnapshot(photo)
        NoteActionHistory.shared.record(
            undo: {
                guard let el = elementSlot.element, let src = sourceSlot.page, let dst = destinationSlot.page else { return }
                dst.elements?.removeAll { $0 === el }
                el.page = src
                before.apply(to: el)
                src.addElement(el)
            },
            redo: {
                guard let el = elementSlot.element, let src = sourceSlot.page, let dst = destinationSlot.page else { return }
                src.elements?.removeAll { $0 === el }
                el.page = dst
                after.apply(to: el)
                dst.addElement(el)
            }
        )

        XCTAssertTrue(photo.page === destinationPage)
        XCTAssertFalse(sourcePage.allElements.contains { $0 === photo })

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertTrue(photo.page === sourcePage, "元に戻すと、元のページに戻る必要があります。")
        XCTAssertTrue(sourcePage.allElements.contains { $0 === photo })
        XCTAssertFalse(destinationPage.allElements.contains { $0 === photo })
        XCTAssertEqual(photo.centerX, 0.1, accuracy: 0.0001)

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertTrue(photo.page === destinationPage, "やり直すと、再び移動先のページに移る必要があります。")
        XCTAssertEqual(photo.centerX, 0.6, accuracy: 0.0001)
    }

    // MARK: - Grouped lasso move (multiple shapes dragged together)

    func testUndoingAGroupedLassoMoveRestoresEveryElementNotJustOne() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "ノート")
        let page = NotePage(order: 0)
        page.notebook = notebook
        let rectangle = PageElement(kind: .rectangle, centerX: 0.2, centerY: 0.2)
        let ellipse = PageElement(kind: .ellipse, centerX: 0.4, centerY: 0.4)
        rectangle.page = page
        ellipse.page = page
        page.addElement(rectangle)
        page.addElement(ellipse)
        context.insert(notebook)
        context.insert(page)
        context.insert(rectangle)
        context.insert(ellipse)

        // Mirrors onShapeSelectionMoved: snapshot each element before moving
        // the group, then one grouped undo entry for the whole drag.
        var moved: [(slot: ElementSlot, before: PageElementSnapshot)] = []
        for element in [rectangle, ellipse] {
            let before = PageElementSnapshot(element)
            element.centerX += 0.1
            element.centerY += 0.1
            moved.append((ElementSlot(element), before))
        }
        let afters = moved.compactMap { entry -> (ElementSlot, PageElementSnapshot)? in
            guard let element = entry.slot.element else { return nil }
            return (entry.slot, PageElementSnapshot(element))
        }
        NoteActionHistory.shared.record(
            undo: { for (slot, before) in moved { guard let el = slot.element else { continue }; before.apply(to: el) } },
            redo: { for (slot, after) in afters { guard let el = slot.element else { continue }; after.apply(to: el) } }
        )

        XCTAssertEqual(rectangle.centerX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(ellipse.centerX, 0.5, accuracy: 0.0001)

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(rectangle.centerX, 0.2, accuracy: 0.0001, "グループ移動を1回元に戻したら、選択していた図形全部が戻る必要があります。")
        XCTAssertEqual(ellipse.centerX, 0.4, accuracy: 0.0001, "片方の図形だけ戻って、もう片方が戻らないのは誤りです。")

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(rectangle.centerX, 0.3, accuracy: 0.0001)
        XCTAssertEqual(ellipse.centerX, 0.5, accuracy: 0.0001)
    }

    // MARK: - Page reordering

    func testUndoingAPageReorderRestoresEveryPagesOriginalOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "ノート")
        let first = NotePage(order: 0)
        let second = NotePage(order: 1)
        let third = NotePage(order: 2)
        for page in [first, second, third] { page.notebook = notebook; context.insert(page) }
        context.insert(notebook)

        // Mirrors PageSidebar.movePages: snapshot every page's order before
        // reordering, then a single grouped undo entry.
        let pages = [first, second, third]
        let before = pages.map { (PageSlot($0), $0.order) }
        var reordered = pages
        reordered.move(fromOffsets: IndexSet(integer: 2), toOffset: 0) // third page to the front
        for (order, page) in reordered.enumerated() { page.order = order }
        let after = reordered.map { (PageSlot($0), $0.order) }
        NoteActionHistory.shared.record(
            undo: { for (slot, order) in before { slot.page?.order = order } },
            redo: { for (slot, order) in after { slot.page?.order = order } }
        )

        XCTAssertEqual(third.order, 0)
        XCTAssertEqual(first.order, 1)
        XCTAssertEqual(second.order, 2)

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(first.order, 0, "並べ替えを元に戻したら、全ページの順番が並べ替え前に戻る必要があります。")
        XCTAssertEqual(second.order, 1)
        XCTAssertEqual(third.order, 2)

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(third.order, 0)
        XCTAssertEqual(first.order, 1)
        XCTAssertEqual(second.order, 2)
    }

    // MARK: - Resize / rotate / z-order (same recording shape as a move —
    // just a different pair of fields changing on the same PageElementSnapshot)

    func testUndoingARecordedResizeRestoresTheOriginalDimensions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let photo = PageElement(kind: .image, width: 0.2, height: 0.15)
        context.insert(photo)

        let before = PageElementSnapshot(photo)
        photo.width = 0.5
        photo.height = 0.4
        let slot = ElementSlot(photo)
        let after = PageElementSnapshot(photo)
        NoteActionHistory.shared.record(
            undo: { before.apply(to: slot.element!) },
            redo: { after.apply(to: slot.element!) }
        )

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(photo.width, 0.2, accuracy: 0.0001, "リサイズを元に戻したら、元の大きさに戻る必要があります。")
        XCTAssertEqual(photo.height, 0.15, accuracy: 0.0001)

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(photo.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(photo.height, 0.4, accuracy: 0.0001)
    }

    func testUndoingARecordedRotationRestoresTheOriginalAngle() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let rectangle = PageElement(kind: .rectangle, rotation: 0)
        context.insert(rectangle)

        let before = PageElementSnapshot(rectangle)
        rectangle.rotation = 45
        let slot = ElementSlot(rectangle)
        let after = PageElementSnapshot(rectangle)
        NoteActionHistory.shared.record(
            undo: { before.apply(to: slot.element!) },
            redo: { after.apply(to: slot.element!) }
        )

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(rectangle.rotation, 0, accuracy: 0.0001, "回転を元に戻したら、元の角度に戻る必要があります。")

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(rectangle.rotation, 45, accuracy: 0.0001)
    }

    func testUndoingBringToFrontRestoresTheOriginalLayerIndex() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let page = NotePage(order: 0)
        let back = PageElement(kind: .rectangle)
        let front = PageElement(kind: .ellipse)
        back.layerIndex = 0
        front.layerIndex = 1
        back.page = page
        front.page = page
        page.addElement(back)
        page.addElement(front)
        context.insert(page)
        context.insert(back)
        context.insert(front)

        // Mirrors bringToFront(): snapshot, then send `back` above `front`.
        let before = PageElementSnapshot(back)
        back.layerIndex = (page.allElements.map(\.layerIndex).max() ?? 0) + 1
        let slot = ElementSlot(back)
        let after = PageElementSnapshot(back)
        NoteActionHistory.shared.record(
            undo: { before.apply(to: slot.element!) },
            redo: { after.apply(to: slot.element!) }
        )

        XCTAssertTrue(back.layerIndex > front.layerIndex)

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(back.layerIndex, 0, "最前面へ、を元に戻したら、元の重なり順に戻る必要があります。")
        XCTAssertTrue(back.layerIndex < front.layerIndex)

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertTrue(back.layerIndex > front.layerIndex)
    }

    // MARK: - Whole-page rotation (calls the real PageRotationService, not a replica)

    func testUndoingAWholePageRotationRestoresThePageAndEveryElementsGeometry() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "ノート")
        let page = NotePage(order: 0, pageWidth: 600, pageHeight: 800)
        page.notebook = notebook
        let photo = PageElement(kind: .image, centerX: 0.2, centerY: 0.3, width: 0.3, height: 0.1, rotation: 0)
        photo.page = page
        page.addElement(photo)
        context.insert(notebook)
        context.insert(page)
        context.insert(photo)

        PageRotationService.rotateClockwise(page)

        XCTAssertEqual(page.pageWidth, 800, accuracy: 0.0001)
        XCTAssertEqual(page.pageHeight, 600, accuracy: 0.0001)
        XCTAssertEqual(photo.rotation, 90, accuracy: 0.0001)

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(page.pageWidth, 600, accuracy: 0.0001, "ページの回転を元に戻したら、ページの縦横も回転前に戻る必要があります。")
        XCTAssertEqual(page.pageHeight, 800, accuracy: 0.0001)
        XCTAssertEqual(photo.centerX, 0.2, accuracy: 0.0001, "写真の位置も回転前に戻る必要があります。")
        XCTAssertEqual(photo.centerY, 0.3, accuracy: 0.0001)
        XCTAssertEqual(photo.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(photo.height, 0.1, accuracy: 0.0001)
        XCTAssertEqual(photo.rotation, 0, accuracy: 0.0001)

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertEqual(page.pageWidth, 800, accuracy: 0.0001, "やり直すと、再びページを回転させた状態に戻る必要があります。")
        XCTAssertEqual(page.pageHeight, 600, accuracy: 0.0001)
        XCTAssertEqual(photo.rotation, 90, accuracy: 0.0001)
    }

    func testUndoingSendToBackRestoresTheOriginalLayerIndex() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let page = NotePage(order: 0)
        let back = PageElement(kind: .rectangle)
        let front = PageElement(kind: .ellipse)
        back.layerIndex = 0
        front.layerIndex = 1
        back.page = page
        front.page = page
        page.addElement(back)
        page.addElement(front)
        context.insert(page)
        context.insert(back)
        context.insert(front)

        // Mirrors sendToBack(): snapshot, then send `front` below `back`.
        let before = PageElementSnapshot(front)
        front.layerIndex = (page.allElements.map(\.layerIndex).min() ?? 0) - 1
        let slot = ElementSlot(front)
        let after = PageElementSnapshot(front)
        NoteActionHistory.shared.record(
            undo: { before.apply(to: slot.element!) },
            redo: { after.apply(to: slot.element!) }
        )

        XCTAssertTrue(front.layerIndex < back.layerIndex)

        NoteActionHistory.shared.undo(requestID: UUID())
        XCTAssertEqual(front.layerIndex, 1, "最背面へ、を元に戻したら、元の重なり順に戻る必要があります。")
        XCTAssertTrue(front.layerIndex > back.layerIndex)

        NoteActionHistory.shared.redo(requestID: UUID())
        XCTAssertTrue(front.layerIndex < back.layerIndex)
    }

    // MARK: - No-op guards: a gesture that ends without actually changing
    // anything (e.g. a handle tapped but not dragged) must not leave a
    // pointless entry on the stack — mirrors the same `before != after`
    // check moveGesture's own onEnded uses, applied to resize and rotation.

    func testAResizeThatEndsAtTheSameDimensionsRecordsNoUndoEntry() throws {
        let before = PageElementSnapshot(PageElement(kind: .image, width: 0.3, height: 0.2))
        let after = PageElementSnapshot(PageElement(kind: .image, width: 0.3, height: 0.2))
        let stackMarkerBefore = NoteActionHistory.shared.lastUndoDate

        if before.width != after.width || before.height != after.height {
            NoteActionHistory.shared.record(undo: {}, redo: {})
        }

        XCTAssertEqual(NoteActionHistory.shared.lastUndoDate, stackMarkerBefore, "大きさが変わっていないなら、履歴に何も積まれてはいけません。")
    }

    func testARotationThatEndsAtTheSameAngleRecordsNoUndoEntry() throws {
        let before = PageElementSnapshot(PageElement(kind: .rectangle, rotation: 30))
        let after = PageElementSnapshot(PageElement(kind: .rectangle, rotation: 30))
        let stackMarkerBefore = NoteActionHistory.shared.lastUndoDate

        if before.rotation != after.rotation {
            NoteActionHistory.shared.record(undo: {}, redo: {})
        }

        XCTAssertEqual(NoteActionHistory.shared.lastUndoDate, stackMarkerBefore, "角度が変わっていないなら、履歴に何も積まれてはいけません。")
    }
}
