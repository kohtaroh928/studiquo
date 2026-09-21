import XCTest
@testable import studiquo

/// Coverage for the canvas-based slide model (design steps 2/4): the
/// inherit/override mechanism that lets a master's placeholder changes
/// reach every slide still using it, until someone moves that element on
/// its own slide — and `Slide.changeLayout(to:)`'s role-matching, which is
/// what keeps "switch a slide's layout" a one-tap operation the way the old
/// fixed-`SlideLayout` model was.
final class SlideElementGeometryInheritanceTests: XCTestCase {
    func testAnElementLinkedToAPlaceholderTracksItsCurrentValuesByDefault() {
        let layout = SlideLayoutTemplate(name: "テスト", order: 0)
        let placeholder = layout.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.1, width: 0.8, height: 0.2)
        let element = SlideElement(kind: .text)
        element.sourcePlaceholder = placeholder

        XCTAssertEqual(element.centerX, 0.5)
        XCTAssertTrue(element.isInheritingGeometry)

        // The master (via its placeholder) is edited after the fact — a
        // still-inheriting element must follow it live, not freeze at
        // whatever the value was when the element was created.
        placeholder.centerX = 0.3
        XCTAssertEqual(element.centerX, 0.3, "an element that hasn't been touched must keep following its placeholder")
    }

    func testBakingInGeometryDetachesTheElementFromFurtherPlaceholderChanges() {
        let layout = SlideLayoutTemplate(name: "テスト", order: 0)
        let placeholder = layout.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.1, width: 0.8, height: 0.2)
        let element = SlideElement(kind: .text)
        element.sourcePlaceholder = placeholder

        element.bakeInGeometryIfNeeded() // simulates the user's first drag
        XCTAssertFalse(element.isInheritingGeometry)

        placeholder.centerX = 0.9
        XCTAssertEqual(element.centerX, 0.5, "once overridden, later master edits must not move this element")
    }

    func testBakingInGeometryTwiceDoesNotClobberAnAlreadyOverriddenValue() {
        let layout = SlideLayoutTemplate(name: "テスト", order: 0)
        let placeholder = layout.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.1, width: 0.8, height: 0.2)
        let element = SlideElement(kind: .text)
        element.sourcePlaceholder = placeholder
        element.bakeInGeometryIfNeeded()
        element.overrideCenterX = 0.1 // the user actually moved it after baking in

        element.bakeInGeometryIfNeeded() // e.g. a second drag gesture starting

        XCTAssertEqual(element.overrideCenterX, 0.1, "a second bake-in must not reset a value the user already set")
    }

    func testAFreeElementWithNoPlaceholderUsesItsOwnOverridesOnly() {
        let element = SlideElement(kind: .rectangle)
        element.overrideCenterX = 0.2
        element.overrideCenterY = 0.2
        element.overrideWidth = 0.1
        element.overrideHeight = 0.1

        XCTAssertFalse(element.isInheritingGeometry, "an element with no placeholder was never inheriting to begin with")
        XCTAssertEqual(element.centerX, 0.2)
    }
}

final class SlideGroupTests: XCTestCase {
    func testMovingAGroupMovesEveryMemberByTheSameDelta() {
        let group = SlideElement(kind: .group)
        group.overrideCenterX = 0.5
        group.overrideCenterY = 0.5
        let memberA = SlideElement(kind: .rectangle)
        memberA.overrideCenterX = 0.4
        memberA.overrideCenterY = 0.45
        let memberB = SlideElement(kind: .ellipse)
        memberB.overrideCenterX = 0.6
        memberB.overrideCenterY = 0.55
        group.groupMembers = [memberA, memberB]
        memberA.parentGroup = group
        memberB.parentGroup = group

        group.moveGroup(dx: 0.1, dy: -0.05)

        XCTAssertEqual(group.centerX, 0.6, accuracy: 0.0001)
        XCTAssertEqual(memberA.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(memberA.centerY, 0.4, accuracy: 0.0001)
        XCTAssertEqual(memberB.centerX, 0.7, accuracy: 0.0001)
    }

    func testMovingAGroupBakesInAnInheritingMembersGeometryFirst() {
        let layout = SlideLayoutTemplate(name: "テスト", order: 0)
        let placeholder = layout.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.1, width: 0.8, height: 0.2)
        let group = SlideElement(kind: .group)
        group.overrideCenterX = 0.5
        group.overrideCenterY = 0.5
        let inheritingMember = SlideElement(kind: .text)
        inheritingMember.sourcePlaceholder = placeholder
        group.groupMembers = [inheritingMember]
        inheritingMember.parentGroup = group

        group.moveGroup(dx: 0.1, dy: 0)

        XCTAssertFalse(inheritingMember.isInheritingGeometry, "grouping and moving must detach a member from its placeholder, the same as moving it directly would")
        XCTAssertEqual(inheritingMember.centerX, 0.6, accuracy: 0.0001)
    }
}

