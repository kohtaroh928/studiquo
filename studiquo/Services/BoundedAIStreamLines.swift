import Foundation

/// Fixed diagnostics only: never attach response bytes or a partial line.
enum BoundedAIStreamError: Error, Equatable {
    case invalidLimit
    case lineTooLarge
    case bodyTooLarge
    case invalidUTF8
}

/// Pulls exactly one bounded line on demand, with no producer task or queue.
/// Limits count UTF-8 content bytes, excluding LF/CRLF delimiters.
struct BoundedAIStreamLines<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String
    static var maximumLineBytes: Int { 512 * 1024 }
    private let base: Base
    private let maximumBytes: Int

    init(_ base: Base, maximumBytes: Int = 512 * 1024) throws {
        guard (1...Self.maximumLineBytes).contains(maximumBytes) else { throw BoundedAIStreamError.invalidLimit }
        self.base = base
        self.maximumBytes = maximumBytes
    }
    func makeAsyncIterator() -> Iterator { Iterator(base: base.makeAsyncIterator(), maximumBytes: maximumBytes) }

    struct Iterator: AsyncIteratorProtocol {
        private var base: Base.AsyncIterator
        private let maximumBytes: Int
        private var skipLF = false
        private var finished = false
        fileprivate init(base: Base.AsyncIterator, maximumBytes: Int) {
            self.base = base
            self.maximumBytes = maximumBytes
        }
        mutating func next() async throws -> String? {
            guard !finished else { return nil }
            var bytes = Data()
            do {
                while true {
                    try Task.checkCancellation()
                    let incoming = try await base.next()
                    try Task.checkCancellation()
                    guard let byte = incoming else {
                        finished = true
                        return bytes.isEmpty ? nil : try decode(bytes)
                    }
                    if skipLF {
                        skipLF = false
                        if byte == 10 { continue }
                    }
                    if byte == 13 {
                        skipLF = true
                        return try decode(bytes)
                    }
                    if byte == 10 { return try decode(bytes) }
                    guard bytes.count < maximumBytes else { throw BoundedAIStreamError.lineTooLarge }
                    bytes.append(byte)
                }
            } catch {
                finished = true
                try Task.checkCancellation()
                throw error
            }
        }
        private func decode(_ bytes: Data) throws -> String {
            guard let line = String(data: bytes, encoding: .utf8) else { throw BoundedAIStreamError.invalidUTF8 }
            return line
        }
    }
}

/// The underlying URLSession task is cancelled by the caller on all exit paths.
/// Reads at most limit+1 bytes, so a malicious HTTP error cannot grow Data forever.
enum BoundedAIStreamBody {
    static let maximumErrorBytes = 64 * 1024
    static func read<Base: AsyncSequence>(_ sequence: Base, maximumBytes: Int = maximumErrorBytes) async throws -> Data where Base.Element == UInt8 {
        guard (1...maximumErrorBytes).contains(maximumBytes) else { throw BoundedAIStreamError.invalidLimit }
        var result = Data()
        var iterator = sequence.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            let incoming = try await iterator.next()
            try Task.checkCancellation()
            guard let byte = incoming else { break }
            guard result.count < maximumBytes else { throw BoundedAIStreamError.bodyTooLarge }
            result.append(byte)
        }
        guard String(data: result, encoding: .utf8) != nil else { throw BoundedAIStreamError.invalidUTF8 }
        return result
    }
}
