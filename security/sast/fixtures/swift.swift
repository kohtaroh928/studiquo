import Foundation
func fixture(value: String, trust: SecTrust) {
    // ruleid: studiquo.swift.userdefaults-credential
    UserDefaults.standard.set(value, forKey: "accessToken")
    // ok: studiquo.swift.userdefaults-credential
    UserDefaults.standard.set(value, forKey: "theme")
    // ruleid: studiquo.swift.trust-all-challenge
    let unsafe = URLCredential(trust: trust)
    // ok: studiquo.swift.trust-all-challenge
    let safe = URLCredential(user: "fixture", password: "", persistence: .none)
}
func moreFixtures(accessToken: String, status: String, data: Data) {
    // ruleid: studiquo.swift.credential-log
    print(accessToken)
    // ok: studiquo.swift.credential-log
    print(status)
    // ruleid: studiquo.swift.weak-hash
    Insecure.MD5.hash(data: data)
    // ok: studiquo.swift.weak-hash
    SHA256.hash(data: data)
}