final class SlideChangeLayoutTests: XCTestCase {
    func testSwitchingLayoutsKeepsContentForMatchingRoles() {
        let master = SlideMaster()
        let oldLayout = master.addLayout(name: "旧")
        let titlePlaceholder = oldLayout.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.1, width: 0.8, height: 0.2)
        let newLayout = master.addLayout(name: "新")
        let newTitlePlaceholder = newLayout.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.05, width: 0.9, height: 0.15)

        let slide = Slide(order: 0)
        slide.layout = oldLayout
        let titleElement = SlideElement(kind: .text)
        titleElement.sourcePlaceholder = titlePlaceholder
        titleElement.bodyData = DocumentBody.encode(NSAttributedString(string: "私のタイトル"))
        slide.addElement(titleElement)

        slide.changeLayout(to: newLayout)

        XCTAssertTrue(titleElement.sourcePlaceholder === newTitlePlaceholder, "the title content must re-link to the new layout's title placeholder, not be lost")
        XCTAssertEqual(DocumentBody.decode(titleElement.bodyData).string, "私のタイトル")
        XCTAssertTrue(slide.layout === newLayout)
    }

    func testSwitchingLayoutsDetachesAnElementWhoseRoleNoLongerExists() {
        let master = SlideMaster()
        let oldLayout = master.addLayout(name: "旧")
        let secondaryPlaceholder = oldLayout.addPlaceholder(role: .secondaryBody, kind: .text, centerX: 0.75, centerY: 0.5, width: 0.4, height: 0.6)
        let newLayout = master.addLayout(name: "新") // no secondaryBody role at all

        let slide = Slide(order: 0)
        slide.layout = oldLayout
        let secondaryElement = SlideElement(kind: .text)
        secondaryElement.sourcePlaceholder = secondaryPlaceholder
        slide.addElement(secondaryElement)
        let resolvedX = secondaryElement.centerX

        slide.changeLayout(to: newLayout)

        XCTAssertNil(secondaryElement.sourcePlaceholder, "a role the new layout doesn't have must detach, not vanish")
        XCTAssertEqual(secondaryElement.overrideCenterX, resolvedX, "detaching must bake in wherever it currently was, so it doesn't jump")
        XCTAssertTrue(slide.sortedElements.contains { $0 === secondaryElement }, "a detached element stays on the slide as a free element")
    }

    func testSwitchingLayoutsCreatesFreshInheritingElementsForNewlyIntroducedRoles() {
        let master = SlideMaster()
        let oldLayout = master.addLayout(name: "旧") // no image role
        let newLayout = master.addLayout(name: "新")
        let imagePlaceholder = newLayout.addPlaceholder(role: .image, kind: .image, centerX: 0.5, centerY: 0.5, width: 0.7, height: 0.7)

        let slide = Slide(order: 0)
        slide.layout = oldLayout

        slide.changeLayout(to: newLayout)

        let imageElement = slide.element(for: .image)
        XCTAssertNotNil(imageElement)
        XCTAssertTrue(imageElement?.sourcePlaceholder === imagePlaceholder)
        XCTAssertTrue(imageElement?.isInheritingGeometry == true)
    }
}

/// Coverage for the master editor's (design step 5) destructive actions —
/// removing a layout or a single placeholder must never silently discard a
/// slide's position/size for elements still inheriting from it.
/// Coverage for the master editor's (design step 5) "duplicate layout"
/// action — see `SlideMaster.duplicateLayout(_:)`.
/// Coverage for the "pull past the canvas edge to add a slide" gesture's
/// model-side ordering — see `SlideDeck.insertSlide(_:adjacentTo:before:)`.
final class SlideDeckInsertSlideTests: XCTestCase {
    private func deckWithSlides(_ count: Int) -> (SlideDeck, [Slide]) {
        let deck = SlideDeck(title: "テスト")
        var slides: [Slide] = []
        for i in 0..<count {
            let slide = Slide(order: i)
            slide.deck = deck
            deck.addSlide(slide)
            slides.append(slide)
        }
        return (deck, slides)
    }

    func testInsertingBeforeThePlacesTheNewSlideImmediatelyAheadOfIt() {
        let (deck, slides) = deckWithSlides(2) // [A, B]
        let inserted = Slide(order: 0)
        deck.insertSlide(inserted, adjacentTo: slides[1], before: true) // insert before B → [A, new, B]

        let ordered = deck.sortedSlides
        XCTAssertEqual(ordered.count, 3)
        XCTAssertTrue(ordered[0] === slides[0])
        XCTAssertTrue(ordered[1] === inserted)
        XCTAssertTrue(ordered[2] === slides[1])
    }

