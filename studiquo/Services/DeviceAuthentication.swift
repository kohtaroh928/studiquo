import LocalAuthentication

/// A single place to ask "is this really the device owner?" — Face
/// ID/Touch ID, falling back to the device passcode.
enum DeviceAuthentication {
    /// Returns `false` both when authentication fails and when it can't be
    /// attempted at all (no LocalAuthentication support on this device),
    /// since every caller treats the two identically: don't proceed.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        return await authenticate(
            reason: reason,
            canEvaluate: {
                var error: NSError?
                return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
            },
            evaluate: { localizedReason in
                try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: localizedReason
                )
            }
        )
    }

    /// For actions that must not be blocked on a device that has no passcode
    /// or biometrics at all (deleting one's own account has to stay possible):
    /// asks when the device can ask, and says so when it can't.
    enum Outcome: Equatable { case confirmed, declined, unavailable }

    static func confirmIfPossible(reason: String) async -> Outcome {
        let context = LAContext()
        return await confirmIfPossible(
            reason: reason,
            canEvaluate: {
                var error: NSError?
                return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
            },
            evaluate: { localizedReason in
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: localizedReason)
            }
        )
    }

    static func confirmIfPossible(
        reason: String,
        canEvaluate: () -> Bool,
        evaluate: (String) async throws -> Bool
    ) async -> Outcome {
        guard canEvaluate() else { return .unavailable }
        return ((try? await evaluate(reason)) ?? false) ? .confirmed : .declined
    }

    static func authenticate(
        reason: String,
        canEvaluate: () -> Bool,
        evaluate: (String) async throws -> Bool
    ) async -> Bool {
        guard canEvaluate() else { return false }
        return (try? await evaluate(reason)) ?? false
    }
}
