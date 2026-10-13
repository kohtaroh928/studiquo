import XCTest
@testable import studiquo

final class HomeSelectionTests: XCTestCase {
    func testToggleSelectsAndDeselects() {
        var selection = HomeSelection()
        selection.begin()
        selection.toggle("notebook:1")
        XCTAssertTrue(selection.contains("notebook:1"))
        XCTAssertEqual(selection.count, 1)
        selection.toggle("notebook:1")
        XCTAssertFalse(selection.contains("notebook:1"))
        XCTAssertTrue(selection.isEmpty)
        XCTAssertTrue(selection.isActive)
    }

    func testSelectAllAddsToExistingSelectionWithoutDuplicates() {
        var selection = HomeSelection()
        selection.begin()
        selection.toggle("deck:1")
        selection.select(["deck:1", "folder:2", "document:3"])
        XCTAssertEqual(selection.tokens, ["deck:1", "folder:2", "document:3"])
    }

    func testClearKeepsSelectionModeButEndForgetsEverything() {
        var selection = HomeSelection()
        selection.begin()
        selection.select(["a", "b"])
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertTrue(selection.isActive)

        selection.select(["a"])
        selection.end()
        XCTAssertFalse(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }

    func testSelectionSurvivesWhileBrowsingBecauseItIsIndependentOfLocation() {
        // The selection only stores identifiers, so entering another folder
        // (which changes what is on screen) cannot drop earlier choices.
        var selection = HomeSelection()
        selection.begin()
        selection.select(["notebook:in-folder-a"])
        selection.select(["notebook:in-folder-b"])
        XCTAssertEqual(selection.count, 2)
    }

    func testPruneRemovesItemsThatNoLongerExist() {
        var selection = HomeSelection()
        selection.begin()
        selection.select(["notebook:1", "notebook:2", "folder:3"])
        selection.prune(keeping: ["notebook:1", "folder:3", "deck:9"])
        XCTAssertEqual(selection.tokens, ["notebook:1", "folder:3"])
    }

    func testIsInsideMatchesWholePathComponentsOnly() {
        XCTAssertTrue(HomeSelectionRules.isInside("数学", orEqualTo: "数学"))
        XCTAssertTrue(HomeSelectionRules.isInside("数学/代数", orEqualTo: "数学"))
        XCTAssertFalse(HomeSelectionRules.isInside("数学2", orEqualTo: "数学"))
        XCTAssertFalse(HomeSelectionRules.isInside("数学", orEqualTo: "数学/代数"))
    }

    func testTopLevelFolderPathsDropsNestedFolders() {
        let paths = ["数学", "数学/代数", "英語", "英語/文法/時制", "理科2"]
        XCTAssertEqual(
            HomeSelectionRules.topLevelFolderPaths(paths),
            ["数学", "英語", "理科2"]
        )
    }

    func testIsCoveredIgnoresRootAndUnrelatedPaths() {
        let roots = ["数学"]
        XCTAssertTrue(HomeSelectionRules.isCovered("数学", byFolderRoots: roots))
        XCTAssertTrue(HomeSelectionRules.isCovered("数学/代数", byFolderRoots: roots))
        XCTAssertFalse(HomeSelectionRules.isCovered("", byFolderRoots: roots))
        XCTAssertFalse(HomeSelectionRules.isCovered("数学2", byFolderRoots: roots))
    }

    func testFolderCannotBeMovedIntoItselfOrItsDescendants() {
        let moving = ["数学", "英語/文法"]
        XCTAssertTrue(HomeSelectionRules.isMoveDestinationBlocked("数学", movingFolderPaths: moving))
        XCTAssertTrue(HomeSelectionRules.isMoveDestinationBlocked("数学/代数", movingFolderPaths: moving))
        XCTAssertTrue(HomeSelectionRules.isMoveDestinationBlocked("英語/文法/時制", movingFolderPaths: moving))
        XCTAssertFalse(HomeSelectionRules.isMoveDestinationBlocked("英語", movingFolderPaths: moving))
        XCTAssertFalse(HomeSelectionRules.isMoveDestinationBlocked("理科", movingFolderPaths: moving))
        XCTAssertFalse(HomeSelectionRules.isMoveDestinationBlocked(nil, movingFolderPaths: moving))
    }
}