    func testInsertingAfterPlacesTheNewSlideImmediatelyBehindIt() {
        let (deck, slides) = deckWithSlides(2) // [A, B]
        let inserted = Slide(order: 0)
        deck.insertSlide(inserted, adjacentTo: slides[0], before: false) // insert after A → [A, new, B]

        let ordered = deck.sortedSlides
        XCTAssertTrue(ordered[0] === slides[0])
        XCTAssertTrue(ordered[1] === inserted)
        XCTAssertTrue(ordered[2] === slides[1])
    }

    func testOrderValuesEndUpContiguousStartingAtZero() {
        let (deck, slides) = deckWithSlides(3) // [A, B, C]
        let inserted = Slide(order: 0)
        deck.insertSlide(inserted, adjacentTo: slides[1], before: false) // after B → [A, B, new, C]

        XCTAssertEqual(deck.sortedSlides.map(\.order), [0, 1, 2, 3])
    }

    func testInsertingBeforeTheFirstSlideBecomesTheNewFirstSlide() {
        let (deck, slides) = deckWithSlides(2)
        let inserted = Slide(order: 0)
        deck.insertSlide(inserted, adjacentTo: slides[0], before: true)

        XCTAssertTrue(deck.sortedSlides.first === inserted)
    }

    func testInsertingAfterTheLastSlideBecomesTheNewLastSlide() {
        let (deck, slides) = deckWithSlides(2)
        let inserted = Slide(order: 0)
        deck.insertSlide(inserted, adjacentTo: slides[1], before: false)

        XCTAssertTrue(deck.sortedSlides.last === inserted)
    }
}

final class SlideMasterDuplicateLayoutTests: XCTestCase {
    func testDuplicateCreatesAnIndependentLayoutNamedWithACopySuffix() {
        let master = SlideMaster.makeDefault()
        let original = master.sortedLayouts.first { $0.name == "タイトルと内容" }!

        let copy = master.duplicateLayout(original)

        XCTAssertEqual(copy.name, "タイトルと内容のコピー")
        XCTAssertTrue(master.sortedLayouts.contains { $0 === copy })
        XCTAssertEqual(master.sortedLayouts.count, 8, "the copy is added alongside the 7 defaults, not replacing one")
    }

    func testDuplicateCopiesEveryPlaceholdersGeometryAndTextStyle() {
        let master = SlideMaster.makeDefault()
        let original = master.sortedLayouts.first { $0.name == "タイトルと内容" }!
        let originalTitle = original.placeholder(for: .title)!
        originalTitle.defaultFontSize = 44
        originalTitle.defaultIsBold = true
        originalTitle.rotation = 5

        let copy = master.duplicateLayout(original)
        let copiedTitle = copy.placeholder(for: .title)!

        XCTAssertEqual(copiedTitle.centerX, originalTitle.centerX)
        XCTAssertEqual(copiedTitle.centerY, originalTitle.centerY)
        XCTAssertEqual(copiedTitle.width, originalTitle.width)
        XCTAssertEqual(copiedTitle.height, originalTitle.height)
        XCTAssertEqual(copiedTitle.defaultFontSize, 44)
        XCTAssertEqual(copiedTitle.defaultIsBold, true)
        XCTAssertEqual(copiedTitle.rotation, 5)
    }

    func testEditingTheCopyAfterwardDoesNotAffectTheOriginal() {
        let master = SlideMaster.makeDefault()
        let original = master.sortedLayouts.first { $0.name == "タイトルと内容" }!
        let originalTitleX = original.placeholder(for: .title)!.centerX

        let copy = master.duplicateLayout(original)
        copy.placeholder(for: .title)!.centerX = 0.1

        XCTAssertEqual(original.placeholder(for: .title)!.centerX, originalTitleX, "the two placeholders must be separate objects, not shared")
    }

    func testDuplicatingALayoutWithNoPlaceholdersProducesAnEmptyCopy() {
        let master = SlideMaster.makeDefault()
        let blank = master.sortedLayouts.first { $0.name == "白紙" }!

        let copy = master.duplicateLayout(blank)

        XCTAssertEqual(copy.sortedPlaceholders.count, 0)
    }
}

