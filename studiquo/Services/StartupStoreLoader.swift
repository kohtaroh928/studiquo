import Foundation
import Combine

/// Owns one store-open operation across window appearances. A synchronous
/// store open cannot be cancelled: the deadline changes the UI, but must
/// neither wait for that operation nor open the same store a second time.
@MainActor
final class StartupStoreLoader<Value: Sendable>: ObservableObject {
    enum State {
        case idle
        case loading
        case delayed
        case failed(String)
        case ready(Value)
    }

    @Published private(set) var state: State = .idle
    private let timeout: TimeInterval
    private let openStore: @Sendable () throws -> Value
    private var deadline: DispatchWorkItem?
    private var attemptID: UUID?

    init(timeout: TimeInterval = 10, openStore: @escaping @Sendable () throws -> Value) {
        self.timeout = timeout
        self.openStore = openStore
    }

    func start() {
        switch state {
        case .idle, .failed: break
        case .loading, .delayed, .ready: return
        }

        state = .loading
        let id = UUID()
        attemptID = id
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.attemptID == id else { return }
            self.state = .delayed
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)

        // Do not put this in a TaskGroup: leaving a group waits for all of
        // its children, including a cancelled child awaiting a continuation.
        let openStore = self.openStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try openStore() }
            Task { @MainActor [weak self] in
                guard let self, self.attemptID == id else { return }
                self.deadline?.cancel()
                self.deadline = nil
                self.attemptID = nil
                switch result {
                case .success(let value): self.state = .ready(value)
                case .failure(let error): self.state = .failed(error.localizedDescription)
                }
            }
        }
    }
}
