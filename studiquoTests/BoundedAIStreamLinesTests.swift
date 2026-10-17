import XCTest
@testable import studiquo

final class BoundedAIStreamLinesTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        func bump() { lock.lock(); defer { lock.unlock() }; stored += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return stored }
    }
    private struct Bytes: AsyncSequence, Sendable {
        typealias Element = UInt8
        let values: [UInt8]
        let counter: Counter?
        init(_ values: [UInt8], counter: Counter? = nil) { self.values = values; self.counter = counter }
        struct AsyncIterator: AsyncIteratorProtocol {
            let values: [UInt8]
            let counter: Counter?
            var index = 0
            mutating func next() async throws -> UInt8? {
                counter?.bump()
                guard index < values.count else { return nil }
                defer { index += 1 }
                return values[index]
            }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(values: values, counter: counter) }
    }
    private struct InfiniteBytes: AsyncSequence, Sendable {
        typealias Element = UInt8
        let counter: Counter
        struct AsyncIterator: AsyncIteratorProtocol {
            let counter: Counter
            mutating func next() async throws -> UInt8? { counter.bump(); return 65 }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(counter: counter) }
    }
    private actor StartGate {
        var started = false
        var waiting: CheckedContinuation<Void, Never>?
        func signal() { started = true; waiting?.resume(); waiting = nil }
        func wait() async {
            if started { return }
            await withCheckedContinuation { waiting = $0 }
        }
    }
    private struct SlowBytes: AsyncSequence, Sendable {
        typealias Element = UInt8
        let gate: StartGate
        struct AsyncIterator: AsyncIteratorProtocol {
            let gate: StartGate
            mutating func next() async throws -> UInt8? {
                await gate.signal()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return 65
            }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(gate: gate) }
    }
    private func collect(_ text: String) async throws -> [String] {
        var lines: [String] = []
        for try await line in try BoundedAIStreamLines(Bytes(Array(text.utf8))) { lines.append(line) }
        return lines
    }
    func testCRLFEmptyLinesTrailingEOFAndUnicode() async throws {
        for (text, expected) in [("one\r\n\r\n日本語😀\nlast", ["one", "", "日本語😀", "last"]), ("a\rb\r", ["a", "b"]), ("", []), ("\n", [""])] {
            let actual = try await collect(text)
            XCTAssertEqual(actual, expected)
        }
    }
    func testPullBasedIterationDoesNotReadAhead() async throws {
        let counter = Counter()
        var iterator = try BoundedAIStreamLines(Bytes(Array("first\nsecond\n".utf8), counter: counter)).makeAsyncIterator()
        XCTAssertEqual(counter.count, 0)
        let first = try await iterator.next()
        XCTAssertEqual(first, "first")
        XCTAssertEqual(counter.count, 6)
        let second = try await iterator.next()
        XCTAssertEqual(second, "second")
        XCTAssertEqual(counter.count, 13)
    }
    func testMaximum512KiBLineAcceptsCRLFDelimiter() async throws {
        var iterator = try BoundedAIStreamLines(Bytes(Array(repeating: 65, count: 512 * 1024) + [13, 10])).makeAsyncIterator()
        let line = try await iterator.next()
        XCTAssertEqual(line?.utf8.count, 512 * 1024)
        let end = try await iterator.next()
        XCTAssertNil(end)
    }
    func testInfiniteLineStopsAtFirstExcessByteAndIteratorStaysFinished() async throws {
        let counter = Counter()
        var iterator = try BoundedAIStreamLines(InfiniteBytes(counter: counter), maximumBytes: 16).makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Must bound an endless line") }
        catch { XCTAssertEqual(error as? BoundedAIStreamError, .lineTooLarge) }
        XCTAssertEqual(counter.count, 17)
        let end = try await iterator.next()
        XCTAssertNil(end)
        XCTAssertEqual(counter.count, 17)
    }
    func testInvalidUTF8NeverProducesReplacementText() async throws {
        for bytes: [UInt8] in [[0xC3, 0x28, 10], [0xE3, 0x81], [0x80, 10], [0xC0, 0xAF, 10]] {
            var iterator = try BoundedAIStreamLines(Bytes(bytes)).makeAsyncIterator()
            do { _ = try await iterator.next(); XCTFail("Must reject malformed UTF-8") }
            catch { XCTAssertEqual(error as? BoundedAIStreamError, .invalidUTF8) }
        }
    }
    func testLimitCountsUTF8BytesInsteadOfCharacters() async throws {
        var iterator = try BoundedAIStreamLines(Bytes(Array("あい\n".utf8)), maximumBytes: 5).makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Two Japanese characters exceed five UTF-8 bytes") }
        catch { XCTAssertEqual(error as? BoundedAIStreamError, .lineTooLarge) }
    }
    func testInvalidLineLimitsAreRejected() throws {
        for limit in [-1, 0, 512 * 1024 + 1] {
            XCTAssertThrowsError(try BoundedAIStreamLines(Bytes([]), maximumBytes: limit))
        }
    }
    func testCancellationBeforeReadConsumesNoBytes() async throws {
        let counter = Counter()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            var iterator = try BoundedAIStreamLines(InfiniteBytes(counter: counter)).makeAsyncIterator()
            return try await iterator.next()
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must be preserved") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(counter.count, 0)
    }
    func testCancellationDuringPendingByteReadStopsIterator() async throws {
        let gate = StartGate()
        let task = Task {
            var iterator = try BoundedAIStreamLines(SlowBytes(gate: gate)).makeAsyncIterator()
            return try await iterator.next()
        }
        await gate.wait()
        task.cancel()
        do { _ = try await task.value; XCTFail("Pending read must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testErrorBodyCancellationBeforeReadConsumesNoBytes() async throws {
        let counter = Counter()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await BoundedAIStreamBody.read(InfiniteBytes(counter: counter))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Error body read must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(counter.count, 0)
    }
    func testErrorBodyMaximumAndFirstExcessByteAreBounded() async throws {
        let good = try await BoundedAIStreamBody.read(Bytes(Array(repeating: 65, count: 64 * 1024)))
        XCTAssertEqual(good.count, 64 * 1024)
        let counter = Counter()
        do { _ = try await BoundedAIStreamBody.read(InfiniteBytes(counter: counter), maximumBytes: 16); XCTFail("Must stop oversized HTTP error") }
        catch { XCTAssertEqual(error as? BoundedAIStreamError, .bodyTooLarge) }
        XCTAssertEqual(counter.count, 17)
    }
    func testErrorBodyRejectsInvalidUTF8AndLimits() async throws {
        do { _ = try await BoundedAIStreamBody.read(Bytes([0xFF])); XCTFail("Invalid UTF-8 must fail") }
        catch { XCTAssertEqual(error as? BoundedAIStreamError, .invalidUTF8) }
        for limit in [0, 64 * 1024 + 1] {
            do { _ = try await BoundedAIStreamBody.read(Bytes([]), maximumBytes: limit); XCTFail("Invalid bound") }
            catch { XCTAssertEqual(error as? BoundedAIStreamError, .invalidLimit) }
        }
    }
}