final class SlideMasterEditorRemovalTests: XCTestCase {
    func testRemovingALayoutDetachesAndBakesInStillInheritingElements() {
        let master = SlideMaster.makeDefault()
        let layout = master.sortedLayouts.first { $0.name == "タイトルと内容" }!
        let titlePlaceholder = layout.placeholder(for: .title)!

        let slide = Slide(order: 0)
        slide.layout = layout
        let titleElement = SlideElement(kind: .text)
        titleElement.sourcePlaceholder = titlePlaceholder
        slide.addElement(titleElement)
        let resolvedX = titleElement.centerX

        let removed = master.removeLayout(layout)

        XCTAssertTrue(removed)
        XCTAssertFalse(master.sortedLayouts.contains { $0 === layout })
        XCTAssertNil(titleElement.sourcePlaceholder, "the placeholder it inherited from is gone — it must detach, not point at nothing")
        XCTAssertEqual(titleElement.overrideCenterX, resolvedX, "detaching must bake in wherever it currently was, so it doesn't jump")
    }

    func testRemovingALayoutNotOnThisMasterIsANoOp() {
        let master = SlideMaster.makeDefault()
        let foreignLayout = SlideLayoutTemplate(name: "よそのレイアウト", order: 0)
        XCTAssertFalse(master.removeLayout(foreignLayout))
    }

    func testRemovingAPlaceholderDetachesAndBakesInStillInheritingElements() {
        let layout = SlideLayoutTemplate(name: "テスト", order: 0)
        let placeholder = layout.addPlaceholder(role: .body, kind: .text, centerX: 0.5, centerY: 0.5, width: 0.6, height: 0.4)

        let slide = Slide(order: 0)
        slide.layout = layout
        let element = SlideElement(kind: .text)
        element.sourcePlaceholder = placeholder
        slide.addElement(element)
        let resolvedWidth = element.width

        let removed = layout.removePlaceholder(placeholder)

        XCTAssertTrue(removed)
        XCTAssertFalse(layout.sortedPlaceholders.contains { $0 === placeholder })
        XCTAssertNil(element.sourcePlaceholder)
        XCTAssertEqual(element.overrideWidth, resolvedWidth)
    }

    func testRemovingAPlaceholderLeavesOtherPlaceholdersAndTheirElementsUntouched() {
        let layout = SlideLayoutTemplate(name: "テスト", order: 0)
        let titlePlaceholder = layout.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.1, width: 0.8, height: 0.2)
        let bodyPlaceholder = layout.addPlaceholder(role: .body, kind: .text, centerX: 0.5, centerY: 0.6, width: 0.8, height: 0.6)

        let slide = Slide(order: 0)
        slide.layout = layout
        let titleElement = SlideElement(kind: .text)
        titleElement.sourcePlaceholder = titlePlaceholder
        slide.addElement(titleElement)

        layout.removePlaceholder(bodyPlaceholder)

        XCTAssertTrue(titleElement.sourcePlaceholder === titlePlaceholder, "removing one placeholder must not disturb an element inheriting from a different one")
        XCTAssertTrue(layout.sortedPlaceholders.contains { $0 === titlePlaceholder })
    }
}

final class SlideMasterDefaultTests: XCTestCase {
    func testMakeDefaultCreatesTheSevenStandardLayouts() {
        let master = SlideMaster.makeDefault()
        XCTAssertEqual(master.sortedLayouts.count, 7)
    }

    func testMakeDefaultsTitleAndBodyLayoutHasATitleAndABodyPlaceholder() {
        let master = SlideMaster.makeDefault()
        let titleAndBody = master.sortedLayouts.first { $0.name == "タイトルと内容" }
        XCTAssertNotNil(titleAndBody?.placeholder(for: .title))
        XCTAssertNotNil(titleAndBody?.placeholder(for: .body))
    }

    func testMakeDefaultsBlankLayoutHasNoPlaceholders() {
        let master = SlideMaster.makeDefault()
        let blank = master.sortedLayouts.first { $0.name == "白紙" }
        XCTAssertEqual(blank?.sortedPlaceholders.count, 0)
    }
}

/// Coverage for the presentation playback sequencing (design step 6) —
/// see `Slide.animationSteps`'s doc comment for the simplified model this
/// groups elements under.
/// Coverage for the presenter view's elapsed-time clock (design step 7) —
/// see `PresentationElapsedTime`'s doc comment.
final class PresentationElapsedTimeTests: XCTestCase {
    func testFormatsSecondsUnderAMinuteAsZeroMinutes() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(PresentationElapsedTime.formatted(from: start, to: start.addingTimeInterval(45)), "00:45")
    }

    func testFormatsMinutesAndSeconds() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(PresentationElapsedTime.formatted(from: start, to: start.addingTimeInterval(125)), "02:05")
    }

    func testNeverGoesNegativeIfNowIsSomehowBeforeStart() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(PresentationElapsedTime.formatted(from: start, to: start.addingTimeInterval(-5)), "00:00")
    }
}

