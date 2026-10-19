import Foundation
import XCTest
@testable import studiquo

@MainActor
final class FriendInviteAndModerationPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FriendInviteAndModerationPolicyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 1. QRScanRoutingPolicy & FriendStore.add(url:) Phishing / External Domain Protection

    func testQRScanRoutingPolicyRejectsUnsafeSchemesAndAcceptsCaseInsensitiveInviteSchemes() {
        XCTAssertTrue(QRScanRoutingPolicy.isInviteLink("HTTPS://api.studiquo.app/invite?token=T1"))
        XCTAssertTrue(QRScanRoutingPolicy.isInviteLink("STUDIQUO://friend/add?token=T1"))

        for unsafe in [
            "http://api.studiquo.app/invite?token=T1",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,<script>alert(1)</script>",
            "mailto:user@example.com",
            "MANUALCODE1",
        ] {
            XCTAssertFalse(QRScanRoutingPolicy.isInviteLink(unsafe), "Scheme must be rejected: \(unsafe)")
        }
    }

    func testFriendStoreAddURLRejectsExternalDomainsAndNonInvitePathsWithoutStagingToken() throws {
        let store = FriendStore(defaults: defaults, autoRefresh: false)

        let rejectedURLs = [
            "https://evil.example.com/invite?token=PHISHING_TOKEN",
            "https://api.studiquo.app.evil.com/invite?token=SUBDOMAIN_SPOOF",
            "https://api.studiquo.app/other-path?token=WRONG_PATH",
            "studiquo://other-host/add?token=WRONG_HOST",
            "studiquo://friend/other?token=WRONG_CUSTOM_PATH",
            "http://api.studiquo.app/invite?token=INSECURE_HTTP",
        ]

        for raw in rejectedURLs {
            let url = try XCTUnwrap(URL(string: raw))
            store.add(url: url)
            XCTAssertNil(store.pendingLinkToken, "External/malformed URL must not stage pendingLinkToken: \(raw)")
            XCTAssertNil(store.pendingDeepLinkCode, "External/malformed URL must not stage pendingDeepLinkCode: \(raw)")
        }
    }

    func testFriendStoreAddURLStagesTokenOrCodeOnlyForAuthenticUniversalOrCustomSchemeLinks() throws {
        let store = FriendStore(defaults: defaults, autoRefresh: false)

        // 1. Universal Link with token
        let universalURL = try XCTUnwrap(URL(string: "https://api.studiquo.app/invite?token=UNIV_TOKEN_123"))
        store.add(url: universalURL)
        XCTAssertEqual(store.pendingLinkToken, "UNIV_TOKEN_123")
        store.cancelPendingLinkAdd()
        XCTAssertNil(store.pendingLinkToken)

        // 2. Legacy custom scheme with token
        let customTokenURL = try XCTUnwrap(URL(string: "studiquo://friend/add?token=CUSTOM_TOKEN_456"))
        store.add(url: customTokenURL)
        XCTAssertEqual(store.pendingLinkToken, "CUSTOM_TOKEN_456")
        store.cancelPendingLinkAdd()

        // 3. Legacy custom scheme with manual code
        let customCodeURL = try XCTUnwrap(URL(string: "studiquo://friend/add?code=FRIEND88"))
        store.add(url: customCodeURL)
        XCTAssertEqual(store.pendingDeepLinkCode, "FRIEND88")
        store.cancelPendingDeepLinkRequest()
        XCTAssertNil(store.pendingDeepLinkCode)
    }

    func testConfirmPendingLinkAddBlocksSelfInviteImmediately() throws {
        defaults.set("SELF_CODE", forKey: "studiquoFriendCode")
        defaults.set("MY_OWN_LINK_TOKEN", forKey: "studiquoFriendLinkToken")
        let store = FriendStore(defaults: defaults, autoRefresh: false)

        let selfURL = try XCTUnwrap(URL(string: "https://api.studiquo.app/invite?token=MY_OWN_LINK_TOKEN"))
        store.add(url: selfURL)
        XCTAssertEqual(store.pendingLinkToken, "MY_OWN_LINK_TOKEN")

        store.confirmPendingLinkAdd()
        XCTAssertNil(store.pendingLinkToken)
        XCTAssertEqual(store.errorMessage, "自分自身をフレンドに追加することはできません。")
    }

    // MARK: - 2. NoteChatSplitPolicy Group & Attachment Routing

    func testNoteChatSplitPolicyHandlesGroupTargetsAndAttachmentNonCollapsingRouting() {
        let friendA = NoteChatTarget.friend(UUID())
        let group1 = NoteChatTarget.group(roomID: "group-room-1")
        let group2 = NoteChatTarget.group(roomID: "group-room-2")

        // Tapping an already-visible group collapses it:
        XCTAssertEqual(
            NoteChatSplitPolicy.action(forTapping: group1, primaryTarget: nil, secondaryTarget: group1),
            .collapse
        )
        // Tapping a different group when primary holds a chat replaces primary instead of opening two chats:
        XCTAssertEqual(
            NoteChatSplitPolicy.action(forTapping: group2, primaryTarget: friendA, secondaryTarget: nil),
            .openInPrimary
        )

        // Attachment routing never collapses an already-open target:
        XCTAssertEqual(
            NoteChatSplitPolicy.actionForAttachment(
                to: group1,
                sourcePane: .primary,
                primaryTarget: nil,
                secondaryTarget: group1
            ),
            .openInSecondary
        )
        XCTAssertEqual(
            NoteChatSplitPolicy.actionForAttachment(
                to: group1,
                sourcePane: .secondary,
                primaryTarget: group1,
                secondaryTarget: nil
            ),
            .openInPrimary
        )
        // When target is not open anywhere, opens in the opposite pane from sourcePane:
        XCTAssertEqual(
            NoteChatSplitPolicy.actionForAttachment(
                to: group2,
                sourcePane: .primary,
                primaryTarget: nil,
                secondaryTarget: nil
            ),
            .openInSecondary
        )
        XCTAssertEqual(
            NoteChatSplitPolicy.actionForAttachment(
                to: group2,
                sourcePane: .secondary,
                primaryTarget: nil,
                secondaryTarget: nil
            ),
            .openInPrimary
        )
    }

    // MARK: - 3. FriendChatService Read-Only Retry Policy

    func testFriendChatServiceNeverRetriesMutatingMethodsEvenOnServerOrTimeoutErrors() {
        for method in ["POST", "PUT", "DELETE", "PATCH"] {
            XCTAssertFalse(
                FriendChatService.shouldRetryReadRequest(method: method, statusCode: 503),
                "\(method) must never be auto-retried on 503"
            )
            XCTAssertFalse(
                FriendChatService.shouldRetryReadRequest(method: method, error: URLError(.timedOut)),
                "\(method) must never be auto-retried on timeout"
            )
        }
        XCTAssertTrue(FriendChatService.shouldRetryReadRequest(method: "GET", statusCode: 502))
        XCTAssertFalse(FriendChatService.shouldRetryReadRequest(method: "GET", statusCode: 429))
        XCTAssertFalse(FriendChatService.shouldRetryReadRequest(method: "GET", statusCode: 401))
    }
}
