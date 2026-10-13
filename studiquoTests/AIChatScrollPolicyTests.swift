import SwiftUI
import XCTest
@testable import studiquo

/// A chat must open on its newest message, not its first. The list used to
/// scroll only when the message count changed, so reopening a chat showed the top.
final class AIChatScrollPolicyTests: XCTestCase {
    func testExistingConversationOpensAtBottom() {
        XCTAssertEqual(AIChatScrollPolicy.anchor(messageCount: 1), .bottom)
        XCTAssertEqual(AIChatScrollPolicy.anchor(messageCount: 50), .bottom)
    }

    func testEmptyChatKeepsGreetingAtTop() {
        XCTAssertEqual(AIChatScrollPolicy.anchor(messageCount: 0), .top)
    }
}