final class SlideAnimationStepsTests: XCTestCase {
    private func animatedElement(order: Int, kind: SlideAnimationKind = .fadeIn, trigger: SlideAnimationTrigger = .onClick) -> SlideElement {
        let element = SlideElement(kind: .text)
        element.animationKind = kind
        element.animationTrigger = trigger
        element.animationOrder = order
        return element
    }

    func testANonAnimatedSlideHasOnlyTheEmptyAutoRevealStep() {
        let slide = Slide(order: 0)
        let element = SlideElement(kind: .text) // animationKind defaults to .none
        slide.addElement(element)
        XCTAssertEqual(slide.animationSteps.count, 1)
        XCTAssertTrue(slide.animationSteps[0].isEmpty)
    }

    func testEachOnClickElementStartsItsOwnStep() {
        let slide = Slide(order: 0)
        let first = animatedElement(order: 0)
        let second = animatedElement(order: 1)
        slide.addElement(second) // insertion order shouldn't matter, animationOrder decides
        slide.addElement(first)

        let steps = slide.animationSteps
        XCTAssertEqual(steps.count, 3, "an empty auto-reveal step 0, plus one step per onClick element")
        XCTAssertTrue(steps[0].isEmpty)
        XCTAssertTrue(steps[1].first === first)
        XCTAssertTrue(steps[2].first === second)
    }

    func testWithPreviousAndAfterPreviousJoinTheStepBeforeThem() {
        let slide = Slide(order: 0)
        let click = animatedElement(order: 0, trigger: .onClick)
        let withPrevious = animatedElement(order: 1, trigger: .withPrevious)
        let afterPrevious = animatedElement(order: 2, trigger: .afterPrevious)
        slide.addElement(click)
        slide.addElement(withPrevious)
        slide.addElement(afterPrevious)

        let steps = slide.animationSteps
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[1].count, 3, "both followers join the onClick step ahead of them, not steps of their own")
    }

    func testWithPreviousBeforeAnyOnClickJoinsTheAutoRevealStep() {
        let slide = Slide(order: 0)
        let withPrevious = animatedElement(order: 0, trigger: .withPrevious)
        slide.addElement(withPrevious)

        let steps = slide.animationSteps
        XCTAssertEqual(steps.count, 1, "nothing needs a click — it plays the moment the slide appears")
        XCTAssertTrue(steps[0].first === withPrevious)
    }

    func testElementsWithNoAnimationAreExcludedEntirely() {
        let slide = Slide(order: 0)
        let plain = SlideElement(kind: .text) // .none
        let animated = animatedElement(order: 0)
        slide.addElement(plain)
        slide.addElement(animated)

        let steps = slide.animationSteps
        XCTAssertFalse(steps.contains { $0.contains { $0 === plain } })
    }
}

/// Coverage for the "new animation plays last by default" auto-ordering
/// the element context menu relies on — see `Slide.nextAnimationOrder()`.
final class SlideNextAnimationOrderTests: XCTestCase {
    private func animatedElement(order: Int) -> SlideElement {
        let element = SlideElement(kind: .text)
        element.animationKind = .fadeIn
        element.animationOrder = order
        return element
    }

    func testASlideWithNoAnimatedElementsStartsAtZero() {
        let slide = Slide(order: 0)
        slide.addElement(SlideElement(kind: .text)) // .none, doesn't count
        XCTAssertEqual(slide.nextAnimationOrder(), 0)
    }

    func testReturnsOnePastTheCurrentHighestOrder() {
        let slide = Slide(order: 0)
        slide.addElement(animatedElement(order: 0))
        slide.addElement(animatedElement(order: 3))
        XCTAssertEqual(slide.nextAnimationOrder(), 4, "one past the highest (3), regardless of how many elements share lower orders")
    }

    func testUnanimatedElementsDoNotAffectTheResult() {
        let slide = Slide(order: 0)
        slide.addElement(animatedElement(order: 1))
        let plain = SlideElement(kind: .text) // .none, animationOrder left at its 0 default
        plain.animationOrder = 99 // meaningless while animationKind == .none — must be ignored
        slide.addElement(plain)
        XCTAssertEqual(slide.nextAnimationOrder(), 2, "the unanimated element's stray animationOrder value must not leak in")
    }
}

final class SlideElementRichTextTests: XCTestCase {
    func testBodyRoundTripsThroughDocumentBodyEncoding() {
        let element = SlideElement(kind: .text)
        element.body = NSAttributedString(string: "見出し")
        XCTAssertEqual(element.body.string, "見出し")
    }

