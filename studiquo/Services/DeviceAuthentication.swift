import LocalAuthentication

/// A single place to ask "is this really the device owner?" — Face
/// ID/Touch ID, falling back to the device passcode.
enum DeviceAuthentication {
    /// Returns `false` both when authentication fails and when it can't be
    /// attempted at all (no LocalAuthentication support on this device),
    /// since every caller treats the two identically: don't proceed.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
