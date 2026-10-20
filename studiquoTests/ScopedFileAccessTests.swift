import XCTest
@testable import studiquo

final class ScopedFileAccessTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/sample.pdf")

    private final class Counter {
        var starts = 0
        var stops = 0
    }

    private func makeAccess(_ counter: Counter, grants: Bool = true) -> ScopedFileAccess {
        ScopedFileAccess(
            url: url,
            start: { _ in counter.starts += 1; return grants },
            stop: { _ in counter.stops += 1 }
        )
    }

    func testStartsOnInitAndStopsOnRelease() {
        let counter = Counter()
        let access = makeAccess(counter)
        XCTAssertEqual(counter.starts, 1, "生成時にアクセスを開始する必要があります。")
        XCTAssertTrue(access.hasScopedAccess)
        access.release()
        XCTAssertEqual(counter.stops, 1, "解放時にアクセスを終了する必要があります。")
    }

    func testReleaseIsIdempotent() {
        let counter = Counter()
        let access = makeAccess(counter)
        access.release()
        access.release()
        XCTAssertEqual(counter.stops, 1, "何度 release しても、終了は1回だけにする必要があります。")
    }

    func testDeinitStopsIfNeverReleased() {
        let counter = Counter()
        var access: ScopedFileAccess? = makeAccess(counter)
        XCTAssertNotNil(access)
        access = nil
        XCTAssertEqual(counter.stops, 1, "明示的に解放されなくても、破棄時にアクセスを終了する必要があります。")
    }

    func testDeinitAfterReleaseDoesNotStopTwice() {
        let counter = Counter()
        var access: ScopedFileAccess? = makeAccess(counter)
        access?.release()
        access = nil
        XCTAssertEqual(counter.stops, 1, "release 済みなら、破棄時に二重に終了してはいけません。")
    }

    func testDoesNotStopWhenAccessWasNotGranted() {
        let counter = Counter()
        var access: ScopedFileAccess? = makeAccess(counter, grants: false)
        XCTAssertFalse(access?.hasScopedAccess ?? true)
        access?.release()
        access = nil
        XCTAssertEqual(counter.stops, 0, "開始できなかったアクセスは、終了を呼んではいけません(開始と終了の数を揃える)。")
    }
}