    func testDefaultTextAttributesUsesThePlaceholdersFontSizeAndWeight() {
        let layout = SlideLayoutTemplate(name: "テスト", order: 0)
        let placeholder = layout.addPlaceholder(role: .title, kind: .text, centerX: 0.5, centerY: 0.1, width: 0.8, height: 0.2)
        placeholder.defaultFontSize = 40
        placeholder.defaultIsBold = true
        let element = SlideElement(kind: .text)
        element.sourcePlaceholder = placeholder

        let attributes = element.defaultTextAttributes()
        let font = attributes[.font] as? UIFont
        XCTAssertEqual(font?.pointSize, 40)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    func testDefaultTextAttributesFallsBackToAPlainDefaultWithNoPlaceholder() {
        let element = SlideElement(kind: .text)
        let attributes = element.defaultTextAttributes()
        let font = attributes[.font] as? UIFont
        XCTAssertEqual(font?.pointSize, 18)
        XCTAssertFalse(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }
}

final class SlideListTextTests: XCTestCase {
    func testSettingAListKindMarksTheWholeParagraphNotJustTheSelectedRange() {
        let text = NSMutableAttributedString(string: "箇条書きの項目です")
        SlideListText.setListKind(.bulleted, level: 0, forRange: NSRange(location: 2, length: 1), in: text)

        XCTAssertEqual(SlideListText.listKind(at: 0, in: text), .bulleted)
        XCTAssertEqual(SlideListText.listKind(at: text.length - 1, in: text), .bulleted)
    }

    func testClearingAListKindRemovesBothAttributes() {
        let text = NSMutableAttributedString(string: "項目")
        SlideListText.setListKind(.numbered, level: 1, forRange: NSRange(location: 0, length: 2), in: text)
        SlideListText.setListKind(nil, level: 0, forRange: NSRange(location: 0, length: 2), in: text)

        XCTAssertNil(SlideListText.listKind(at: 0, in: text))
        XCTAssertEqual(SlideListText.listLevel(at: 0, in: text), 0)
    }

    func testMarkersGivesBulletGlyphsByLevelAndLeavesPlainParagraphsUnmarked() {
        let text = NSMutableAttributedString(string: "見出し\n項目1\n子項目\n")
        let lines = text.string.components(separatedBy: "\n")
        // "見出し" (plain), "項目1" (level 0 bullet), "子項目" (level 1 bullet)
        var location = lines[0].utf16.count + 1
        SlideListText.setListKind(.bulleted, level: 0, forRange: NSRange(location: location, length: lines[1].utf16.count), in: text)
        location += lines[1].utf16.count + 1
        SlideListText.setListKind(.bulleted, level: 1, forRange: NSRange(location: location, length: lines[2].utf16.count), in: text)

        let markers = SlideListText.markers(for: text)
        XCTAssertEqual(markers[0].marker, nil, "the heading paragraph has no list formatting")
        XCTAssertEqual(markers[1].marker, "•")
        XCTAssertEqual(markers[2].marker, "◦", "a level-1 bullet uses the second glyph")
    }

    func testMarkersNumbersConsecutiveSameLevelItemsAndRestartsAfterABreak() {
        let text = NSMutableAttributedString(string: "一つ目\n二つ目\n見出し\nまた一つ目\n")
        let lines = text.string.components(separatedBy: "\n")
        var location = 0
        SlideListText.setListKind(.numbered, level: 0, forRange: NSRange(location: location, length: lines[0].utf16.count), in: text)
        location += lines[0].utf16.count + 1
        SlideListText.setListKind(.numbered, level: 0, forRange: NSRange(location: location, length: lines[1].utf16.count), in: text)
        location += lines[1].utf16.count + 1
        location += lines[2].utf16.count + 1 // "見出し" stays a plain paragraph
        SlideListText.setListKind(.numbered, level: 0, forRange: NSRange(location: location, length: lines[3].utf16.count), in: text)

        let markers = SlideListText.markers(for: text)
        XCTAssertEqual(markers[0].marker, "1.")
        XCTAssertEqual(markers[1].marker, "2.")
        XCTAssertEqual(markers[2].marker, nil)
        XCTAssertEqual(markers[3].marker, "1.", "a non-list paragraph in between must restart the numbering, not continue it")
    }

    func testMarkerUsesLetterAndRomanNumeralsForDeeperNumberedLevels() {
        XCTAssertEqual(SlideListText.marker(kind: .numbered, level: 0, position: 1), "1.")
        XCTAssertEqual(SlideListText.marker(kind: .numbered, level: 1, position: 2), "b.")
        XCTAssertEqual(SlideListText.marker(kind: .numbered, level: 2, position: 4), "iv.")
    }
}

/// Coverage for design step 9: converting a deck built on the legacy
/// fixed-layout fields into the canvas-based `master`/`elements` model.
final class SlideBlockMigrationTests: XCTestCase {
    func testMigrationSeedsTheMasterFromTheDecksTheme() {
        let deck = SlideDeck(title: "テスト")
        deck.theme = .midnight
        let slide = Slide(order: 0, layout: .titleAndBody)
        slide.titleText = "見出し"
        deck.addSlide(slide)
        slide.deck = deck

        SlideBlockMigration.migrateIfNeeded(deck)

        XCTAssertNotNil(deck.master)
        XCTAssertEqual(deck.master?.titleColorHex.uppercased(), "#FFFFFF", "midnight's titleColor is plain white")
    }

    func testMigrationConvertsTitleAndBodyIntoRoleLinkedElements() {
        let deck = SlideDeck(title: "テスト")
        let slide = Slide(order: 0, layout: .titleAndBody)
        slide.titleText = "見出し"
        slide.bodyText = "一つ目\n二つ目"
        deck.addSlide(slide)
        slide.deck = deck

        SlideBlockMigration.migrateIfNeeded(deck)

        XCTAssertEqual(slide.element(for: .title)?.body.string, "見出し")
        let bodyElement = slide.element(for: .body)
        XCTAssertEqual(bodyElement?.body.string, "一つ目\n二つ目")
        XCTAssertNotNil(bodyElement.flatMap { SlideListText.listKind(at: 0, in: $0.body) }, "a titleAndBody slide's content must migrate as a real bulleted list")
    }

    func testMigrationConvertsATitleSlidesBodyAsAPlainSubtitleNotABulletedList() {
        let deck = SlideDeck(title: "テスト")
        let slide = Slide(order: 0, layout: .titleSlide)
        slide.titleText = "タイトル"
        slide.bodyText = "サブタイトル文"
        deck.addSlide(slide)
        slide.deck = deck

        SlideBlockMigration.migrateIfNeeded(deck)

        let subtitleElement = slide.element(for: .subtitle)
        XCTAssertEqual(subtitleElement?.body.string, "サブタイトル文")
        XCTAssertNil(subtitleElement.flatMap { SlideListText.listKind(at: 0, in: $0.body) }, "a title slide's subtitle must not become a bulleted list")
    }

    func testMigrationConvertsTwoContentBothColumns() {
        let deck = SlideDeck(title: "テスト")
        let slide = Slide(order: 0, layout: .twoContent)
        slide.bodyText = "左"
        slide.secondaryText = "右"
        deck.addSlide(slide)
        slide.deck = deck

        SlideBlockMigration.migrateIfNeeded(deck)

        XCTAssertEqual(slide.element(for: .body)?.body.string, "左")
        XCTAssertEqual(slide.element(for: .secondaryBody)?.body.string, "右")
    }

    func testMigrationConvertsAnImageSlide() {
        let deck = SlideDeck(title: "テスト")
        let slide = Slide(order: 0, layout: .titleAndImage)
        slide.titleText = "写真つき"
        slide.imageData = Data([0x01, 0x02, 0x03])
        deck.addSlide(slide)
        slide.deck = deck

        SlideBlockMigration.migrateIfNeeded(deck)

        XCTAssertEqual(slide.element(for: .image)?.imageData, Data([0x01, 0x02, 0x03]))
    }

    func testMigrationSkipsEmptyLegacyFields() {
        let deck = SlideDeck(title: "テスト")
        let slide = Slide(order: 0, layout: .titleAndBody)
        slide.titleText = "見出しのみ"
        deck.addSlide(slide)
        slide.deck = deck

        SlideBlockMigration.migrateIfNeeded(deck)

        XCTAssertNotNil(slide.element(for: .title))
        XCTAssertNil(slide.element(for: .body), "an empty legacy field must not create a blank element")
    }

    func testMigrationNeverClearsTheLegacyFields() {
        let deck = SlideDeck(title: "テスト")
        let slide = Slide(order: 0, layout: .titleAndBody)
        slide.titleText = "見出し"
        slide.bodyText = "本文"
        deck.addSlide(slide)
        slide.deck = deck

        SlideBlockMigration.migrateIfNeeded(deck)

        XCTAssertEqual(slide.titleText, "見出し")
        XCTAssertEqual(slide.bodyText, "本文")
    }

    func testMigrationIsIdempotentAndDoesNotDuplicateElementsOnASecondCall() {
        let deck = SlideDeck(title: "テスト")
        let slide = Slide(order: 0, layout: .titleAndBody)
        slide.titleText = "見出し"
        deck.addSlide(slide)
        slide.deck = deck

        SlideBlockMigration.migrateIfNeeded(deck)
        let countAfterFirst = slide.sortedElements.count
        SlideBlockMigration.migrateIfNeeded(deck)

        XCTAssertEqual(slide.sortedElements.count, countAfterFirst)
    }

    func testMigrationPicksUpASlideAddedAfterTheDeckWasAlreadyMigratedOnce() {
        let deck = SlideDeck(title: "テスト")
        let first = Slide(order: 0, layout: .titleAndBody)
        first.titleText = "最初"
        deck.addSlide(first)
        first.deck = deck
        SlideBlockMigration.migrateIfNeeded(deck)
        XCTAssertNotNil(deck.master, "sanity check: the deck was actually migrated once already")

        let second = Slide(order: 1, layout: .titleAndBody)
        second.titleText = "後から追加"
        deck.addSlide(second)
        second.deck = deck

        SlideBlockMigration.migrateIfNeeded(deck)

        XCTAssertNotNil(second.layout, "a slide added after the deck's first migration must still be migrated on the next call")
        XCTAssertEqual(second.element(for: .title)?.body.string, "後から追加")
    }
}

/// Coverage for design step 4's grouping command (`Slide.group`/`ungroup`),
/// building on `SlideGroupTests`' coverage of `SlideElement.moveGroup`.
final class SlideGroupCommandTests: XCTestCase {
    func testGroupingTwoElementsCreatesAGroupSizedToTheirCombinedBounds() {
        let slide = Slide(order: 0)
        let a = SlideElement(kind: .rectangle)
        a.overrideCenterX = 0.2; a.overrideCenterY = 0.2
        a.overrideWidth = 0.1; a.overrideHeight = 0.1
        let b = SlideElement(kind: .ellipse)
        b.overrideCenterX = 0.5; b.overrideCenterY = 0.4
        b.overrideWidth = 0.1; b.overrideHeight = 0.1
        slide.addElement(a)
        slide.addElement(b)

        guard let group = slide.group([a, b]) else { return XCTFail("grouping 2 elements must not be a no-op") }

        XCTAssertEqual(group.kind, .group)
        // a spans 0.15...0.25, b spans 0.45...0.55 → combined 0.15...0.55
        XCTAssertEqual(group.centerX, 0.35, accuracy: 0.0001)
        XCTAssertEqual(group.width, 0.4, accuracy: 0.0001)
        XCTAssertTrue(a.parentGroup === group)
        XCTAssertTrue(b.parentGroup === group)
    }

    func testGroupingFewerThanTwoElementsIsANoOp() {
        let slide = Slide(order: 0)
        let a = SlideElement(kind: .rectangle)
        slide.addElement(a)

        let group = slide.group([a])

        XCTAssertNil(group)
        XCTAssertEqual(slide.sortedElements.count, 1, "no group element should have been created")
    }

    func testGroupingBakesInGeometryForAStillInheritingMember() {
        let layout = SlideLayoutTemplate(name: "テスト", order: 0)
        let placeholder = layout.addPlaceholder(role: .title, kind: .text, centerX: 0.3, centerY: 0.3, width: 0.1, height: 0.1)
        let slide = Slide(order: 0)
        let inheriting = SlideElement(kind: .text)
        inheriting.sourcePlaceholder = placeholder
        let free = SlideElement(kind: .rectangle)
        free.overrideCenterX = 0.6; free.overrideCenterY = 0.6
        free.overrideWidth = 0.1; free.overrideHeight = 0.1
        slide.addElement(inheriting)
        slide.addElement(free)

        slide.group([inheriting, free])

        XCTAssertFalse(inheriting.isInheritingGeometry, "grouping must detach a member from its placeholder, same as a direct move would")
    }

    func testUngroupingRemovesTheGroupAndLeavesMembersWhereTheyWere() {
        let slide = Slide(order: 0)
        let a = SlideElement(kind: .rectangle)
        a.overrideCenterX = 0.2; a.overrideCenterY = 0.2
        a.overrideWidth = 0.1; a.overrideHeight = 0.1
        let b = SlideElement(kind: .ellipse)
        b.overrideCenterX = 0.5; b.overrideCenterY = 0.4
        b.overrideWidth = 0.1; b.overrideHeight = 0.1
        slide.addElement(a)
        slide.addElement(b)
        guard let group = slide.group([a, b]) else { return XCTFail("setup failed") }

        slide.ungroup(group)

        XCTAssertNil(a.parentGroup)
        XCTAssertNil(b.parentGroup)
        XCTAssertEqual(a.centerX, 0.2, accuracy: 0.0001, "members must stay exactly where they were")
        XCTAssertFalse(slide.sortedElements.contains { $0 === group }, "the group element itself must be removed")
        XCTAssertTrue(slide.sortedElements.contains { $0 === a })
        XCTAssertTrue(slide.sortedElements.contains { $0 === b })
    }
}
