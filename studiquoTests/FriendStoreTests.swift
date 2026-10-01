import XCTest
@testable import studiquo

@MainActor
final class FriendStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FriendStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMessageListURLUsesAQueryItemForTheCursor() throws {
        let roomID = String(repeating: "a", count: 64)
        let baseURL = try XCTUnwrap(URL(string: "https://example.com"))
        let url = FriendChatService.messageListURL(roomID: roomID, after: 42, baseURL: baseURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/api/chat/rooms/\(roomID)/messages")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "after", value: "42")])
        XCTAssertFalse(url.absoluteString.contains("%3F"))
    }

    // Regression coverage for "sharing the QR/invitation link before
    // registration finishes shares the placeholder text instead of a real
    // code": the add-friend screen must know not to show it yet.

    func testIsCodeReadyIsFalseOnAFreshInstallAndTrueAfterRegistering() async {
        let client = MockFriendChatClient(identity: .init(code: "ME1234", name: "Me", linkToken: "LINKME1"))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        XCTAssertFalse(store.isCodeReady, "a brand-new install has no persisted code yet")

        await store.refresh()

        XCTAssertTrue(store.isCodeReady)
        XCTAssertEqual(store.myCode, "ME1234")
    }

    func testIsCodeReadyIsTrueImmediatelyWhenALastKnownCodeWasAlreadyPersisted() {
        defaults.set("ME1234", forKey: "studiquoFriendCode")
        defaults.set("LINKME1", forKey: "studiquoFriendLinkToken")
        let store = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)

        XCTAssertTrue(store.isCodeReady, "a later launch already has a persisted code before refresh() ever runs")
    }

    // Regression coverage for "unread counts aren't persisted, so a
    // relaunch silently resets every unread badge to zero even though the
    // underlying messages are still there and genuinely unread".
    func testUnreadCountsSurviveBeingRecreatedFromTheSamePersistedStore() {
        let friendID = UUID()
        let firstLaunch = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)
        firstLaunch.unreadCounts[friendID] = 3

        let secondLaunch = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)

        XCTAssertEqual(secondLaunch.unreadCounts[friendID], 3, "an unread count must survive a relaunch, the same way messages and friends already do")
    }

    func testGroupUnreadCountsSurviveRelaunchAndContributeToTheTotalBadge() {
        let firstLaunch = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)
        firstLaunch.groupUnreadCounts["group-room"] = 4

        let secondLaunch = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)

        XCTAssertEqual(secondLaunch.groupUnreadCounts["group-room"], 4)
        XCTAssertEqual(secondLaunch.totalUnreadCount, 4)
    }

    func testInboxRefreshFetchesClosedChatAndUpdatesItsUnreadBadge() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let client = MockFriendChatClient(roomMessages: ["room-a": [
            .init(id: 1, text: "新着", sentAt: Date().timeIntervalSince1970 * 1_000, isMine: false)
        ]])
        await client.setInbox([.init(roomID: "room-a", latestID: 1, unreadCount: 1)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]

        await store.refreshInbox()

        XCTAssertEqual(store.unreadCounts[friend.id], 1)
        XCTAssertEqual(store.messages(for: friend).map(\.text), ["新着"])
        store.markRead(friend)
        await waitUntil { await client.readCallsSnapshot().contains(where: { $0.roomID == "room-a" && $0.throughID == 1 }) }
        await client.setInbox([.init(roomID: "room-a", latestID: 1, unreadCount: 0)])
        await store.refreshInbox()
        XCTAssertEqual(store.unreadCounts[friend.id], 0)
    }

    func testRemovingFriendHidesConversationButRestoresHistoryWhenRefriended() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient()
        await client.setBlockedContacts([contact])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]
        store.messages = [.init(id: UUID(), friendID: friend.id, text: "残す会話", sentAt: Date(), isMine: false, isCanceled: false, roomID: "room-a")]
        store.unreadCounts[friend.id] = 2

        let removed = await store.removeFriend(contact)
        XCTAssertTrue(removed)
        XCTAssertTrue(store.friends.isEmpty)
        XCTAssertEqual(store.messages.map(\.text), ["残す会話"])
        XCTAssertNil(store.unreadCounts[friend.id])

        let relaunched = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        XCTAssertTrue(relaunched.friends.isEmpty)
        XCTAssertEqual(relaunched.messages.map(\.text), ["残す会話"])
        await client.setFriends([.init(code: friend.code, name: friend.name, roomID: "room-a")])
        await client.setInbox([.init(roomID: "room-a", latestID: 0, unreadCount: 0, closed: false)])
        await store.refreshInbox()
        XCTAssertEqual(store.friends.first?.id, friend.id)
        XCTAssertEqual(store.messages(for: friend).map(\.text), ["残す会話"])
        await relaunched.refreshInbox()
        XCTAssertEqual(relaunched.friends.first?.id, friend.id)
    }

    // Regression coverage for "the archive exists in the data model but
    // nothing can ever reach it": these test the pieces that actually let a
    // removed friend's history stay viewable, rather than just staying
    // preserved-but-unreachable in `messages`.

    func testRemovingFriendPopulatesArchivedFriendsWithItsInfo() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient()
        await client.setBlockedContacts([contact])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]

        let removed = await store.removeFriend(contact)

        XCTAssertTrue(removed)
        XCTAssertEqual(store.archivedFriends.count, 1)
        XCTAssertEqual(store.archivedFriends.first?.code, "ALICE1")
        XCTAssertEqual(store.archivedFriends.first?.name, "Alice")
        XCTAssertEqual(store.archivedFriends.first?.roomID, "room-a")
    }

    func testSendingToAnArchivedFriendReachesTheServerInsteadOfFailingSilently() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient()
        await client.setBlockedContacts([contact])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]
        _ = await store.removeFriend(contact)
        XCTAssertTrue(store.friends.isEmpty, "the friend must actually be gone from the active list for this to be a real test of the archived fallback")

        let attempted = store.send("hello after removal", to: friend)

        XCTAssertTrue(attempted, "canonicalFriend must resolve the archived record so the local guard doesn't reject this before ever calling the network")
        await waitUntil { await client.sentMessages().count == 1 }
        let sent = await client.sentMessages()
        XCTAssertEqual(sent.first?.roomID, "room-a")
        XCTAssertEqual(sent.first?.text, "hello after removal")
    }

    func testSendingToAnArchivedFriendShowsADedicatedMessageWhenTheServerConfirmsTheFriendshipEnded() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient()
        await client.setBlockedContacts([contact])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]
        _ = await store.removeFriend(contact)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 403, message: "This friendship has ended."))

        _ = store.send("hello", to: friend)

        let expected = "このフレンドは削除済みのため、メッセージを送信できません。過去のやり取りは引き続き閲覧できます。"
        await waitUntil { store.errorMessage == expected }
        XCTAssertEqual(store.errorMessage, expected)
    }

    // Regression coverage for the previous test's fix: distinguishing
    // "This friendship has ended." must not swallow every other 403 into
    // the same specific wording — an unrelated room-access rejection still
    // gets the older, more general message.
    func testSendingToAnArchivedFriendKeepsTheGenericMessageForAnUnrelated403() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient()
        await client.setBlockedContacts([contact])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]
        _ = await store.removeFriend(contact)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 403, message: "You are not a participant in this room."))

        _ = store.send("hello", to: friend)

        let expected = "チャットルームにアクセスできません。フレンド情報を更新してください。"
        await waitUntil { store.errorMessage == expected }
        XCTAssertEqual(store.errorMessage, expected)
    }

    func testArchivedFriendsClearsTheEntryOnceReAddedAsAFriend() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient()
        await client.setBlockedContacts([contact])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]
        _ = await store.removeFriend(contact)
        XCTAssertEqual(store.archivedFriends.count, 1)

        // `refreshFriends()` alone won't do it: `locallyRemovedCodes` (set by
        // `removeFriend`) deliberately suppresses this exact code from a
        // plain friends poll, precisely so a stale in-flight response can't
        // un-archive someone the instant they're removed. `refreshInbox()`
        // is what actually detects "this retained room reopened" and lifts
        // that suppression — see its own reopening branch.
        await client.setFriends([.init(code: friend.code, name: friend.name, roomID: "room-a")])
        await client.setInbox([.init(roomID: "room-a", latestID: 0, unreadCount: 0, closed: false)])
        await store.refreshInbox()

        XCTAssertTrue(store.archivedFriends.isEmpty, "once the person is a real friend again, they must not also linger in the archive")
        XCTAssertEqual(store.friends.first?.code, "ALICE1")
    }

    func testArchivedFriendsNeverDuplicatesTheSamePersonAcrossRemoveReAddRemoveCycles() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient()
        await client.setBlockedContacts([contact])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]

        _ = await store.removeFriend(contact)
        XCTAssertEqual(store.archivedFriends.count, 1)

        // Re-added as a real friend (see the previous test for why this
        // needs refreshInbox(), not refreshFriends()), then removed again.
        await client.setFriends([.init(code: friend.code, name: friend.name, roomID: "room-a")])
        await client.setInbox([.init(roomID: "room-a", latestID: 0, unreadCount: 0, closed: false)])
        await store.refreshInbox()
        XCTAssertTrue(store.archivedFriends.isEmpty)
        await client.setBlockedContacts([contact])
        _ = await store.removeFriend(contact)

        XCTAssertEqual(store.archivedFriends.count, 1, "removing the same person twice across a re-add cycle must not leave two archived entries for them")
    }

    func testArchivedFriendsPersistsAcrossRelaunch() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient()
        await client.setBlockedContacts([contact])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]
        _ = await store.removeFriend(contact)
        XCTAssertEqual(store.archivedFriends.count, 1)

        let relaunched = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        XCTAssertEqual(relaunched.archivedFriends.count, 1)
        XCTAssertEqual(relaunched.archivedFriends.first?.code, "ALICE1")
    }

    func testRelaunchDoesNotBrieflyRestoreAnArchivedFriendFromAStaleListResponse() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient(friends: [.init(code: friend.code, name: friend.name, roomID: "room-a")])
        let original = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        original.friends = [friend]

        let removed = await original.removeFriend(contact)
        XCTAssertTrue(removed)
        // Model an eventually-consistent response still containing the
        // relationship immediately after the next app launch.
        await client.setFriends([.init(code: friend.code, name: friend.name, roomID: "room-a")])

        let relaunched = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        XCTAssertTrue(relaunched.friends.isEmpty)
        XCTAssertEqual(relaunched.archivedFriends.map(\.code), [friend.code])

        await relaunched.refreshFriends()

        XCTAssertTrue(relaunched.friends.isEmpty, "a stale launch response must not flash an archived contact in the active friends section")
        XCTAssertEqual(relaunched.archivedFriends.map(\.code), [friend.code])
    }

    func testLaunchRefreshDoesNotRestoreAnArchivedFriendFromAStaleServerSnapshot() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let contact = FriendChatService.BlockedContact(code: friend.code, name: friend.name, roomID: "room-a")
        let client = MockFriendChatClient(friends: [.init(code: friend.code, name: friend.name, roomID: "room-a")])
        let previousLaunch = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        previousLaunch.friends = [friend]
        let removed = await previousLaunch.removeFriend(contact)
        XCTAssertTrue(removed)

        // The server edge/cache still answers with its pre-removal list on
        // the first full refresh performed by a newly launched app.
        await client.setFriends([.init(code: friend.code, name: friend.name, roomID: "room-a")])
        let newLaunch = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await newLaunch.refresh()

        XCTAssertTrue(newLaunch.friends.isEmpty)
        XCTAssertEqual(newLaunch.archivedFriends.map(\.code), [friend.code])
    }

    func testInboxClosesRemovedFriendEvenIfFriendsListIsTemporarilyStale() async {
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let client = MockFriendChatClient()
        await client.setInbox([.init(roomID: "room-a", latestID: 3, unreadCount: 0, closed: true)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]
        store.messages = [.init(id: UUID(), friendID: friend.id, text: "保存する", sentAt: Date(), isMine: false, isCanceled: false, roomID: "room-a")]
        store.unreadCounts[friend.id] = 2

        await store.refreshInbox()

        XCTAssertTrue(store.friends.isEmpty)
        XCTAssertNil(store.unreadCounts[friend.id])
        XCTAssertEqual(store.messages.map(\.text), ["保存する"])
    }

    // Regression coverage for "a corrupted message history silently
    // resets to empty with no warning": unlike friends (re-fetched from
    // the server on the next refresh) or unread counts (self-correcting),
    // a message history that fails to decode has no other copy anywhere.
    func testInitSurfacesAnErrorWhenThePersistedMessageHistoryFailsToDecode() {
        defaults.set(Data("not valid json".utf8), forKey: "studiquoFriendMessages")

        let store = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)

        XCTAssertEqual(store.messages, [])
        XCTAssertNotEqual(store.errorMessage, "", "the user must be told local history couldn't be restored, not just see an empty conversation")
    }

    func testRefreshLoadsMultipleFriendsAndKeepsDemoFriend() async {
        let client = MockFriendChatClient(
            identity: .init(code: "ME1234", name: "Me"),
            friends: [
                .init(code: "ALICE1", name: "Alice", roomID: "room-a"),
                .init(code: "BOB222", name: "Bob", roomID: "room-b"),
            ]
        )
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.addDemoFriend()

        await store.refresh()

        XCTAssertEqual(store.myCode, "ME1234")
        XCTAssertEqual(store.friends.map(\.name), ["デモフレンド", "Alice", "Bob"])
        XCTAssertEqual(Set(store.friends.compactMap(\.roomID)), ["room-a", "room-b"])
    }

    // Regression coverage for "a friend's profile photo never shows up
    // anywhere but a generic placeholder icon, no matter what's set in the
    // profile screen": nothing about it ever reached the server before this.
    func testRefreshUploadsTheLocalProfilePhotoTheFirstTime() async {
        defaults.set(Data("fake jpeg bytes".utf8), forKey: "profileImage")
        let client = MockFriendChatClient(identity: .init(code: "ME1234", name: "Me"))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refresh()

        let uploaded = await client.uploadedAvatarsSnapshot()
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(uploaded.first?.contentType, "image/jpeg")
        XCTAssertEqual(uploaded.first?.data, Data("fake jpeg bytes".utf8))
    }

    func testRefreshDoesNotReuploadAnUnchangedProfilePhoto() async {
        defaults.set(Data("fake jpeg bytes".utf8), forKey: "profileImage")
        let client = MockFriendChatClient(identity: .init(code: "ME1234", name: "Me"))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refresh()
        await store.refresh()

        let uploaded = await client.uploadedAvatarsSnapshot()
        XCTAssertEqual(uploaded.count, 1, "an unchanged photo must not be re-uploaded on every poll")
    }

    func testRefreshUploadsAgainOnlyAfterThePhotoActuallyChanges() async {
        defaults.set(Data("first photo".utf8), forKey: "profileImage")
        let client = MockFriendChatClient(identity: .init(code: "ME1234", name: "Me"))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refresh()

        defaults.set(Data("second photo".utf8), forKey: "profileImage")
        await store.refresh()

        let uploaded = await client.uploadedAvatarsSnapshot()
        XCTAssertEqual(uploaded.map(\.data), [Data("first photo".utf8), Data("second photo".utf8)])
    }

    func testRefreshDownloadsANewFriendsAvatarAndSurfacesItOnTheFriendRecord() async {
        let client = MockFriendChatClient(
            identity: .init(code: "ME1234", name: "Me"),
            friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a", avatarUpdatedAt: 1_000)]
        )
        await client.setAvatar(Data("alice's photo".utf8), forCode: "ALICE1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refresh()

        XCTAssertEqual(store.friends.first(where: { $0.code == "ALICE1" })?.avatarData, Data("alice's photo".utf8))
    }

    func testRefreshDoesNotRedownloadAFriendsAvatarWhenItHasNotChanged() async {
        let client = MockFriendChatClient(
            identity: .init(code: "ME1234", name: "Me"),
            friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a", avatarUpdatedAt: 1_000)]
        )
        await client.setAvatar(Data("alice's photo".utf8), forCode: "ALICE1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refresh()

        // A second poll reports the exact same avatarUpdatedAt — the cached
        // copy must be trusted, not re-fetched on every single poll.
        await client.setAvatar(Data("a different payload, should never be read".utf8), forCode: "ALICE1")
        await store.refreshFriends()

        XCTAssertEqual(store.friends.first(where: { $0.code == "ALICE1" })?.avatarData, Data("alice's photo".utf8))
    }

    func testRefreshRedownloadsAFriendsAvatarOnceItsTimestampChanges() async {
        let client = MockFriendChatClient(
            identity: .init(code: "ME1234", name: "Me"),
            friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a", avatarUpdatedAt: 1_000)]
        )
        await client.setAvatar(Data("old photo".utf8), forCode: "ALICE1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refresh()

        await client.setFriends([.init(code: "ALICE1", name: "Alice", roomID: "room-a", avatarUpdatedAt: 2_000)])
        await client.setAvatar(Data("new photo".utf8), forCode: "ALICE1")
        await store.refreshFriends()

        XCTAssertEqual(store.friends.first(where: { $0.code == "ALICE1" })?.avatarData, Data("new photo".utf8))
    }

    func testRefreshClearsACachedAvatarOnceAFriendNoLongerHasOne() async {
        let client = MockFriendChatClient(
            identity: .init(code: "ME1234", name: "Me"),
            friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a", avatarUpdatedAt: 1_000)]
        )
        await client.setAvatar(Data("old photo".utf8), forCode: "ALICE1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refresh()
        XCTAssertNotNil(store.friends.first(where: { $0.code == "ALICE1" })?.avatarData)

        await client.setFriends([.init(code: "ALICE1", name: "Alice", roomID: "room-a", avatarUpdatedAt: nil)])
        await store.refreshFriends()

        XCTAssertNil(store.friends.first(where: { $0.code == "ALICE1" })?.avatarData)
    }

    // Regression coverage for "a demo friend's scripted reply never counts
    // as unread": unlike a real friend's incoming message (handled in
    // refreshMessages), the demo reply appended nothing to unreadCounts at
    // all, so its badge silently never appeared.

    func testDemoFriendReplyIncrementsUnreadCountWhenItsChatIsNotOpen() async {
        let store = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)
        store.addDemoFriend()
        let demo = store.friends.first(where: { $0.isDemo == true })!

        store.send("hi", to: demo)
        await waitUntil(timeout: 2) { store.unreadCounts[demo.id] == 1 }

        XCTAssertEqual(store.unreadCounts[demo.id], 1, "the scripted demo reply must count as unread the same way a real incoming message would")
    }

    func testDemoFriendReplyDoesNotCountAsUnreadWhileItsChatIsOpen() async throws {
        let store = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)
        store.addDemoFriend()
        let demo = store.friends.first(where: { $0.isDemo == true })!
        store.markRead(demo)

        store.send("hi", to: demo)
        try await Task.sleep(for: .seconds(1.3))

        XCTAssertEqual(store.unreadCounts[demo.id, default: 0], 0, "a demo reply while its own chat is open must not show as unread, matching real messages")
    }

    // Regression coverage for "a friend never appears once their accept
    // response arrives": repeated refreshes must keep each already-known
    // friend's `id` stable, or their accumulated messages/unread counts
    // (both keyed off that id) would be silently orphaned every time.

    func testRepeatedRefreshesKeepAnExistingFriendsIDStable() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refresh()
        let firstID = store.friends.first(where: { $0.code == "ALICE1" })?.id
        await store.refresh()
        let secondID = store.friends.first(where: { $0.code == "ALICE1" })?.id

        XCTAssertNotNil(firstID)
        XCTAssertEqual(firstID, secondID, "the same friend must keep the same id across refreshes")
    }

    func testRefreshFriendsSurfacesANewlyAcceptedFriendWithoutDisturbingAnExistingOnesUnreadCount() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refresh()
        let alice = store.friends[0]
        store.unreadCounts[alice.id] = 3
        store.messages = [FriendMessage(id: UUID(), friendID: alice.id, text: "hi", sentAt: Date(), isMine: false, isCanceled: false)]

        // Bob just accepted a request this user sent, so he now shows up
        // alongside Alice on the next poll.
        await client.setFriends([
            .init(code: "ALICE1", name: "Alice", roomID: "room-a"),
            .init(code: "BOB222", name: "Bob", roomID: "room-b"),
        ])
        await store.refreshFriends()

        XCTAssertEqual(store.friends.map(\.code).sorted(), ["ALICE1", "BOB222"])
        let aliceAfter = store.friends.first(where: { $0.code == "ALICE1" })
        XCTAssertEqual(aliceAfter?.id, alice.id)
        XCTAssertEqual(store.unreadCounts[alice.id], 3)
        XCTAssertEqual(store.messages(for: alice).map(\.text), ["hi"])
    }

    // Regression coverage for "a friend's today-study-time always shows as
    // zero": reporting must actually reach the server, and a friend's
    // reported time must only be trusted when it's dated today.

    func testReportMyStudyTimeSendsTheValueToTheServer() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.reportMyStudyTime(1_500)
        await waitUntil { await client.reportedStudyStatsSnapshot().count == 1 }

        let reported = await client.reportedStudyStatsSnapshot()
        XCTAssertEqual(reported.first?.seconds, 1_500)
        XCTAssertNotNil(reported.first?.date)
    }

    func testRefreshFriendsShowsAFriendsStudyTimeOnlyWhenReportedForToday() async {
        let todayFormatter = DateFormatter()
        todayFormatter.calendar = Calendar(identifier: .gregorian)
        todayFormatter.dateFormat = "yyyy-MM-dd"
        let today = todayFormatter.string(from: Date())

        let client = MockFriendChatClient(friends: [
            .init(code: "ALICE1", name: "Alice", roomID: "room-a", todayStudySeconds: 1_200, studyDate: today),
            .init(code: "BOB222", name: "Bob", roomID: "room-b", todayStudySeconds: 4_000, studyDate: "2000-01-01"),
        ])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refreshFriends()

        let alice = store.friends.first(where: { $0.code == "ALICE1" })
        let bob = store.friends.first(where: { $0.code == "BOB222" })
        XCTAssertEqual(alice?.todayStudySeconds, 1_200)
        XCTAssertEqual(bob?.todayStudySeconds, 0, "a stale (not-today) study date must not be trusted")
    }

    func testReportMyStudyTimeCanHideTheValueFromFriends() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.reportMyStudyTime(1_500, sharesStudyTime: false)
        await waitUntil { await client.reportedStudyStatsSnapshot().count == 1 }

        let reported = await client.reportedStudyStatsSnapshot()
        XCTAssertNil(reported.first?.seconds)
        XCTAssertNil(reported.first?.date)
    }

    func testFriendProfileLeavesStudyTimeEmptyWhenFriendDoesNotShareIt() {
        let friend = FriendRecord(
            id: UUID(), name: "Alice", code: "ALICE1",
            todayStudySeconds: 1_200, roomID: "room-a",
            isDemo: false, sharesStudyTime: false
        )

        let profile = FriendProfile(friend: friend, blockedByMeRoomIDs: [])

        XCTAssertNil(profile.todayStudySeconds, "共有していないフレンドの勉強時間は、未共有などの文言を出さず空欄にするためnilにします。")
    }

    func testRefreshFriendsMarksMissingStudyTimeAsUnshared() async {
        let todayFormatter = DateFormatter()
        todayFormatter.calendar = Calendar(identifier: .gregorian)
        todayFormatter.dateFormat = "yyyy-MM-dd"
        let today = todayFormatter.string(from: Date())
        let client = MockFriendChatClient(friends: [
            .init(code: "ALICE1", name: "Alice", roomID: "room-a", todayStudySeconds: nil, studyDate: today),
        ])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refreshFriends()

        let alice = store.friends.first(where: { $0.code == "ALICE1" })
        XCTAssertEqual(alice?.sharesStudyTime, false)
        if let alice {
            XCTAssertNil(FriendProfile(friend: alice, blockedByMeRoomIDs: []).todayStudySeconds)
        }
    }

    func testFriendChatSummariesSortNewestMessagesFirstAndKeepEmptyChatsLast() {
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let bob = FriendRecord(id: UUID(), name: "Bob", code: "BOB222", todayStudySeconds: 0, roomID: "room-b", isDemo: false)
        let carol = FriendRecord(id: UUID(), name: "Carol", code: "CAROL3", todayStudySeconds: 0, roomID: "room-c", isDemo: false)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = Date(timeIntervalSince1970: 2_000)
        let messages = [
            FriendMessage(id: UUID(), friendID: alice.id, text: "old", sentAt: oldDate, isMine: false),
            FriendMessage(id: UUID(), friendID: bob.id, text: "new", sentAt: newDate, isMine: false),
        ]

        let summaries = FriendChatSummary.summaries(
            friends: [alice, bob, carol],
            messages: messages,
            unreadCounts: [bob.id: 2]
        )

        XCTAssertEqual(summaries.map { $0.friend.id }, [bob.id, alice.id, carol.id])
        XCTAssertEqual(summaries.first?.previewText, "new")
        XCTAssertEqual(summaries.first?.unreadCount, 2)
        XCTAssertNil(summaries.last?.latestDate)
    }

    func testSendRoutesMessagesToTheCorrectFriendAndRoom() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let bob = FriendRecord(id: UUID(), name: "Bob", code: "BOB222", todayStudySeconds: 0, roomID: "room-b", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice, bob]

        store.send("Alice only", to: alice)
        store.send("Bob only", to: bob)
        await waitUntil { await client.sentMessages().count == 2 }

        XCTAssertEqual(store.messages(for: alice).map(\.text), ["Alice only"])
        XCTAssertEqual(store.messages(for: bob).map(\.text), ["Bob only"])
        let sent = await client.sentMessages()
        XCTAssertEqual(sent.map(\.roomID), ["room-a", "room-b"])
        XCTAssertEqual(sent.map(\.text), ["Alice only", "Bob only"])
    }

    // Regression coverage for "a failed send looks identical to a delivered
    // message, with no failure indicator": the optimistic local message must
    // be flagged so the UI can show the send actually failed.
    func testSendMarksTheOptimisticMessageAsFailedWhenTheServerRejectsIt() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        store.send("hello", to: alice)
        await waitUntil { await client.sentMessages().count == 1 }
        await waitUntil { store.messages(for: alice).first?.sendFailed == true }

        let sent = store.messages(for: alice)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.text, "hello")
        XCTAssertEqual(sent.first?.sendFailed, true)
        XCTAssertNotEqual(store.errorMessage, "")
    }

    func testSendReturnsFalseAndKeepsAFailedBubbleWhenTheFriendHasNoRoomYet() {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: nil, isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        let queued = store.send("hello", to: alice)

        XCTAssertFalse(queued)
        XCTAssertEqual(store.messages(for: alice).first?.text, "hello")
        XCTAssertEqual(store.messages(for: alice).first?.sendFailed, true)
        XCTAssertNotEqual(store.errorMessage, "")
    }

    func testSendingToABlockedFriendIsRejectedLocallyAndPreservesTheDraftForRetry() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]
        store.blockedByMeRoomIDs = ["room-a"]

        let queued = store.send("ブロック解除後に送りたい文章", to: alice)

        XCTAssertFalse(queued, "falseなら入力欄側は文章を消さず、そのまま再試行できます。")
        XCTAssertTrue(store.messages(for: alice).isEmpty, "ブロック中の相手に送信済み風の吹き出しを作ってはいけません。")
        XCTAssertTrue(store.errorMessage.contains("ブロックを解除"))
        let sent = await client.sentMessages()
        XCTAssertTrue(sent.isEmpty, "無効な送信先への通信を開始してはいけません。")
    }

    func testSendCanonicalizesAStaleFriendRecordByCodeBeforeSavingTheMessage() async {
        let client = MockFriendChatClient()
        let current = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let stale = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: nil, isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [current]

        let queued = store.send("hello", to: stale)
        await waitUntil { store.messages(for: current).first?.serverID != nil }

        XCTAssertTrue(queued)
        XCTAssertEqual(store.messages(for: stale).count, 0)
        XCTAssertEqual(store.messages(for: current).first?.text, "hello")
        XCTAssertEqual(store.messages(for: current).first?.sendFailed, nil)
        let sent = await client.sentMessages()
        XCTAssertEqual(sent.first?.roomID, "room-a")
    }

    func testIncomingMessageUsesCurrentFriendWhenTheOpenChatHasAnOldFriendID() async {
        let client = MockFriendChatClient(roomMessages: ["room-a": [
            .init(id: 1, text: "届いた", sentAt: 1_000, isMine: false),
        ]])
        let current = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let stale = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: nil, isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [current]

        await store.refreshMessages(for: stale)

        XCTAssertEqual(store.messages(for: current).map(\.text), ["届いた"])
        XCTAssertTrue(store.messages(for: stale).isEmpty)
    }

    func testSendDoesNotMarkTheMessageAsFailedWhenTheServerAccepts() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.send("hello", to: alice)
        await waitUntil { await client.sentMessages().count == 1 }

        XCTAssertEqual(store.messages(for: alice).first?.sendFailed, nil)
    }

    func testSuccessfulSendImmediatelyStoresTheServerConfirmation() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.send("hello", to: alice)
        await waitUntil { store.messages(for: alice).first?.serverID != nil }

        let message = store.messages(for: alice).first
        XCTAssertEqual(message?.text, "hello")
        XCTAssertEqual(message?.serverID, 1)
        XCTAssertEqual(message?.isCanceled, false)
        XCTAssertEqual(message?.sendFailed, nil)
    }

    func testSuccessfulSendImmediatelyRefreshesTheConversation() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.send("hello", to: alice)
        await waitUntil { await !client.messagesAfterRequestsSnapshot().isEmpty }

        let afterRequests = await client.messagesAfterRequestsSnapshot()
        XCTAssertEqual(afterRequests, [0])
        XCTAssertEqual(store.messages(for: alice).first?.serverID, 1)
        XCTAssertEqual(store.messages(for: alice).first?.isCanceled, false)
    }

    func testRefreshMessagesKeepsFriendRoomsSeparateAndCountsUnread() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let bob = FriendRecord(id: UUID(), name: "Bob", code: "BOB222", todayStudySeconds: 0, roomID: "room-b", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice, bob]
        store.messages = [
            FriendMessage(id: UUID(), friendID: bob.id, text: "Local Bob draft", sentAt: Date(timeIntervalSince1970: 1), isMine: true, isCanceled: false)
        ]

        await client.setMessages([
            "room-a": [
                .init(id: 1, text: "A sent", sentAt: 1_000, isMine: true),
                .init(id: 2, text: "A received", sentAt: 2_000, isMine: false),
            ],
            "room-b": [
                .init(id: 3, text: "B received", sentAt: 1_500, isMine: false),
            ],
        ])

        // Mirrors the real app flow: FriendChatView calls markRead before its
        // polling loop ever calls refreshMessages for the friend being viewed.
        store.markRead(alice)
        await store.refreshMessages(for: alice)
        XCTAssertEqual(store.messages(for: alice).map(\.text), ["A sent", "A received"])
        XCTAssertEqual(store.messages(for: bob).map(\.text), ["Local Bob draft"])
        XCTAssertEqual(store.unreadCounts[alice.id, default: 0], 0)

        store.stopReading(alice)
        await client.appendMessage(.init(id: 4, text: "A new", sentAt: 3_000, isMine: false), to: "room-a")
        await store.refreshMessages(for: alice)
        XCTAssertEqual(store.unreadCounts[alice.id, default: 0], 1)

        store.markRead(alice)
        await client.appendMessage(.init(id: 5, text: "A active", sentAt: 4_000, isMine: false), to: "room-a")
        await store.refreshMessages(for: alice)
        XCTAssertEqual(store.unreadCounts[alice.id, default: 0], 0)
    }

    func testChatKeepsPollingWhileAttachmentMaintenanceIsSuspended() async {
        let gate = FriendChatMaintenanceGate()
        var refreshCount = 0
        let activity = Task {
            await FriendChatActivity.run(
                pollInterval: .milliseconds(10),
                refresh: { refreshCount += 1 },
                maintenance: { await gate.wait() }
            )
        }

        await waitUntil { gate.isWaiting && refreshCount > 0 }
        let countBefore = refreshCount
        await waitUntil { refreshCount > countBefore }
        XCTAssertTrue(gate.isWaiting, "receiving must continue before attachment repair finishes")

        activity.cancel()
        gate.open()
        await activity.value
    }

    func testRefreshMessagesFetchesOnlyWhatsNewAndKeepsOlderLocalHistory() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        // 25 known messages — comfortably past the small trailing window
        // refreshMessages re-requests on every poll (so a just-canceled
        // message's retraction can still reach this device even though it
        // was already fetched once; see the cancellation tests below).
        let initial = (1...25).map { FriendChatService.Message(id: $0, text: "message \($0)", sentAt: Double($0) * 1_000, isMine: false) }
        await client.setMessages(["room-a": initial])
        await store.refreshMessages(for: alice)
        XCTAssertEqual(store.messages(for: alice).count, 25)

        // Even if the server's own window has since moved past this message
        // (it only keeps the most recent 200 for an after:0 request), the
        // client must not need the whole history again — only what's new,
        // plus a small trailing window of what it already has.
        await client.appendMessage(.init(id: 26, text: "New message", sentAt: 26_000, isMine: false), to: "room-a")
        await store.refreshMessages(for: alice)

        XCTAssertEqual(store.messages(for: alice).map(\.text).last, "New message")
        XCTAssertEqual(store.messages(for: alice).count, 26, "no duplicates from re-fetching the trailing window")
        let requestedAfterValues = await client.messagesAfterRequestsSnapshot()
        XCTAssertEqual(
            requestedAfterValues, [0, 5],
            "the second fetch must ask for messages well past the start (efficient), but not strictly past the last known id either (the trailing window)"
        )
    }

    func testRoomChangeResetsMessageCursorAndDoesNotMixRoomHistories() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-old", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]
        await client.setMessages(["room-old": [.init(id: 100, text: "Old room", sentAt: 1_000, isMine: false)]])
        await store.refreshMessages(for: alice)

        await client.setFriends([.init(code: "ALICE1", name: "Alice", roomID: "room-new")])
        await store.refreshFriends()
        await client.setMessages(["room-new": [
            .init(id: 1, text: "New room", sentAt: 2_000, isMine: false),
            .init(id: 100, text: "Same numeric ID in new room", sentAt: 3_000, isMine: false),
        ]])
        await store.refreshMessages(for: alice)

        let requestedAfterValues = await client.messagesAfterRequestsSnapshot()
        XCTAssertEqual(requestedAfterValues, [0, 0])
        XCTAssertEqual(store.messages(for: alice).map(\.text), ["New room", "Same numeric ID in new room"])
        XCTAssertEqual(store.messages.filter { $0.roomID == "room-old" }.map(\.text), ["Old room"])
        XCTAssertEqual(FriendChatSummary.summaries(friends: store.friends, messages: store.messages, unreadCounts: [:]).first?.previewText, "Same numeric ID in new room")
    }

    func testLegacyCachedMessagesAdoptPersistedRoomBeforeFriendshipChanges() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-old", isDemo: false)
        let oldMessage = FriendMessage(id: UUID(), friendID: alice.id, text: "Old room", sentAt: Date(timeIntervalSince1970: 1), isMine: false, isCanceled: false, serverID: 100)
        defaults.set(try! JSONEncoder().encode([alice]), forKey: "studiquoFriends")
        defaults.set(try! JSONEncoder().encode([oldMessage]), forKey: "studiquoFriendMessages")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        XCTAssertEqual(store.messages.first?.roomID, "room-old")

        await client.setFriends([.init(code: "ALICE1", name: "Alice", roomID: "room-new")])
        await store.refreshFriends()
        await client.setMessages(["room-new": [.init(id: 1, text: "New room", sentAt: 2_000, isMine: false)]])
        await store.refreshMessages(for: alice)

        let requestedAfterValues = await client.messagesAfterRequestsSnapshot()
        XCTAssertEqual(requestedAfterValues, [0])
        XCTAssertEqual(store.messages(for: alice).map(\.text), ["New room"])
    }

    func testRefreshMessagesReconcilesAnOptimisticallySentMessageInsteadOfDuplicatingIt() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.send("Hi Alice", to: alice)
        await waitUntil { await client.sentMessages().count == 1 }
        XCTAssertEqual(store.messages(for: alice).count, 1)

        await store.refreshMessages(for: alice)

        XCTAssertEqual(
            store.messages(for: alice).map(\.text), ["Hi Alice"],
            "the server's own echo of my sent message must reconcile with the optimistic copy, not duplicate it"
        )
    }

    // Regression coverage for "sentAt isn't resynced after server
    // reconciliation": leaving the optimistic copy's local-clock sentAt in
    // place risks it sorting out of order relative to messages that arrived
    // in between, once the server's authoritative timestamp is available.
    func testRefreshMessagesResyncsSentAtToTheServersAuthoritativeTimestamp() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.send("Hi Alice", to: alice)
        await waitUntil { await client.sentMessages().count == 1 }
        let localSentAt = store.messages(for: alice).first?.sentAt

        // A server timestamp deliberately far from "now", standing in for
        // clock skew or send/ack latency.
        let serverSentAt = Date(timeIntervalSince1970: 1_700_000_000)
        await client.setMessages(["room-a": [
            .init(id: 1, text: "Hi Alice", sentAt: serverSentAt.timeIntervalSince1970 * 1_000, isMine: true)
        ]])

        await store.refreshMessages(for: alice)

        let reconciled = store.messages(for: alice).first
        XCTAssertEqual(reconciled?.serverID, 1)
        XCTAssertNotEqual(reconciled?.sentAt, localSentAt)
        XCTAssertEqual(reconciled?.sentAt.timeIntervalSince1970 ?? 0, serverSentAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // Regression coverage for "silent polling failures (no error
    // surfaced)": a background poll used to fail forever with nothing ever
    // telling the user why their screen had gone stale.

    func testRefreshFriendsSurfacesAnErrorOnlyAfterSustainedFailures() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        await store.refreshFriends()
        XCTAssertEqual(store.errorMessage, "", "a single transient blip shouldn't alert the user yet")

        await store.refreshFriends()
        XCTAssertEqual(store.errorMessage, "", "still within tolerance")

        await store.refreshFriends()
        XCTAssertNotEqual(store.errorMessage, "", "a sustained failure must surface something instead of silently going stale forever")
    }

    func testRefreshFriendsFailureCounterResetsOnASuccessfulPoll() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(URLError(.notConnectedToInternet))
        await store.refreshFriends()
        await store.refreshFriends()

        await client.setErrorToThrow(nil)
        await store.refreshFriends()

        await client.setErrorToThrow(URLError(.notConnectedToInternet))
        await store.refreshFriends()
        await store.refreshFriends()

        XCTAssertEqual(store.errorMessage, "", "a success in between must reset the streak, not just accumulate failures across it")
    }

    func testConnectivityErrorClearsOnceThePollActuallyRecovers() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(URLError(.notConnectedToInternet))
        await store.refreshFriends()
        await store.refreshFriends()
        await store.refreshFriends()
        XCTAssertNotEqual(store.errorMessage, "", "sanity check: the sustained-failure alert fired")

        await client.setErrorToThrow(nil)
        await store.refreshFriends()

        XCTAssertEqual(store.errorMessage, "", "a stale connectivity error must not sit on screen forever once polling actually recovers")
    }

    func testAnExpiredTokenSurfacesASignInAgainMessageImmediatelyInsteadOfWaitingForConsecutiveFailures() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 401, message: "This token has expired. Reconnect from Studiquo to get a new one."))

        await store.refreshFriends()

        XCTAssertEqual(
            store.errorMessage, "ログインの有効期限が切れています。一度サインアウトし、もう一度サインインしてください。",
            "an expired token fails identically on every retry, so there's nothing to gain by waiting for the usual consecutive-failure threshold"
        )
    }

    // Regression coverage for a real report: with an actually-expired token,
    // dismissing the alert (which just clears errorMessage — see
    // FriendsHomeView's own .alert) only ever bought a fraction of a
    // second before it reappeared, because several independent 2-second
    // polling loops (friends, incoming requests, and — while a chat is
    // open — messages, all funneling into this same notePollResult) keep
    // rediscovering the same still-401 token, and used to unconditionally
    // reassign errorMessage every single time one of them did. The user
    // could not actually read or act on it before it was replaced by an
    // identical copy of itself.
    func testAnExpiredTokenAlertIsNotReshownOnEveryPollWhileItIsStillUnresolved() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 401, message: "This token has expired. Reconnect from Studiquo to get a new one."))
        await store.refreshFriends()
        XCTAssertNotEqual(store.errorMessage, "", "sanity check: the first failure did surface the message")

        // The user dismisses it, exactly like tapping "OK" on the alert.
        store.errorMessage = ""

        // More poll ticks — standing in for this same loop's next tick, or
        // one of the other independent polling loops discovering the same
        // still-expired token moments later — keep failing identically.
        await store.refreshFriends()
        await store.refreshFriends()
        await store.refreshFriends()

        XCTAssertEqual(store.errorMessage, "", "a still-expired token must not re-show the alert on every subsequent poll once the user has already been told and dismissed it")
    }

    func testAnExpiredTokenAlertCanBeShownAgainAfterActuallySigningInAgainAndFailingOnceMore() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 401, message: "This token has expired. Reconnect from Studiquo to get a new one."))
        await store.refreshFriends()
        store.errorMessage = ""
        await store.refreshFriends()
        XCTAssertEqual(store.errorMessage, "", "sanity check: the repeat-suppression from the test above is in effect")

        // A real sign-in-again success resets the "already notified" state...
        await client.setErrorToThrow(nil)
        await store.refreshFriends()
        // ...so a genuinely new expiry later is still reported, not
        // silently suppressed forever by the very first one this store
        // instance ever saw.
        await client.setErrorToThrow(FriendChatService.ServerError(status: 401, message: "This token has expired. Reconnect from Studiquo to get a new one."))
        await store.refreshFriends()

        XCTAssertNotEqual(store.errorMessage, "", "a fresh expiry after a real recovery must still be reported")
    }

    func testAPlainServerErrorStillUsesTheGenericConnectivityMessageWithTheUsualThreshold() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 500, message: "Internal error."))

        await store.refreshFriends()
        XCTAssertEqual(store.errorMessage, "", "a single blip — even a server error, not just a network one — shouldn't alert immediately unless it's specifically an expired token")

        await store.refreshFriends()
        await store.refreshFriends()
        XCTAssertEqual(store.errorMessage, "フレンドサーバーに接続できません。", "a sustained non-auth failure still gets the generic connectivity message")
    }

    func testAuthExpiredErrorClearsOnceSigningInAgainActuallyRecovers() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 401, message: "This token has expired. Reconnect from Studiquo to get a new one."))
        await store.refreshFriends()
        XCTAssertNotEqual(store.errorMessage, "", "sanity check: the auth-expired message fired")

        await client.setErrorToThrow(nil)
        await store.refreshFriends()

        XCTAssertEqual(store.errorMessage, "", "a stale sign-in-again message must not sit on screen forever once a fresh token actually starts working")
    }

    // MARK: - refreshGroups / refreshGroupInvites

    func testRefreshGroupsPopulatesGroupsFromServer() async {
        let client = MockFriendChatClient()
        let group = FriendChatService.Group(
            roomID: String(repeating: "a", count: 64), name: "受験対策",
            members: [.init(code: "ME0000", name: "Me"), .init(code: "ALICE1", name: "Alice")]
        )
        await client.setGroups([group])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refreshGroups()

        XCTAssertEqual(store.groups.map(\.roomID), [group.roomID])
        XCTAssertEqual(store.groups.first?.name, "受験対策")
        XCTAssertEqual(store.groups.first?.members.count, 2)
    }

    func testRefreshGroupInvitesPopulatesIncomingGroupInvitesFromServer() async {
        let client = MockFriendChatClient()
        let invite = FriendChatService.GroupInvite(
            roomID: String(repeating: "b", count: 64), name: "受験対策",
            inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000
        )
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refreshGroupInvites()

        XCTAssertEqual(store.incomingGroupInvites.map(\.roomID), [invite.roomID])
        XCTAssertEqual(store.incomingGroupInvites.first?.inviterName, "Alice")
    }

    // Mirrors testConnectivityErrorClearsOnceThePollActuallyRecovers — groups
    // and friends share the same notePollResult machinery, so a sustained
    // failure while listing groups must behave identically.
    func testRefreshGroupsConnectivityErrorSurfacesAfterThreeFailuresThenClearsOnRecovery() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        await store.refreshGroups()
        XCTAssertEqual(store.errorMessage, "", "still within tolerance")
        await store.refreshGroups()
        XCTAssertEqual(store.errorMessage, "", "still within tolerance")
        await store.refreshGroups()
        XCTAssertNotEqual(store.errorMessage, "", "a sustained failure must surface something instead of silently going stale forever")

        await client.setErrorToThrow(nil)
        await store.refreshGroups()

        XCTAssertEqual(store.errorMessage, "", "a stale connectivity error must not sit on screen forever once polling actually recovers")
    }

    // Mirrors testAnExpiredTokenSurfacesASignInAgainMessageImmediatelyInsteadOfWaitingForConsecutiveFailures.
    func testRefreshGroupsExpiredTokenSurfacesSignInAgainMessageImmediately() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 401, message: "This token has expired. Reconnect from Studiquo to get a new one."))

        await store.refreshGroups()

        XCTAssertEqual(
            store.errorMessage, "ログインの有効期限が切れています。一度サインアウトし、もう一度サインインしてください。",
            "an expired token fails identically on every retry, so there's nothing to gain by waiting for the usual consecutive-failure threshold"
        )
    }

    // Same as above, for the separate incoming-group-invites poll — a
    // distinct code path from refreshGroups that funnels into the same
    // shared auth-failure handling and must behave the same way.
    func testRefreshGroupInvitesExpiredTokenSurfacesSignInAgainMessageImmediately() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 401, message: "This token has expired. Reconnect from Studiquo to get a new one."))

        await store.refreshGroupInvites()

        XCTAssertEqual(
            store.errorMessage, "ログインの有効期限が切れています。一度サインアウトし、もう一度サインインしてください。"
        )
    }

    // MARK: - createGroup

    func testCreateGroupWithAnEmptyNameFailsWithoutCallingTheNetwork() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.createGroup(name: "", memberCodes: ["ALICE1"])

        XCTAssertFalse(succeeded)
        XCTAssertTrue(store.groups.isEmpty)
        let calls = await client.createGroupCallsSnapshot()
        XCTAssertTrue(calls.isEmpty, "an empty name must be rejected locally, before ever reaching the network")
    }

    func testCreateGroupWithAWhitespaceOnlyNameFailsWithoutCallingTheNetwork() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.createGroup(name: "   ", memberCodes: ["ALICE1"])

        XCTAssertFalse(succeeded)
        let calls = await client.createGroupCallsSnapshot()
        XCTAssertTrue(calls.isEmpty)
    }

    func testCreateGroupWithNoInvitedFriendsStillSucceeds() async {
        // A group can start as just its creator (see groups.js — no
        // minimum invited-member count), the same way an ordinary
        // conversation can start with nobody in it yet.
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.createGroup(name: "一人グループ", memberCodes: [])

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.groups.count, 1)
    }

    func testLegacyCachedGroupWithoutPublicCodeStillDecodes() throws {
        let legacy = Data(#"{"roomID":"room-a","name":"旧グループ","members":[]}"#.utf8)

        let group = try JSONDecoder().decode(FriendChatService.Group.self, from: legacy)

        XCTAssertEqual(group.roomID, "room-a")
        XCTAssertEqual(group.name, "旧グループ")
        XCTAssertNil(group.code)
        XCTAssertNil(group.avatarUpdatedAt)
    }

    func testRenamingAGroupPreservesItsPublicCodeAndAvatarRevision() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(
            roomID: "room-a",
            name: "変更前",
            members: [],
            code: "ABCDEFG234",
            avatarUpdatedAt: 123
        )]

        let renamed = await store.renameGroup(roomID: "room-a", name: "変更後")
        XCTAssertTrue(renamed)
        XCTAssertEqual(store.groups.first?.code, "ABCDEFG234")
        XCTAssertEqual(store.groups.first?.avatarUpdatedAt, 123)
    }

    func testUpdatingAGroupPhotoUploadsAndImmediatelyUpdatesTheVisibleIcon() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [.init(roomID: "room-a", name: "勉強会", members: [], code: "ABCDEFG234")]
        let photo = Data("jpeg bytes".utf8)

        let updated = await store.updateGroupAvatar(roomID: "room-a", data: photo)

        XCTAssertTrue(updated)
        XCTAssertEqual(store.groupAvatars["room-a"], photo)
        XCTAssertEqual(store.groups.first?.avatarUpdatedAt, 456)
        let chatSummary = GroupChatSummary.summaries(
            groups: store.groups,
            messagesByRoomID: store.groupMessages,
            avatarsByRoomID: store.groupAvatars
        ).first
        XCTAssertEqual(chatSummary?.avatarData, photo, "the chat list must use the photo immediately after it is changed")
        let uploads = await client.groupAvatarUploadsSnapshot()
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads.first?.roomID, "room-a")
        XCTAssertEqual(uploads.first?.contentType, "image/jpeg")
        XCTAssertEqual(uploads.first?.data, photo)
    }

    func testOversizedGroupPhotoIsRejectedBeforeUploading() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let oversized = Data(repeating: 1, count: AvatarImageProcessor.maximumUploadBytes + 1)

        let updated = await store.updateGroupAvatar(roomID: "room-a", data: oversized)

        XCTAssertFalse(updated)
        let uploads = await client.groupAvatarUploadsSnapshot()
        XCTAssertTrue(uploads.isEmpty)
    }

    func testRefreshingGroupsDownloadsAnUpdatedPhotoForTheGroupList() async {
        let client = MockFriendChatClient()
        let photo = Data("remote jpeg".utf8)
        await client.setGroupAvatar(photo, roomID: "room-a")
        await client.setGroups([.init(
            roomID: "room-a",
            name: "勉強会",
            members: [],
            code: "ABCDEFG234",
            avatarUpdatedAt: 789
        )])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refreshGroups()

        XCTAssertEqual(store.groupAvatars["room-a"], photo)
        let chatSummary = GroupChatSummary.summaries(
            groups: store.groups,
            messagesByRoomID: store.groupMessages,
            avatarsByRoomID: store.groupAvatars
        ).first
        XCTAssertEqual(chatSummary?.avatarData, photo, "the chat list must use a photo downloaded after relaunch or refresh")
    }

    func testCreateGroupSuccessAddsTheReturnedGroupToTheList() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.createGroup(name: "受験対策", memberCodes: ["ALICE1", "BOB000"])

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups.first?.name, "受験対策")
        let calls = await client.createGroupCallsSnapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "受験対策")
        XCTAssertEqual(calls.first?.memberCodes, ["ALICE1", "BOB000"])
    }

    /// Regression coverage for the production race that made a newly-created
    /// group disappear: a list poll captured the old empty server state,
    /// creation completed and inserted the group locally, then that older
    /// poll arrived late and replaced the list with its empty snapshot.
    func testStaleGroupRefreshCannotRemoveAGroupCreatedWhileItWasInFlight() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.holdGroups()

        let staleRefresh = Task { await store.refreshGroups() }
        await waitUntil { await client.isGroupFetchWaiting() }

        let succeeded = await store.createGroup(name: "受験対策", memberCodes: ["ALICE1"])
        let createdRoomID = await client.createdGroupRoomID
        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.groups.map(\.roomID), [createdRoomID])

        await client.releaseGroups()
        await staleRefresh.value

        XCTAssertEqual(
            store.groups.map(\.roomID), [createdRoomID],
            "an older empty list response must not overwrite a group created after that request began"
        )
    }

    // Regression coverage for the same shape of bug notePollResult's own
    // tests guard against elsewhere: a create that happens to echo back a
    // group the client already knows about (e.g. a refresh() landing in
    // between the request and its response) must not add a second, visibly
    // duplicate entry.
    func testCreateGroupDoesNotDuplicateAGroupAlreadyInTheList() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let existing = FriendChatService.Group(roomID: await client.createdGroupRoomID, name: "既存", members: [])
        store.groups = [existing]

        let succeeded = await store.createGroup(name: "受験対策", memberCodes: ["ALICE1"])

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.groups.count, 1, "the same roomID must not appear twice")
    }

    func testCreateGroupMapsAServerErrorToASpecificJapaneseMessage() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 400, message: "You can only invite your own friends."))

        let succeeded = await store.createGroup(name: "受験対策", memberCodes: ["STRANGER"])

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.errorMessage, "自分の友達だけを招待できます。")
    }

    func testCreateGroupFailureAddsNothingToTheList() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        let succeeded = await store.createGroup(name: "受験対策", memberCodes: ["ALICE1"])

        XCTAssertFalse(succeeded)
        XCTAssertTrue(store.groups.isEmpty)
    }

    // MARK: - inviteToGroup

    func testInviteToGroupSuccessReturnsTrueAndClearsTheErrorMessage() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.errorMessage = "前回のエラー"
        let roomID = String(repeating: "a", count: 64)

        let succeeded = await store.inviteToGroup(roomID: roomID, code: "CAROL1")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.errorMessage, "")
        let calls = await client.inviteToGroupCallsSnapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.roomID, roomID)
        XCTAssertEqual(calls.first?.code, "CAROL1")
    }

    // An invite only ever creates a pending invitation on the invitee's own
    // side — the inviter's own membership list must not change until (and
    // unless) that invite is actually accepted.
    func testInviteToGroupDoesNotChangeTheLocalGroupsList() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let roomID = String(repeating: "a", count: 64)
        let group = FriendChatService.Group(roomID: roomID, name: "受験対策", members: [.init(code: "ME0000", name: "Me")])
        store.groups = [group]

        _ = await store.inviteToGroup(roomID: roomID, code: "CAROL1")

        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups.first?.members.map(\.code), ["ME0000"])
    }

    func testInviteToGroupMapsAServerErrorToASpecificJapaneseMessage() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 400, message: "This group is full."))

        let succeeded = await store.inviteToGroup(roomID: String(repeating: "a", count: 64), code: "CAROL1")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.errorMessage, "このグループは満員です。")
    }

    func testInviteToGroupFailureSetsAGenericErrorMessageForANonServerError() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        let succeeded = await store.inviteToGroup(roomID: String(repeating: "a", count: 64), code: "CAROL1")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.errorMessage, "招待できませんでした。")
    }

    // Re-inviting someone who already has an unanswered invite to this same
    // group must not read as a fresh success — the server reports
    // "already_pending" (see user-registry.js's addIncomingGroupInvite) and
    // the store must surface that distinctly instead of dismissing silently.
    func testInviteToGroupAlreadyPendingReturnsFalseAndSetsAnAlreadySentMessage() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setInviteToGroupResultStatus("already_pending")

        let succeeded = await store.inviteToGroup(roomID: String(repeating: "a", count: 64), code: "CAROL1")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.errorMessage, "この招待はすでに送信済みです。")
    }

    // The already-pending response still means the request itself reached
    // the server and was recognized — unlike the error-throwing paths above,
    // this is not a transport/server failure, so no duplicate call retry
    // logic should be needed; this just documents that the single call
    // already made is what gets classified as "already_pending".
    func testInviteToGroupAlreadyPendingStillRecordsExactlyOneCallToTheServer() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setInviteToGroupResultStatus("already_pending")
        let roomID = String(repeating: "a", count: 64)

        _ = await store.inviteToGroup(roomID: roomID, code: "CAROL1")

        let calls = await client.inviteToGroupCallsSnapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.roomID, roomID)
        XCTAssertEqual(calls.first?.code, "CAROL1")
    }

    // MARK: - acceptGroupInvite

    func testAcceptGroupInviteMovesTheInviteIntoGroupsAndClearsIt() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let joined = FriendChatService.Group(roomID: roomID, name: "受験対策", members: [.init(code: "ME0000", name: "Me"), .init(code: "ALICE1", name: "Alice")])
        await client.setAcceptGroupInviteResult(joined)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()

        store.acceptGroupInvite(store.incomingGroupInvites[0])
        await waitUntil { await client.acceptedGroupInviteRoomIDsSnapshot() == [roomID] }

        XCTAssertEqual(store.groups.map(\.roomID), [roomID])
        XCTAssertEqual(store.groups.first?.members.count, 2)
        XCTAssertTrue(store.incomingGroupInvites.isEmpty)
    }

    /// Regression coverage for an accepted group being present in the store
    /// but omitted from the main message list, which previously built rows
    /// exclusively from `friends`.
    func testAcceptedGroupProducesAGroupChatListSummary() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "g", count: 64)
        let invite = FriendChatService.GroupInvite(
            roomID: roomID, name: "英語勉強会",
            inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000
        )
        let joined = FriendChatService.Group(
            roomID: roomID, name: "英語勉強会",
            members: [.init(code: "ME0000", name: "Me"), .init(code: "ALICE1", name: "Alice")]
        )
        await client.setGroupInvites([invite])
        await client.setAcceptGroupInviteResult(joined)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()

        store.acceptGroupInvite(invite)
        await waitUntil { store.groups.contains(where: { $0.roomID == roomID }) }

        let summaries = GroupChatSummary.summaries(
            groups: store.groups,
            messagesByRoomID: store.groupMessages,
            unreadCounts: [roomID: 3]
        )
        XCTAssertEqual(summaries.map(\.id), [roomID])
        XCTAssertEqual(summaries.first?.group.name, "英語勉強会")
        XCTAssertEqual(summaries.first?.group.members.count, 2)
        XCTAssertEqual(summaries.first?.unreadCount, 3)
    }

    func testInboxFetchesGroupMessagesAndPublishesTheirUnreadCountForTheChatList() async {
        let roomID = String(repeating: "a", count: 64)
        let group = FriendChatService.Group(roomID: roomID, name: "英語勉強会", members: [])
        let client = MockFriendChatClient(roomMessages: [roomID: [
            .init(id: 1, text: "宿題を共有しました", sentAt: 1_700_000_000_000, isMine: false)
        ]])
        await client.setInbox([.init(roomID: roomID, latestID: 1, unreadCount: 1, kind: "group")])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [group]

        await store.refreshInbox()

        XCTAssertEqual(store.groupMessages[roomID]?.map(\.text), ["宿題を共有しました"])
        XCTAssertEqual(store.groupUnreadCounts[roomID], 1)
        XCTAssertEqual(store.totalUnreadCount, 1)
        let summary = GroupChatSummary.summaries(
            groups: store.groups,
            messagesByRoomID: store.groupMessages,
            unreadCounts: store.groupUnreadCounts
        ).first
        XCTAssertEqual(summary?.previewText, "宿題を共有しました")
        XCTAssertEqual(summary?.unreadCount, 1)
    }

    func testOpeningAGroupChatClearsItsUnreadCountAndMarksTheRoomRead() async {
        let roomID = String(repeating: "b", count: 64)
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groupMessages[roomID] = [.init(id: 7, text: "新着", sentAt: 1_700_000_000_000, isMine: false)]
        store.groupUnreadCounts[roomID] = 1

        store.startReadingGroup(roomID: roomID)
        await waitUntil { await client.readCallsSnapshot().contains { $0.roomID == roomID && $0.throughID == 7 } }

        XCTAssertEqual(store.groupUnreadCounts[roomID], 0)
        XCTAssertEqual(store.activeGroupRoomID, roomID)
        store.stopReadingGroup(roomID: roomID)
        XCTAssertNil(store.activeGroupRoomID)
    }

    // Mirrors testAcceptDoesNotCreateADuplicateFriendIfOneAlreadyExists — a
    // refresh() landing in between the request and its response can result
    // in this group already being present.
    func testAcceptGroupInviteDoesNotDuplicateAGroupAlreadyInTheList() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: [.init(code: "ME0000", name: "Me")])]

        store.acceptGroupInvite(store.incomingGroupInvites[0])
        await waitUntil { await client.acceptedGroupInviteRoomIDsSnapshot() == [roomID] }

        XCTAssertEqual(store.groups.filter { $0.roomID == roomID }.count, 1)
        XCTAssertTrue(store.incomingGroupInvites.isEmpty)
    }

    // Mirrors testAcceptIgnoresASecondCallForTheSameCodeWhileTheFirstIsStillInFlight.
    func testAcceptGroupInviteIgnoresASecondCallForTheSameRoomWhileTheFirstIsStillInFlight() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()

        store.acceptGroupInvite(store.incomingGroupInvites[0])
        store.acceptGroupInvite(store.incomingGroupInvites[0]) // simulates a rapid double-tap
        await waitUntil { store.groups.contains(where: { $0.roomID == roomID }) }

        let accepted = await client.acceptedGroupInviteRoomIDsSnapshot()
        XCTAssertEqual(accepted, [roomID], "a second tap while the first is still in flight must not fire a second network call")
    }

    // Mirrors testPendingRequestActionsTracksAnAcceptInFlightAndClearsOnceItFinishes.
    func testPendingGroupActionsTracksAnAcceptInFlightAndClearsOnceItFinishes() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()

        store.acceptGroupInvite(store.incomingGroupInvites[0])
        XCTAssertTrue(store.pendingGroupActions.contains(roomID), "the room must be marked in-flight synchronously, before the network call resolves")

        await waitUntil { !store.pendingGroupActions.contains(roomID) }
    }

    func testAcceptGroupInviteFailureLeavesTheInviteInPlaceAndSetsAnErrorMessage() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()
        await client.setErrorToThrow(FriendChatService.ServerError(status: 404, message: "Invitation not found."))

        store.acceptGroupInvite(store.incomingGroupInvites[0])
        await waitUntil { !store.errorMessage.isEmpty }

        XCTAssertEqual(store.incomingGroupInvites.map(\.roomID), [roomID], "a failed accept must leave the invite where the user can still see and retry it")
        XCTAssertTrue(store.groups.isEmpty)
    }

    // MARK: - rejectGroupInvite

    func testRejectGroupInviteClearsTheInviteWithoutCreatingAGroup() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()

        store.rejectGroupInvite(store.incomingGroupInvites[0])
        await waitUntil { await client.rejectedGroupInviteRoomIDsSnapshot() == [roomID] }

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.incomingGroupInvites.isEmpty)
    }

    func testRejectGroupInviteSurfacesTheServersSpecificReason() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()
        await client.setErrorToThrow(FriendChatService.ServerError(status: 404, message: "Invitation not found."))

        store.rejectGroupInvite(store.incomingGroupInvites[0])
        await waitUntil { !store.errorMessage.isEmpty }

        XCTAssertEqual(store.errorMessage, "招待が見つかりません。")
        XCTAssertEqual(store.incomingGroupInvites.map(\.roomID), [roomID], "a failed reject must leave the invite where the user can still see and retry it")
    }

    func testRejectGroupInviteIgnoresASecondCallForTheSameRoomWhileTheFirstIsStillInFlight() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()

        store.rejectGroupInvite(store.incomingGroupInvites[0])
        store.rejectGroupInvite(store.incomingGroupInvites[0]) // simulates a rapid double-tap
        await waitUntil { store.incomingGroupInvites.isEmpty }

        let rejected = await client.rejectedGroupInviteRoomIDsSnapshot()
        XCTAssertEqual(rejected, [roomID], "a second tap while the first is still in flight must not fire a second network call")
    }

    // Mirrors testRejectIsIgnoredWhileAnAcceptForTheSameCodeIsStillInFlight for
    // the friend-request flow — accept and reject share pendingGroupActions
    // keyed by roomID, so whichever fires first must own that room until it
    // resolves.

    func testRejectGroupInviteIsIgnoredWhileAnAcceptForTheSameRoomIsStillInFlight() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()

        store.acceptGroupInvite(store.incomingGroupInvites[0])
        store.rejectGroupInvite(store.incomingGroupInvites[0]) // must be ignored — accept already owns this room
        await waitUntil { store.groups.contains(where: { $0.roomID == roomID }) }

        let rejected = await client.rejectedGroupInviteRoomIDsSnapshot()
        XCTAssertTrue(rejected.isEmpty, "reject must not fire while accept is already in flight for the same room")
    }

    func testAcceptGroupInviteIsIgnoredWhileARejectForTheSameRoomIsStillInFlight() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()

        store.rejectGroupInvite(store.incomingGroupInvites[0])
        store.acceptGroupInvite(store.incomingGroupInvites[0]) // must be ignored — reject already owns this room
        await waitUntil { store.incomingGroupInvites.isEmpty }

        let accepted = await client.acceptedGroupInviteRoomIDsSnapshot()
        XCTAssertTrue(accepted.isEmpty, "accept must not fire while reject is already in flight for the same room")
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testPendingGroupActionsTracksARejectInFlightAndClearsOnceItFinishes() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let invite = FriendChatService.GroupInvite(roomID: roomID, name: "受験対策", inviterCode: "ALICE1", inviterName: "Alice", invitedAt: 1_700_000_000_000)
        await client.setGroupInvites([invite])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshGroupInvites()

        store.rejectGroupInvite(store.incomingGroupInvites[0])
        XCTAssertTrue(store.pendingGroupActions.contains(roomID), "the room must be marked in-flight synchronously, before the network call resolves")

        await waitUntil { !store.pendingGroupActions.contains(roomID) }
    }

    // MARK: - renameGroup

    func testRenameGroupWithAnEmptyNameFailsWithoutCallingTheNetwork() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: [])]

        let succeeded = await store.renameGroup(roomID: roomID, name: "")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.groups.first?.name, "受験対策")
        let calls = await client.renameGroupCallsSnapshot()
        XCTAssertTrue(calls.isEmpty, "an empty name must be rejected locally, before ever reaching the network")
    }

    func testRenameGroupWithAWhitespaceOnlyNameFailsWithoutCallingTheNetwork() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: [])]

        let succeeded = await store.renameGroup(roomID: roomID, name: "   ")

        XCTAssertFalse(succeeded)
        let calls = await client.renameGroupCallsSnapshot()
        XCTAssertTrue(calls.isEmpty)
    }

    func testRenameGroupTrimsWhitespaceBeforeSendingIt() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: [])]

        let succeeded = await store.renameGroup(roomID: roomID, name: "  英語部  ")

        XCTAssertTrue(succeeded)
        let calls = await client.renameGroupCallsSnapshot()
        XCTAssertEqual(calls.first?.name, "英語部")
    }

    func testRenameGroupSuccessUpdatesTheNameInTheLocalListWithoutTouchingItsMembers() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let members = [FriendChatService.GroupMember(code: "ALICE1", name: "Alice")]
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: members)]

        let succeeded = await store.renameGroup(roomID: roomID, name: "英語部")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.groups.first?.name, "英語部")
        XCTAssertEqual(store.groups.first?.members, members)
        XCTAssertEqual(store.errorMessage, "")
    }

    func testRenameGroupForAGroupNotInTheLocalListStillSucceedsButChangesNothingLocally() async {
        // Mirrors the accept/duplicate-guard tests elsewhere in this file: a
        // rename can legitimately arrive for a room the local list doesn't
        // (yet) know about — e.g. a refresh() racing ahead of it — and must
        // not crash or insert a bogus entry.
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.renameGroup(roomID: roomID, name: "英語部")

        XCTAssertTrue(succeeded)
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testRenameGroupMapsAServerErrorToASpecificJapaneseMessage() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: [])]
        await client.setErrorToThrow(FriendChatService.ServerError(status: 403, message: "You are not a member of this group."))

        let succeeded = await store.renameGroup(roomID: roomID, name: "英語部")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.errorMessage, "このグループのメンバーではありません。")
        XCTAssertEqual(store.groups.first?.name, "受験対策", "a failed rename must leave the locally-shown name untouched")
    }

    func testRenameGroupFailureLeavesTheNameUnchanged() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: [])]
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        let succeeded = await store.renameGroup(roomID: roomID, name: "英語部")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.groups.first?.name, "受験対策")
    }

    // MARK: - removeGroupMember

    func testRemoveGroupMemberRemovesAnotherMemberFromTheLocalMemberList() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(
            roomID: roomID, name: "受験対策",
            members: [.init(code: "ME0000", name: "Me"), .init(code: "BOB222", name: "Bob")]
        )]

        let succeeded = await store.removeGroupMember(roomID: roomID, code: "BOB222")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.groups.count, 1, "removing a member must not remove the group itself")
        XCTAssertEqual(store.groups.first?.members.map(\.code), ["ME0000"])
        let calls = await client.removeGroupMemberCallsSnapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.code, "BOB222")
    }

    // Leaving is implemented as removing yourself — see removeGroupMember's
    // own doc comment in ProfileAndFriendsView.swift.
    func testRemoveGroupMemberForOnesOwnCodeLeavesTheGroupEntirely() async {
        defaults.set("ME0000", forKey: "studiquoFriendCode")
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(
            roomID: roomID, name: "受験対策",
            members: [.init(code: "ME0000", name: "Me"), .init(code: "BOB222", name: "Bob")]
        )]

        let succeeded = await store.removeGroupMember(roomID: roomID, code: store.myCode)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(store.groups.isEmpty, "removing yourself must drop the whole group from the local list, not just your own entry")
    }

    func testRemoveGroupMemberReturnsFalseWithoutCallingTheNetworkWhileAnotherGroupActionForTheSameRoomIsInFlight() async {
        // Mirrors the double-tap guards on accept/rejectGroupInvite —
        // removeGroupMember shares the same pendingGroupActions set keyed by
        // roomID, so any other in-flight group action for this room (an
        // accept, a reject, another remove) must block a second one here too.
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: [.init(code: "BOB222", name: "Bob")])]
        store.pendingGroupActions.insert(roomID)

        let succeeded = await store.removeGroupMember(roomID: roomID, code: "BOB222")

        XCTAssertFalse(succeeded)
        let calls = await client.removeGroupMemberCallsSnapshot()
        XCTAssertTrue(calls.isEmpty, "a group action already in flight for this room must block a second one, without ever reaching the network")
    }

    func testRemoveGroupMemberMapsAServerErrorToASpecificJapaneseMessage() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: [.init(code: "BOB222", name: "Bob")])]
        await client.setErrorToThrow(FriendChatService.ServerError(status: 404, message: "Member not found."))

        let succeeded = await store.removeGroupMember(roomID: roomID, code: "BOB222")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.errorMessage, "メンバーが見つかりません。")
    }

    func testRemoveGroupMemberFailureLeavesTheMemberListUnchanged() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let members = [FriendChatService.GroupMember(code: "ME0000", name: "Me"), .init(code: "BOB222", name: "Bob")]
        store.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: members)]
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        let succeeded = await store.removeGroupMember(roomID: roomID, code: "BOB222")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.groups.first?.members, members)
    }

    // MARK: - refreshGroupMessages

    func testRefreshGroupMessagesFetchesOnlyWhatsNewAndKeepsOlderLocalHistory() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setMessages([roomID: [
            .init(id: 1, text: "こんにちは", sentAt: 1_000, isMine: false),
            .init(id: 2, text: "よろしく", sentAt: 2_000, isMine: true),
        ]])

        await store.refreshGroupMessages(roomID: roomID)
        XCTAssertEqual(store.groupMessages[roomID]?.map(\.text), ["こんにちは", "よろしく"])

        await client.appendMessage(.init(id: 3, text: "新着", sentAt: 3_000, isMine: false), to: roomID)
        await store.refreshGroupMessages(roomID: roomID)

        XCTAssertEqual(store.groupMessages[roomID]?.map(\.text), ["こんにちは", "よろしく", "新着"])
        let requestedAfterValues = await client.messagesAfterRequestsSnapshot()
        XCTAssertEqual(requestedAfterValues, [0, 2], "the second fetch must ask only for what's new, unlike the 1:1 flow this doesn't keep a trailing window")
    }

    func testRefreshGroupMessagesKeepsDifferentGroupsSeparate() async {
        let client = MockFriendChatClient()
        let roomA = String(repeating: "a", count: 64)
        let roomB = String(repeating: "b", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setMessages([
            roomA: [.init(id: 1, text: "Group A", sentAt: 1_000, isMine: false)],
            roomB: [.init(id: 1, text: "Group B", sentAt: 1_000, isMine: false)],
        ])

        await store.refreshGroupMessages(roomID: roomA)
        await store.refreshGroupMessages(roomID: roomB)

        XCTAssertEqual(store.groupMessages[roomA]?.map(\.text), ["Group A"])
        XCTAssertEqual(store.groupMessages[roomB]?.map(\.text), ["Group B"])
    }

    func testRefreshGroupMessagesDoesNotDuplicateAMessageAlreadyKnown() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setMessages([roomID: [.init(id: 1, text: "こんにちは", sentAt: 1_000, isMine: false)]])
        await store.refreshGroupMessages(roomID: roomID)
        // Simulates the same message arriving again in a later fetch's
        // window (the request only ever asks for `after: lastID`, but a
        // defensive filter still guards against a duplicate id showing up).
        store.groupMessages[roomID] = [.init(id: 1, text: "こんにちは", sentAt: 1_000, isMine: false)]

        await store.refreshGroupMessages(roomID: roomID)

        XCTAssertEqual(store.groupMessages[roomID]?.count, 1)
    }

    func testRefreshGroupMessagesSilentlyIgnoresAnErrorAndKeepsExistingMessages() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setMessages([roomID: [.init(id: 1, text: "こんにちは", sentAt: 1_000, isMine: false)]])
        await store.refreshGroupMessages(roomID: roomID)
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        await store.refreshGroupMessages(roomID: roomID)

        XCTAssertEqual(store.groupMessages[roomID]?.map(\.text), ["こんにちは"], "a transient failure must not lose what's already been fetched")
        XCTAssertEqual(store.errorMessage, "", "this polls every couple of seconds while the screen is open, so a blip must stay silent rather than flash an alert")
    }

    func testRefreshGroupMessagesTreatsAnEmptySuccessfulResponseAsANoOp() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refreshGroupMessages(roomID: roomID)

        XCTAssertNil(store.groupMessages[roomID], "an empty response for a room with no history yet must not create a bogus empty entry")
    }

    // MARK: - sendGroupMessage

    func testSendGroupMessageWithAnEmptyTextFailsWithoutCallingTheNetwork() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.sendGroupMessage("", roomID: roomID)

        XCTAssertFalse(succeeded)
        XCTAssertTrue(store.groupMessages[roomID, default: []].isEmpty)
        let sent = await client.sentMessages()
        XCTAssertTrue(sent.isEmpty, "an empty message must be rejected locally, before ever reaching the network")
    }

    func testSendGroupMessageWithAWhitespaceOnlyTextFailsWithoutCallingTheNetwork() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.sendGroupMessage("   \n  ", roomID: roomID)

        XCTAssertFalse(succeeded)
        let sent = await client.sentMessages()
        XCTAssertTrue(sent.isEmpty)
    }

    // Unlike the 1:1 flow (which silently truncates an over-length message to
    // the same limit), sendGroupMessage rejects it outright — see its own
    // guard in ProfileAndFriendsView.swift.
    func testSendGroupMessageWithTextOverTheLengthLimitFailsWithoutCallingTheNetwork() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let tooLong = String(repeating: "あ", count: 2_001)

        let succeeded = await store.sendGroupMessage(tooLong, roomID: roomID)

        XCTAssertFalse(succeeded)
        let sent = await client.sentMessages()
        XCTAssertTrue(sent.isEmpty, "an over-length message must be rejected locally rather than silently truncated")
    }

    func testSendGroupMessageSuccessAppendsTheSentMessageToTheRoomsMessageList() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.sendGroupMessage("こんにちは", roomID: roomID)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.groupMessages[roomID]?.map(\.text), ["こんにちは"])
        XCTAssertEqual(store.errorMessage, "")
        let sent = await client.sentMessages()
        XCTAssertEqual(sent, [.init(text: "こんにちは", roomID: roomID)])
    }

    func testSendGroupMessageTrimsSurroundingWhitespaceBeforeSendingIt() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.sendGroupMessage("  こんにちは  ", roomID: roomID)

        XCTAssertTrue(succeeded)
        let sent = await client.sentMessages()
        XCTAssertEqual(sent, [.init(text: "こんにちは", roomID: roomID)])
    }

    func testSendGroupMessageAppendsToExistingHistoryWithoutLosingIt() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setMessages([roomID: [.init(id: 1, text: "先に届いたメッセージ", sentAt: 1_000, isMine: false)]])
        await store.refreshGroupMessages(roomID: roomID)

        let succeeded = await store.sendGroupMessage("送信するメッセージ", roomID: roomID)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.groupMessages[roomID]?.map(\.text), ["先に届いたメッセージ", "送信するメッセージ"])
    }

    func testSendGroupMessageMapsAServerErrorToASpecificJapaneseMessage() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 403, message: "You are not a member of this group."))

        let succeeded = await store.sendGroupMessage("こんにちは", roomID: roomID)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.errorMessage, "このグループのメンバーではありません。")
    }

    func testSendGroupMessageFailureAddsNothingToTheList() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        let succeeded = await store.sendGroupMessage("こんにちは", roomID: roomID)

        XCTAssertFalse(succeeded)
        XCTAssertTrue(store.groupMessages[roomID, default: []].isEmpty)
        XCTAssertEqual(store.errorMessage, "送信できませんでした。")
    }

    func testCancelGroupMessageRetractsItThroughTheSharedChatAPIAndUpdatesTheGroupImmediately() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let message = FriendChatService.Message(id: 7, text: "取り消す", sentAt: 1_000, isMine: true)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groupMessages[roomID] = [message]

        await store.cancelGroupMessage(message, roomID: roomID)

        XCTAssertEqual(store.groupMessages[roomID]?.first?.text, "")
        XCTAssertEqual(store.groupMessages[roomID]?.first?.isCanceled, true)
        let canceled = await client.canceledMessagesSnapshot()
        XCTAssertEqual(canceled.count, 1)
        XCTAssertEqual(canceled.first?.roomID, roomID)
        XCTAssertEqual(canceled.first?.messageID, 7)
    }

    func testCancelGroupMessageRestoresTheBubbleWhenTheServerRejectsTheRetraction() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let message = FriendChatService.Message(id: 8, text: "残す", sentAt: 1_000, isMine: true)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.groupMessages[roomID] = [message]
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        await store.cancelGroupMessage(message, roomID: roomID)

        XCTAssertEqual(store.groupMessages[roomID]?.first?.text, "残す")
        XCTAssertNotEqual(store.groupMessages[roomID]?.first?.isCanceled, true)
        XCTAssertEqual(store.errorMessage, "メッセージを取り消せませんでした。もう一度お試しください。")
    }

    func testReportGroupMessageUsesItsGroupRoomAndServerMessageID() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let message = FriendChatService.Message(id: 9, text: "通報対象", sentAt: 1_000, isMine: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.reportGroupMessage(message, roomID: roomID, reason: "迷惑行為")

        let reports = await client.reportedMessagesSnapshot()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.roomID, roomID)
        XCTAssertEqual(reports.first?.messageID, 9)
        XCTAssertEqual(reports.first?.reason, "迷惑行為")
    }

    // MARK: - group list persistence

    // Mirrors testSeenStatusPersistsAcrossARelaunchSoTheBadgeDoesNotReappearForAnAlreadySeenRequest
    // for the group list: groups must survive a relaunch on their own,
    // without waiting for the next refreshGroups() poll to repopulate them.
    func testGroupsPersistAcrossARelaunch() async {
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let group = FriendChatService.Group(
            roomID: roomID, name: "受験対策",
            members: [.init(code: "ME0000", name: "Me"), .init(code: "ALICE1", name: "Alice")]
        )
        let firstLaunch = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        firstLaunch.groups = [group]

        let secondLaunch = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        XCTAssertEqual(secondLaunch.groups.map(\.roomID), [roomID])
        XCTAssertEqual(secondLaunch.groups.first?.name, "受験対策")
        XCTAssertEqual(secondLaunch.groups.first?.members, group.members)
    }

    func testAnEmptyGroupsListPersistsJustAsWellAsANonEmptyOne() async {
        // Regression coverage for the shape of bug this session's
        // AppSchemaCloudKitCompatibilityTests fix guarded against elsewhere:
        // leaving the last group must not leave stale data behind for the
        // next launch to incorrectly resurrect.
        let client = MockFriendChatClient()
        let roomID = String(repeating: "a", count: 64)
        let firstLaunch = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        firstLaunch.groups = [FriendChatService.Group(roomID: roomID, name: "受験対策", members: [])]
        firstLaunch.groups = []

        let secondLaunch = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        XCTAssertTrue(secondLaunch.groups.isEmpty)
    }

    func testCorruptedPersistedGroupsDataFallsBackToAnEmptyListInsteadOfCrashing() {
        defaults.set(Data("not valid json".utf8), forKey: "studiquoGroups")

        let store = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)

        XCTAssertTrue(store.groups.isEmpty)
    }

    func testASuccessfulPollDoesNotClearAnUnrelatedErrorMessage() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.errorMessage = "フレンド申請を承認できませんでした。"

        await store.refreshFriends()

        XCTAssertEqual(
            store.errorMessage, "フレンド申請を承認できませんでした。",
            "a background poll succeeding a moment later must not silently wipe out a different, not-yet-seen error"
        )
    }

    func testRefreshMessagesTreatsAnEmptySuccessfulResponseAsSuccessNotFailure() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        for _ in 0..<5 {
            await store.refreshMessages(for: alice)
        }

        XCTAssertEqual(store.errorMessage, "", "an empty but successful response (no new messages yet) must never be mistaken for a failure")
    }

    func testRoomAccessFailureIsNotMisreportedAsServerConnectivityFailure() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]
        await client.setErrorToThrow(FriendChatService.ServerError(status: 403, message: "You are not a participant in this room."))

        await store.refreshMessages(for: alice)

        XCTAssertEqual(store.errorMessage, "チャットルームにアクセスできません。フレンド情報を更新してください。")
    }

    // Regression coverage for "same-text reconciliation could mismatch
    // order": two in-flight messages with identical text used to be
    // reconciled by matching text alone, which silently assumed the server
    // received them in the same order the client issued them — not
    // guaranteed over the network. `clientMessageID` makes the match exact
    // regardless of arrival order.
    func testRefreshMessagesReconcilesByClientMessageIDEvenWhenIdenticalTextArrivesOutOfOrder() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.send("hi", to: alice)
        store.send("hi", to: alice)
        await waitUntil { await client.sentMessages().count == 2 }

        let local = store.messages(for: alice)
        XCTAssertEqual(local.count, 2)
        let firstLocalID = local[0].id
        let secondLocalID = local[1].id

        // The server received these two identical-text sends in the
        // OPPOSITE order from how the client issued them — a plausible
        // network race, not a client bug. Reconciliation must still match
        // each server echo back to the local copy that actually produced
        // it, not just the next unclaimed "hi" in local order.
        await client.setMessages(["room-a": [
            .init(id: 1, text: "hi", sentAt: 1_000, isMine: true, clientMessageID: secondLocalID.uuidString),
            .init(id: 2, text: "hi", sentAt: 2_000, isMine: true, clientMessageID: firstLocalID.uuidString),
        ]])

        await store.refreshMessages(for: alice)

        let reconciled = store.messages(for: alice)
        XCTAssertEqual(reconciled.first(where: { $0.id == firstLocalID })?.serverID, 2)
        XCTAssertEqual(reconciled.first(where: { $0.id == secondLocalID })?.serverID, 1)
    }

    func testCancelLeavesOnlyMyMessageAsCanceledInVisibleConversation() {
        let store = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let mine = FriendMessage(id: UUID(), friendID: friend.id, text: "remove me", sentAt: Date(timeIntervalSince1970: 1), isMine: true, isCanceled: false)
        let incoming = FriendMessage(id: UUID(), friendID: friend.id, text: "keep me", sentAt: Date(timeIntervalSince1970: 2), isMine: false, isCanceled: false)
        store.friends = [friend]
        store.messages = [mine, incoming]

        store.cancel(mine)
        store.cancel(incoming)

        let visible = store.messages(for: friend)
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].id, mine.id)
        XCTAssertEqual(visible[0].text, "")
        XCTAssertEqual(visible[0].isCanceled, true)
        XCTAssertEqual(visible[1].text, "keep me")
        XCTAssertEqual(visible[1].isCanceled, false)
    }

    // Regression coverage for "canceling a message only hides it on the
    // sender's own screen": a message the server has already confirmed
    // (has a serverID) must actually be retracted server-side too, not
    // just hidden locally.

    func testCancelCallsTheServerToRetractAConfirmedMessage() async {
        let client = MockFriendChatClient()
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let mine = FriendMessage(id: UUID(), friendID: friend.id, text: "oops", sentAt: Date(), isMine: true, isCanceled: false, serverID: 42)
        store.friends = [friend]
        store.messages = [mine]

        store.cancel(mine)
        await waitUntil { await client.canceledMessagesSnapshot().count == 1 }

        let canceled = await client.canceledMessagesSnapshot()
        XCTAssertEqual(canceled.first?.roomID, "room-a")
        XCTAssertEqual(canceled.first?.messageID, 42)
        let visible = store.messages(for: friend)
        XCTAssertEqual(visible.first?.text, "")
        XCTAssertEqual(visible.first?.isCanceled, true)
    }

    func testCancelRevertsLocallyAndSurfacesAnErrorWhenTheServerRejectsIt() async {
        let client = MockFriendChatClient()
        await client.setErrorToThrow(URLError(.notConnectedToInternet))
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let mine = FriendMessage(id: UUID(), friendID: friend.id, text: "oops", sentAt: Date(), isMine: true, isCanceled: false, serverID: 42)
        store.friends = [friend]
        store.messages = [mine]

        store.cancel(mine)
        await waitUntil { store.messages(for: friend).first?.isCanceled == false }

        let visible = store.messages(for: friend)
        XCTAssertEqual(
            visible.first?.text, "oops",
            "a failed retraction must not leave the message looking canceled — the recipient never actually lost the original text"
        )
        XCTAssertEqual(visible.first?.isCanceled, false)
        XCTAssertNotEqual(store.errorMessage, "")
    }

    func testCancelOfAMessageWithNoServerIDYetDoesNotCallTheServer() async {
        let client = MockFriendChatClient()
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let mine = FriendMessage(id: UUID(), friendID: friend.id, text: "not synced yet", sentAt: Date(), isMine: true, isCanceled: false)
        store.friends = [friend]
        store.messages = [mine]

        store.cancel(mine)

        XCTAssertEqual(store.messages(for: friend).first?.isCanceled, true, "still hidden locally even though there's nothing to retract server-side yet")
        let canceled = await client.canceledMessagesSnapshot()
        XCTAssertEqual(canceled.count, 0)
    }

    // Regression coverage for "canceling while a message is still sending
    // doesn't actually stop the send": there's no way to un-send an HTTP
    // request already issued, so the fix isn't stopping it — it's making
    // sure the message still gets genuinely retracted server-side the
    // moment it has a serverID to retract, instead of silently reaching
    // the recipient uncanceled just because the cancel happened first.
    func testCancelingAnInFlightMessageStillRetractsItServerSideOnceTheSendCompletes() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.send("oops", to: alice)
        let optimistic = store.messages(for: alice).first!
        XCTAssertNil(optimistic.serverID, "this test only proves something if the send genuinely hasn't resolved yet")

        // Canceled before the pending send has any serverID to retract —
        // the old behavior just hid it locally and left it at that.
        store.cancel(optimistic)
        await waitUntil { await client.canceledMessagesSnapshot().count == 1 }

        let canceled = await client.canceledMessagesSnapshot()
        XCTAssertEqual(canceled.first?.roomID, "room-a")
        let sent = await client.sentMessages()
        XCTAssertEqual(sent.count, 1, "the network send itself can't actually be stopped — it still reaches the server")
    }

    // MARK: Block / unblock / report

    func testBlockCallsTheServerAndMarksTheRoomBlockedLocally() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.block(alice)
        await waitUntil { await client.blockedByMeRoomsSnapshot().contains("room-a") }

        XCTAssertTrue(store.blockedByMeRoomIDs.contains("room-a"))
    }

    func testUnblockCallsTheServerAndClearsTheLocalBlockedState() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]
        store.blockedByMeRoomIDs = ["room-a"]
        // Seeds the mock's own server-side state as genuinely blocked, so
        // waiting on it clearing observes a real transition — starting from
        // an already-empty set would make the wait below pass instantly,
        // before unblock's async Task has actually run.
        _ = try? await client.block(roomID: "room-a")

        store.unblock(alice)
        await waitUntil { await !client.blockedByMeRoomsSnapshot().contains("room-a") }

        XCTAssertFalse(store.blockedByMeRoomIDs.contains("room-a"))
    }

    func testBlockSurfacesAnErrorWhenTheServerRejectsIt() async {
        let client = MockFriendChatClient()
        await client.setErrorToThrow(URLError(.notConnectedToInternet))
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.block(alice)
        await waitUntil { store.errorMessage != "" }

        XCTAssertFalse(store.blockedByMeRoomIDs.contains("room-a"), "a failed block must not be reflected locally")
    }

    func testRefreshBlockStatusReadsWhetherThisUserHasBlockedTheFriend() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]
        _ = try? await client.block(roomID: "room-a") // simulate a block made from another device

        await store.refreshBlockStatus(for: alice)

        XCTAssertTrue(store.blockedByMeRoomIDs.contains("room-a"))
    }

    func testReportSendsTheMessagesServerIDAndReasonToTheCorrectRoom() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let theirs = FriendMessage(id: UUID(), friendID: alice.id, text: "何か", sentAt: Date(), isMine: false, isCanceled: false, serverID: 7)
        store.friends = [alice]
        store.messages = [theirs]

        store.report(theirs, reason: "スパム")
        await waitUntil { await client.reportedMessagesSnapshot().count == 1 }

        let reported = await client.reportedMessagesSnapshot()
        XCTAssertEqual(reported.first?.roomID, "room-a")
        XCTAssertEqual(reported.first?.messageID, 7)
        XCTAssertEqual(reported.first?.reason, "スパム")
    }

    func testReportOfAMessageWithNoServerIDDoesNotCallTheServer() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let notYetSynced = FriendMessage(id: UUID(), friendID: alice.id, text: "何か", sentAt: Date(), isMine: false, isCanceled: false)
        store.friends = [alice]
        store.messages = [notYetSynced]

        store.report(notYetSynced, reason: "スパム")

        let reported = await client.reportedMessagesSnapshot()
        XCTAssertEqual(reported.count, 0)
    }

    // Regression coverage for the actual point of server-side retraction:
    // the RECIPIENT (or any device that already fetched the message before
    // it was canceled) must see the retraction too, not just the sender.
    func testRefreshMessagesPropagatesARetractionToAMessageThisDeviceAlreadyHas() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        await client.setMessages(["room-a": [.init(id: 1, text: "oops, wrong chat", sentAt: 1_000, isMine: false)]])
        await store.refreshMessages(for: alice)
        XCTAssertEqual(store.messages(for: alice).first?.text, "oops, wrong chat")

        // The sender retracted it after this device already fetched it —
        // simulate the server's now-updated state directly, the same shape
        // a real cancel would leave behind.
        await client.setMessages(["room-a": [.init(id: 1, text: "", sentAt: 1_000, isMine: false, isCanceled: true)]])
        await store.refreshMessages(for: alice)

        let visible = store.messages(for: alice)
        XCTAssertEqual(visible.first?.text, "")
        XCTAssertEqual(visible.first?.isCanceled, true, "a retraction must reach a device that already had the message, not just devices that hadn't fetched it yet")
    }

    // Regression coverage for "materials sent before attachments could be
    // re-shared are permanently unopenable": a legacy attachment (no
    // `remoteRoomID`, not yet `sourceKind == "pdf"`) is repaired by
    // re-rendering and re-uploading it, then editing the message that
    // carries it in place — and that repair must actually reach every
    // reader of the room, including one whose cached copy is old enough to
    // have scrolled out of the normal rolling reconcile window.

    private func legacyAttachment(id: String = "notebook-ABC123", title: String = "数学ノート") -> FriendMessageAttachment {
        // Mirrors exactly what a pre-fix message's payload looked like: no
        // `sourceKind`/`sourceID`/`remoteRoomID` at all, so `resolvedSourceKind`/
        // `resolvedSourceID` fall back to parsing them out of `id`.
        FriendMessageAttachment(id: id, title: title, kind: "notebook", icon: "doc.richtext")
    }

    private func repairedAttachment(from original: FriendMessageAttachment, remoteID: String = "attachment-1", roomID: String = "room-a") -> FriendMessageAttachment {
        FriendMessageAttachment(
            id: original.id, title: original.title, kind: original.kind, icon: original.icon,
            sourceKind: "pdf", sourceID: remoteID, remoteRoomID: roomID
        )
    }

    func testLegacyAttachmentsInTextFindsAnAttachmentWithNoRemoteRoomID() {
        let legacy = legacyAttachment()
        let found = FriendMessageAttachment.legacyAttachments(in: legacy.messageLine)
        XCTAssertEqual(found.map(\.id), [legacy.id])
    }

    func testLegacyAttachmentsInTextExcludesAnAlreadyRepairedPdfAttachment() {
        let repaired = repairedAttachment(from: legacyAttachment())
        XCTAssertTrue(FriendMessageAttachment.legacyAttachments(in: repaired.messageLine).isEmpty, "すでにPDF化・アップロード済みの添付は、修復対象に含まれてはいけません。")
    }

    // Regression coverage for "資料や写真がまだ開けるようになっていない": a
    // legacy attachment can have `sourceKind == "pdf"` for a completely
    // ordinary, unrelated reason — an imported PDF *file* (see
    // `saveFileAttachment`) uses "pdf" as its normal, currently-working
    // kind, not just as the in-app-material repair's target marker. Judging
    // "still broken" by `sourceKind` alone wrongly treated a legacy PDF file
    // (or a legacy photo, whose kind is "photo") as already fine, simply
    // because it wasn't the exact string "pdf"-after-repair. The only
    // reliable signal is `remoteRoomID` — nil means the recipient's device
    // has nowhere to fetch it from, regardless of what kind it is.

    private func legacyFileAttachment(id: String = "file-/tmp/report.pdf-ABC", sourceKind: String = "pdf", sourcePath: String? = "/tmp/report.pdf") -> FriendMessageAttachment {
        FriendMessageAttachment(id: id, title: "report.pdf", kind: "PDF", icon: "doc.richtext", sourceKind: sourceKind, sourcePath: sourcePath)
    }

    func testLegacyAttachmentsInTextFindsALegacyPdfFileEvenThoughItsSourceKindIsAlreadyPdf() {
        let legacyFile = legacyFileAttachment()
        let found = FriendMessageAttachment.legacyAttachments(in: legacyFile.messageLine)
        XCTAssertEqual(found.map(\.id), [legacyFile.id], "sourceKindがすでに\"pdf\"であっても、remoteRoomIDがなければ未修復として扱われる必要があります。")
    }

    func testLegacyAttachmentsInTextFindsALegacyPhoto() {
        let legacyPhoto = FriendMessageAttachment(id: "photo-/tmp/pic.jpg-XYZ", title: "写真", kind: "写真", icon: "photo", sourceKind: "photo", sourcePath: "/tmp/pic.jpg")
        let found = FriendMessageAttachment.legacyAttachments(in: legacyPhoto.messageLine)
        XCTAssertEqual(found.map(\.id), [legacyPhoto.id], "写真も、他の資料と同じく未修復として見つかる必要があります。")
    }

    func testRepairLegacyAttachmentsReUploadsAPhotoStillSittingAtItsOwnSourcePathWhenTheAppMaterialResolverCannotHandleIt() async throws {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("fake jpeg bytes".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let legacyPhoto = FriendMessageAttachment(
            id: "photo-\(tempFile.path)-XYZ", title: "写真", kind: "写真", icon: "photo",
            sourceKind: "photo", sourcePath: tempFile.path
        )
        await client.setMessages(["room-a": [.init(id: 1, text: legacyPhoto.messageLine, sentAt: 1_000, isMine: true)]])
        await store.refreshMessages(for: alice)

        // The in-app-material resolver has nothing to do with a photo — it
        // must return the attachment unchanged, the same as it would for a
        // deleted notebook, so the fallback below is what actually repairs it.
        await store.repairLegacyAttachments(for: alice) { attachment, _ in attachment }

        let edits = await client.editedMessagesSnapshot()
        XCTAssertEqual(edits.count, 1, "アプリ内資料の解決処理では直せない写真も、修復の対象になる必要があります。")
        let editedAttachment = edits.first.flatMap { FriendMessageAttachment.attachments(in: $0.text).first }
        XCTAssertEqual(editedAttachment?.remoteRoomID, "room-a", "写真の実体を再アップロードして、遠隔ルームIDを持たせる必要があります。")

        let uploaded = await client.uploadedAttachmentsSnapshot()
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(uploaded.first?.contentType, "image/jpeg", "拡張子から正しいcontent-typeが推測される必要があります。")
    }

    func testRepairLegacyAttachmentsSkipsAPhotoWhoseFileNoLongerExistsOnDisk() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        let missingPath = "/tmp/studiquo-tests-\(UUID().uuidString)-does-not-exist.jpg"
        let legacyPhoto = FriendMessageAttachment(id: "photo-\(missingPath)-XYZ", title: "写真", kind: "写真", icon: "photo", sourceKind: "photo", sourcePath: missingPath)
        await client.setMessages(["room-a": [.init(id: 1, text: legacyPhoto.messageLine, sentAt: 1_000, isMine: true)]])
        await store.refreshMessages(for: alice)

        await store.repairLegacyAttachments(for: alice) { attachment, _ in attachment }

        let edits = await client.editedMessagesSnapshot()
        XCTAssertTrue(edits.isEmpty, "写真ファイルがもう端末に残っていない場合は、書き換えようとしてはいけません。")
    }

    func testLegacyAttachmentsInTextExcludesPlainTextWithNoAttachment() {
        XCTAssertTrue(FriendMessageAttachment.legacyAttachments(in: "普通のメッセージです").isEmpty)
    }

    func testTextReplacingAttachmentReplacesOnlyTheMatchingLineAndPreservesEverythingElse() {
        let legacy = legacyAttachment(id: "notebook-ABC123")
        let otherAttachment = legacyAttachment(id: "deck-XYZ789", title: "単語帳")
        let originalText = "見て見て\n\(legacy.messageLine)\n\(otherAttachment.messageLine)"
        let repaired = repairedAttachment(from: legacy)

        let newText = FriendMessageAttachment.textReplacingAttachment(in: originalText, id: legacy.id, with: repaired)
        let lines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines[0], "見て見て", "本文は変わってはいけません。")

        // `messageLine` encodes a plain dictionary, whose JSON key order
        // isn't guaranteed to be stable between two separate encodings of
        // the same content — comparing decoded fields, not raw strings, is
        // what actually pins down "this one changed, that one didn't."
        let decoded = FriendMessageAttachment.attachments(in: newText)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.first { $0.id == legacy.id }?.resolvedSourceKind, "pdf", "指定した添付だけが、修復後の内容に置き換わる必要があります。")
        XCTAssertEqual(decoded.first { $0.id == otherAttachment.id }?.resolvedSourceKind, "deck", "他の添付は変わってはいけません。")
    }

    func testRefreshMessagesPropagatesAnEditToAMessageThisDeviceAlreadyHas() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        await client.setMessages(["room-a": [.init(id: 1, text: "legacy attachment reference", sentAt: 1_000, isMine: false)]])
        await store.refreshMessages(for: alice)
        XCTAssertEqual(store.messages(for: alice).first?.text, "legacy attachment reference")

        // The sender edited it after this device already fetched it —
        // simulate the server's now-updated state directly.
        await client.setMessages(["room-a": [.init(id: 1, text: "repaired attachment reference", sentAt: 1_000, isMine: false)]])
        await store.refreshMessages(for: alice)

        XCTAssertEqual(store.messages(for: alice).first?.text, "repaired attachment reference", "an edit must reach a device that already had the message, not just devices that hadn't fetched it yet")
    }

    func testLegacyAttachmentMessagesFindsOnlyThisUsersUnrepairedAttachments() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        let legacy = legacyAttachment()
        let repaired = repairedAttachment(from: legacyAttachment(id: "notebook-DEF456"))
        await client.setMessages(["room-a": [
            .init(id: 1, text: legacy.messageLine, sentAt: 1_000, isMine: true),
            .init(id: 2, text: repaired.messageLine, sentAt: 2_000, isMine: true),
            .init(id: 3, text: legacy.messageLine, sentAt: 3_000, isMine: false),
            .init(id: 4, text: legacy.messageLine, sentAt: 4_000, isMine: true, isCanceled: true),
        ]])
        await store.refreshMessages(for: alice)

        let candidates = store.legacyAttachmentMessages(for: alice)
        XCTAssertEqual(candidates.count, 1, "自分が送った・未修復・取消されていないメッセージだけが対象になる必要があります。")
        XCTAssertEqual(candidates.first?.attachment.id, legacy.id)
    }

    func testRepairLegacyAttachmentsEditsTheMessageAndUpdatesLocalTextWhenTheMaterialIsStillAvailable() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        let legacy = legacyAttachment()
        await client.setMessages(["room-a": [.init(id: 1, text: legacy.messageLine, sentAt: 1_000, isMine: true)]])
        await store.refreshMessages(for: alice)

        let repaired = repairedAttachment(from: legacy)
        await store.repairLegacyAttachments(for: alice) { attachment, _ in
            XCTAssertEqual(attachment.id, legacy.id, "解決処理には、修復が必要な添付ファイルがそのまま渡される必要があります。")
            return repaired
        }

        let edits = await client.editedMessagesSnapshot()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.roomID, "room-a")
        XCTAssertEqual(edits.first?.messageID, 1)
        let editedAttachment = edits.first.flatMap { FriendMessageAttachment.attachments(in: $0.text).first }
        XCTAssertEqual(editedAttachment?.resolvedSourceKind, "pdf", "修復後のメッセージ本文は、新しい添付情報に置き換わっている必要があります。")
        XCTAssertEqual(editedAttachment?.remoteRoomID, "room-a")

        let localAttachment = store.messages(for: alice).first.flatMap { FriendMessageAttachment.attachments(in: $0.text).first }
        XCTAssertEqual(localAttachment?.resolvedSourceKind, "pdf", "この端末が持つメッセージの表示内容も、修復結果に更新される必要があります。")
    }

    func testRepairLegacyAttachmentsSkipsAMessageWhoseMaterialCanNoLongerBeResolvedLocally() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        let legacy = legacyAttachment()
        await client.setMessages(["room-a": [.init(id: 1, text: legacy.messageLine, sentAt: 1_000, isMine: true)]])
        await store.refreshMessages(for: alice)

        // The material was deleted since — `resolvedAppMessageAttachment`
        // returns the attachment unchanged when it can't find anything to
        // render, exactly as it does in the app today.
        await store.repairLegacyAttachments(for: alice) { attachment, _ in attachment }

        let edits = await client.editedMessagesSnapshot()
        XCTAssertTrue(edits.isEmpty, "元の資料がもう見つからない場合は、メッセージを書き換えようとしてはいけません。")
        let stillLegacy = store.messages(for: alice).first.map { FriendMessageAttachment.legacyAttachments(in: $0.text) }
        XCTAssertEqual(stillLegacy?.count, 1, "修復できなかった場合、添付は未修復のまま残る必要があります。")
    }

    func testReconcileLegacyAttachmentsPicksUpARepairMadeLongAfterThisDeviceLastSawTheMessage() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        let legacy = legacyAttachment()
        var initial: [FriendChatService.Message] = [.init(id: 1, text: legacy.messageLine, sentAt: 1_000, isMine: false)]
        // Many messages in between — enough to push id 1 outside
        // `recentReconcileWindow` (20) once this device has caught up to
        // the latest one.
        for index in 2...30 { initial.append(.init(id: index, text: "filler \(index)", sentAt: Double(index) * 1_000, isMine: false)) }
        await client.setMessages(["room-a": initial])
        await store.refreshMessages(for: alice)
        let initialLegacyCount = store.messages(for: alice).first { $0.serverID == 1 }.map { FriendMessageAttachment.legacyAttachments(in: $0.text).count }
        XCTAssertEqual(initialLegacyCount, 1)

        // The sender (a different device) repairs the attachment — this
        // simulates the server's now-updated state directly, the same as
        // `editMessage` would leave behind.
        let repaired = repairedAttachment(from: legacy)
        var updated = initial
        updated[0] = .init(id: 1, text: repaired.messageLine, sentAt: 1_000, isMine: false)
        await client.setMessages(["room-a": updated])

        // A plain poll must NOT pick this up — message id 1 is now well
        // outside the rolling reconcile window, which is exactly the gap
        // `reconcileLegacyAttachments` exists to close.
        await store.refreshMessages(for: alice)
        let stillLegacyCount = store.messages(for: alice).first { $0.serverID == 1 }.map { FriendMessageAttachment.legacyAttachments(in: $0.text).count }
        XCTAssertEqual(stillLegacyCount, 1, "通常のポーリングでは、ウィンドウの外に出た古いメッセージの修復までは拾えないはずです。")

        await store.reconcileLegacyAttachments(for: alice)
        let repairedCount = store.messages(for: alice).first { $0.serverID == 1 }.map { FriendMessageAttachment.legacyAttachments(in: $0.text).count }
        XCTAssertEqual(repairedCount, 0, "古いメッセージへの修復も、専用の確認処理で拾える必要があります。")
    }

    func testReconcileLegacyAttachmentsDoesNothingWhenNoLegacyAttachmentsAreCached() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        await client.setMessages(["room-a": [.init(id: 1, text: "just a normal message", sentAt: 1_000, isMine: false)]])
        await store.refreshMessages(for: alice)

        // Should be a no-op — no lookup call should even be needed since
        // nothing cached still looks like an unrepaired legacy attachment.
        await store.reconcileLegacyAttachments(for: alice)
        XCTAssertEqual(store.messages(for: alice).first?.text, "just a normal message")
    }

    func testBlankUnknownAndOverlongMessagesAreHandled() async {
        let client = MockFriendChatClient()
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let stranger = FriendRecord(id: UUID(), name: "Mallory", code: "MALLRY", todayStudySeconds: 0, roomID: "room-x", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]

        store.send("   ", to: friend)
        store.send("hello", to: stranger)
        XCTAssertTrue(store.messages(for: friend).isEmpty)
        let initiallySent = await client.sentMessages()
        XCTAssertTrue(initiallySent.isEmpty)

        let longText = String(repeating: "a", count: 2_100)
        store.send(longText, to: friend)
        await waitUntil { await client.sentMessages().count == 1 }
        let sent = await client.sentMessages()
        XCTAssertEqual(store.messages(for: friend).first?.text.count, 2_000)
        XCTAssertEqual(sent.first?.text.count, 2_000)
    }

    // Regression coverage for "a message made of invisible characters can be
    // sent": .whitespacesAndNewlines doesn't cover zero-width characters, so
    // trimming alone lets a blank-looking bubble through.
    func testMessagesMadeEntirelyOfInvisibleCharactersAreRejected() async {
        let client = MockFriendChatClient()
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [friend]

        let zeroWidthSpace = "\u{200B}"
        let zeroWidthJoiner = "\u{200D}"
        let byteOrderMark = "\u{FEFF}"
        store.send(zeroWidthSpace, to: friend)
        store.send("  \(zeroWidthJoiner)\(byteOrderMark)  ", to: friend)

        XCTAssertTrue(store.messages(for: friend).isEmpty)
        let sent = await client.sentMessages()
        XCTAssertTrue(sent.isEmpty)

        // A message that mixes invisible characters with real content must
        // still go through untouched. (Unlike the joiner used here,
        // zero-width space is itself part of .whitespacesAndNewlines, so
        // trimming alone already strips it when it's at either end —
        // this checks a character trimming doesn't touch.)
        store.send("\(zeroWidthJoiner)hello\(zeroWidthJoiner)", to: friend)
        await waitUntil { await client.sentMessages().count == 1 }
        XCTAssertEqual(store.messages(for: friend).first?.text, "\(zeroWidthJoiner)hello\(zeroWidthJoiner)")
    }

    func testAttachmentPayloadCanBeSentAsStandaloneMessage() async {
        let client = MockFriendChatClient()
        let friend = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let attachment = FriendMessageAttachment(id: "notebook-123", title: "数学PDF", kind: "PDF", icon: "doc.richtext")
        store.friends = [friend]

        store.send(attachment.messageLine, to: friend)
        await waitUntil { await client.sentMessages().count == 1 }

        XCTAssertTrue(store.messages(for: friend).first?.text.contains("studiquo-attachment") == true)
        let sent = await client.sentMessages()
        XCTAssertTrue(sent.first?.text.contains("studiquo-attachment") == true)
    }

    func testSentPhotoAttachmentSurvivesRelaunchAndStillHasRemoteDownloadLocation() throws {
        let client = MockFriendChatClient()
        let friend = FriendRecord(
            id: UUID(), name: "Alice", code: "ALICE1",
            todayStudySeconds: 0, roomID: "room-a", isDemo: false
        )
        let attachment = FriendMessageAttachment(
            id: "photo-attachment-1",
            title: "ノート切り抜き.jpg",
            kind: "写真",
            icon: "photo",
            sourceKind: "photo",
            remoteRoomID: "room-a"
        )
        let firstLaunch = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        firstLaunch.friends = [friend]
        firstLaunch.messages = [
            FriendMessage(
                id: UUID(), friendID: friend.id, text: attachment.messageLine,
                sentAt: Date(), isMine: true, isCanceled: false, serverID: 42,
                roomID: "room-a"
            )
        ]

        let relaunched = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let restoredMessage = try XCTUnwrap(relaunched.messages(for: friend).first)
        let restoredAttachment = try XCTUnwrap(FriendMessageAttachment.attachments(in: restoredMessage.text).first)

        XCTAssertEqual(restoredAttachment.id, attachment.id)
        XCTAssertEqual(restoredAttachment.title, "ノート切り抜き.jpg")
        XCTAssertEqual(restoredAttachment.resolvedSourceKind, "photo")
        XCTAssertEqual(restoredAttachment.remoteRoomID, "room-a", "再起動後も送信済み画像をサーバーから再表示できる必要があります。")
        XCTAssertEqual(restoredMessage.serverID, 42)
    }

    func testMalformedAttachmentInPersistedHistoryDoesNotCrashRelaunchOrCreateABrokenImage() {
        let friend = FriendRecord(
            id: UUID(), name: "Alice", code: "ALICE1",
            todayStudySeconds: 0, roomID: "room-a", isDemo: false
        )
        let malformed = "[studiquo-attachment:%7Bbroken]"
        defaults.set(try! JSONEncoder().encode([friend]), forKey: "studiquoFriends")
        defaults.set(
            try! JSONEncoder().encode([
                FriendMessage(
                    id: UUID(), friendID: friend.id, text: malformed,
                    sentAt: Date(), isMine: false, isCanceled: false,
                    serverID: 1, roomID: "room-a"
                )
            ]),
            forKey: "studiquoFriendMessages"
        )

        let relaunched = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)

        XCTAssertEqual(relaunched.messages(for: friend).first?.text, malformed)
        XCTAssertTrue(FriendMessageAttachment.attachments(in: malformed).isEmpty)
    }

    // Regression coverage for "local attachment files are never cleaned
    // up": evicting an old message once history exceeds the cap used to
    // leave that message's attachment file on disk forever.
    func testEvictingAnOldMessageDeletesItsLocalAttachmentFile() async throws {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("fake image".utf8).write(to: tempFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        let attachment = FriendMessageAttachment(
            id: "photo-\(tempFile.path)-\(UUID().uuidString)", title: "写真", kind: "写真", icon: "photo",
            sourceKind: "photo", sourceID: tempFile.path, sourcePath: tempFile.path
        )
        let oldMessage = FriendMessage(
            id: UUID(), friendID: alice.id, text: attachment.messageLine,
            sentAt: Date(timeIntervalSince1970: 1), isMine: true, isCanceled: false
        )
        // Fill history right up to the cap with this message first, so the
        // very next send evicts exactly it.
        store.messages = [oldMessage] + (2...10_000).map { i in
            FriendMessage(
                id: UUID(), friendID: alice.id, text: "filler \(i)",
                sentAt: Date(timeIntervalSince1970: Double(i)), isMine: true, isCanceled: false
            )
        }

        store.send("one more", to: alice)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path), "the evicted message's local attachment file must be deleted")
    }

    // Regression coverage for "the message history cap is shared across all
    // friends, not per friend": a very active conversation used to be able
    // to evict another, untouched friend's history even though that
    // friend's own conversation was nowhere near the limit on its own.
    func testMessageHistoryCapIsEnforcedPerFriendNotSharedAcrossAllFriends() {
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let bob = FriendRecord(id: UUID(), name: "Bob", code: "BOB222", todayStudySeconds: 0, roomID: "room-b", isDemo: false)
        let store = FriendStore(client: MockFriendChatClient(), defaults: defaults, autoRefresh: false)
        store.friends = [alice, bob]

        // Bob's conversation is small and quiet.
        let bobsOldMessage = FriendMessage(
            id: UUID(), friendID: bob.id, text: "Bob's old message",
            sentAt: Date(timeIntervalSince1970: 1), isMine: true, isCanceled: false
        )
        // Alice's conversation is already right at the cap.
        let alicesFiller = (2...10_000).map { i in
            FriendMessage(
                id: UUID(), friendID: alice.id, text: "alice filler \(i)",
                sentAt: Date(timeIntervalSince1970: Double(i)), isMine: true, isCanceled: false
            )
        }
        store.messages = [bobsOldMessage] + alicesFiller

        // One more message to Alice pushes HER conversation over its own
        // cap — Bob's should be completely unaffected by it.
        store.send("one more to Alice", to: alice)

        XCTAssertEqual(store.messages(for: alice).count, 10_000, "Alice's own conversation stays capped at its own limit")
        XCTAssertEqual(
            store.messages(for: bob).map(\.text), ["Bob's old message"],
            "Bob's untouched, far-from-any-limit conversation must survive Alice's volume hitting the cap"
        )
    }

    func testBoundedFilenameCapsAnOverlongNameToTheDefaultLimit() {
        let long = String(repeating: "あ", count: 500)
        XCTAssertEqual(FriendMessageAttachment.boundedFilename(long).count, 20)
    }

    func testBoundedFilenameLeavesAShortNameUnchanged() {
        XCTAssertEqual(FriendMessageAttachment.boundedFilename("notes.pdf"), "notes.pdf")
    }

    // Regression coverage for "a long attachment filename corrupts the
    // message": a long, non-ASCII filename balloons under messageLine's
    // percent-encoding (each Japanese character can expand to 9 characters)
    // and, appearing three times in the payload (id, sourceID, sourcePath),
    // could previously push a single attachment's own encoded line past the
    // 2,000-character message limit on its own — at which point FriendChatView.send()'s
    // blind truncation would cut through the middle of the JSON payload,
    // leaving something that can't be parsed back into an attachment.
    func testMessageLineForAWorstCaseLongNonASCIIFilenameStaysWellUnderTheMessageLimit() {
        let longJapaneseName = String(repeating: "あ", count: 500) + ".pdf"
        let bounded = FriendMessageAttachment.boundedFilename(longJapaneseName)
        // A realistic-length iOS sandboxed app-container path, to make sure
        // the measurement isn't unrealistically optimistic.
        let simulatedPath = "/var/mobile/Containers/Data/Application/00000000-0000-0000-0000-000000000000/Documents/FriendChatAttachments/\(UUID().uuidString)-\(bounded)"
        let attachment = FriendMessageAttachment(
            id: "file-\(simulatedPath)-\(UUID().uuidString)",
            title: bounded,
            kind: "PDF",
            icon: "doc.richtext",
            sourceKind: "pdf",
            sourceID: simulatedPath,
            sourcePath: simulatedPath
        )

        XCTAssertLessThan(
            attachment.messageLine.count, 1_600,
            "a single attachment's encoded payload must leave headroom under the 2,000-character message limit"
        )
    }

    func testMessageLineStaysUnderTheLimitEvenWithARemoteRoomIDAttached() {
        let longJapaneseName = String(repeating: "あ", count: 500) + ".pdf"
        let bounded = FriendMessageAttachment.boundedFilename(longJapaneseName)
        let simulatedPath = "/var/mobile/Containers/Data/Application/00000000-0000-0000-0000-000000000000/Documents/FriendChatAttachments/\(UUID().uuidString)-\(bounded)"
        let attachment = FriendMessageAttachment(
            id: "file-\(simulatedPath)-\(UUID().uuidString)",
            title: bounded,
            kind: "PDF",
            icon: "doc.richtext",
            sourceKind: "pdf",
            sourceID: UUID().uuidString,
            sourcePath: simulatedPath,
            remoteRoomID: String(repeating: "a", count: 64)
        )

        XCTAssertLessThan(attachment.messageLine.count, 2_000)
    }

    // Regression coverage for "an attachment can't be opened by anyone but
    // the sender": the actual bytes must now be uploaded to the room, not
    // just referenced by a local file path.

    func testUploadAttachmentSendsTheBytesToTheClientAndReturnsItsID() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let data = Data("hello".utf8)

        let id = await store.uploadAttachment(data: data, contentType: "image/jpeg", roomID: "room-a")

        XCTAssertNotNil(id)
        let uploaded = await client.uploadedAttachmentsSnapshot()
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(uploaded.first?.roomID, "room-a")
        XCTAssertEqual(uploaded.first?.contentType, "image/jpeg")
        XCTAssertEqual(uploaded.first?.data, data)
        XCTAssertEqual(uploaded.first?.id, id)
    }

    // Regression coverage for "an attachment upload failure is completely
    // silent to the sender": the message still sends normally, but with
    // nothing telling the sender that the recipient won't be able to open
    // whatever was attached to it.
    func testUploadAttachmentReturnsNilAndSurfacesAnErrorWhenTheServerRejectsIt() async {
        let client = MockFriendChatClient()
        await client.setErrorToThrow(URLError(.notConnectedToInternet))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let id = await store.uploadAttachment(data: Data("hello".utf8), contentType: "image/jpeg", roomID: "room-a")

        XCTAssertNil(id)
        XCTAssertNotEqual(store.errorMessage, "", "the sender must be told the attachment won't be openable by the recipient")
    }

    func testAttachmentUploadCanBeRetriedAfterConnectivityReturns() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let data = Data("retry image".utf8)
        await client.setErrorToThrow(URLError(.notConnectedToInternet))

        let failedID = await store.uploadAttachment(data: data, contentType: "image/jpeg", roomID: "room-a")
        await client.setErrorToThrow(nil)
        let retriedID = await store.uploadAttachment(data: data, contentType: "image/jpeg", roomID: "room-a")

        XCTAssertNil(failedID)
        XCTAssertNotNil(retriedID, "通信復旧後は同じ添付を再試行できる必要があります。")
        let uploaded = await client.uploadedAttachmentsSnapshot()
        XCTAssertEqual(uploaded.map(\.data), [data], "失敗した試行を送信済みとして二重登録してはいけません。")
    }

    func testDownloadAttachmentReturnsTheBytesPreviouslyUploaded() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let data = Data("hello".utf8)
        let id = await store.uploadAttachment(data: data, contentType: "image/jpeg", roomID: "room-a")

        let downloaded = await store.downloadAttachment(roomID: "room-a", id: id ?? "")

        XCTAssertEqual(downloaded, data)
    }

    func testDownloadAttachmentReturnsNilWhenTheServerRejectsIt() async {
        let client = MockFriendChatClient()
        await client.setErrorToThrow(URLError(.notConnectedToInternet))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let downloaded = await store.downloadAttachment(roomID: "room-a", id: "missing")

        XCTAssertNil(downloaded)
    }

    // Regression coverage for a real gap: opening a
    // studiquo://friend/add?code=... link used to send the friend request
    // immediately, with no confirmation — a link crafted by someone else
    // (a message, a QR code) could send a request the instant it was
    // tapped. add(url:) now only stages the code; the request goes out
    // only through confirmPendingDeepLinkRequest().

    func testAddURLStagesTheCodeWithoutSendingARequestImmediately() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(url: URL(string: "studiquo://friend/add?code=ALICE1")!)

        XCTAssertEqual(store.pendingDeepLinkCode, "ALICE1")
        // Give any accidental fire-and-forget Task a chance to run before
        // asserting nothing happened.
        try? await Task.sleep(for: .milliseconds(50))
        let addedCodes = await client.addedCodesSnapshot()
        XCTAssertEqual(addedCodes, [], "opening the link must not send a request by itself")
    }

    func testConfirmingThePendingDeepLinkRequestActuallySendsIt() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.add(url: URL(string: "studiquo://friend/add?code=ALICE1")!)

        store.confirmPendingDeepLinkRequest()
        await waitUntil { await client.addedCodesSnapshot() == ["ALICE1"] }

        XCTAssertNil(store.pendingDeepLinkCode, "the pending code is cleared once the student acts on it")
    }

    func testCancelingThePendingDeepLinkRequestNeverSendsIt() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.add(url: URL(string: "studiquo://friend/add?code=ALICE1")!)

        store.cancelPendingDeepLinkRequest()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(store.pendingDeepLinkCode)
        let addedCodes = await client.addedCodesSnapshot()
        XCTAssertEqual(addedCodes, [])
    }

    /// A malformed or unrelated URL (wrong scheme/host/path) must be
    /// ignored outright — it shouldn't even stage a confirmation for
    /// something that was never a real friend-add link.
    func testAddURLIgnoresAnUnrelatedURLEntirely() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(url: URL(string: "https://example.com/friend/add?code=ALICE1")!)

        XCTAssertNil(store.pendingDeepLinkCode)
    }

    func testInvitationURLEncodesTheLinkTokenNotTheFriendCode() async {
        let client = MockFriendChatClient(identity: .init(code: "ME0000", name: "Me", linkToken: "LINKTOKEN1"))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refresh()

        XCTAssertEqual(store.invitationURL.absoluteString, "\(WorkerAIProvider.defaultEndpoint)/invite?token=LINKTOKEN1")
    }

    // Regression coverage for "a friend-invite link shared through LINE or
    // Snapchat does nothing when tapped": those apps' in-app browsers
    // generally won't hand a studiquo:// custom-scheme link off to iOS at
    // all, only a real https:// Universal Link — see invitationURL's own
    // doc comment and invite.js server-side.
    func testAddURLAcceptsTheHTTPSUniversalLinkFormat() async {
        let client = MockFriendChatClient()
        await client.setLinkTokenOwner(.init(code: "ALICE1", name: "Alice", roomID: "room-a"), token: "LINKTOKEN1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(url: URL(string: "\(WorkerAIProvider.defaultEndpoint)/invite?token=LINKTOKEN1")!)

        XCTAssertEqual(store.pendingLinkToken, "LINKTOKEN1")
    }

    func testAddURLIgnoresAnHTTPSLinkOnAnUnrelatedHostEvenWithTheRightPath() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(url: URL(string: "https://not-studiquo.example.com/invite?token=LINKTOKEN1")!)

        XCTAssertNil(store.pendingLinkToken)
    }

    func testAddURLWithTheHTTPSFormatButNoTokenQueryItemDoesNothing() async {
        let client = MockFriendChatClient()
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(url: URL(string: "\(WorkerAIProvider.defaultEndpoint)/invite")!)

        XCTAssertNil(store.pendingLinkToken)
    }

    /// The older `studiquo://friend/add?token=…` form must keep working —
    /// someone may already have a link in this shape sitting in a Mail or
    /// Messages thread from before `invitationURL` switched formats.
    func testAddURLStillAcceptsTheOlderCustomSchemeTokenFormat() async {
        let client = MockFriendChatClient()
        await client.setLinkTokenOwner(.init(code: "ALICE1", name: "Alice", roomID: "room-a"), token: "LINKTOKEN1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(url: URL(string: "studiquo://friend/add?token=LINKTOKEN1")!)

        XCTAssertEqual(store.pendingLinkToken, "LINKTOKEN1")
    }

    func testAddURLWithATokenStagesItWithoutRedeemingItImmediately() async {
        let client = MockFriendChatClient()
        await client.setLinkTokenOwner(.init(code: "ALICE1", name: "Alice", roomID: "room-a"), token: "LINKTOKEN1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(url: URL(string: "studiquo://friend/add?token=LINKTOKEN1")!)

        XCTAssertEqual(store.pendingLinkToken, "LINKTOKEN1")
        try? await Task.sleep(for: .milliseconds(50))
        let redeemed = await client.linkAddedTokensSnapshot()
        XCTAssertEqual(redeemed, [], "opening the link must not redeem it by itself")
    }

    func testConfirmingAPendingLinkAddCreatesAnImmediateFriendshipWithNoApprovalStep() async {
        let client = MockFriendChatClient()
        await client.setLinkTokenOwner(.init(code: "ALICE1", name: "Alice", roomID: "room-a"), token: "LINKTOKEN1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.add(url: URL(string: "studiquo://friend/add?token=LINKTOKEN1")!)

        store.confirmPendingLinkAdd()
        await waitUntil { store.friends.contains { $0.code == "ALICE1" } }

        XCTAssertNil(store.pendingLinkToken)
        XCTAssertTrue(store.outgoingRequests.isEmpty, "a link add must never go through the pending-request system")
    }

    // Regression coverage for "the friend appears then immediately
    // disappears": tapping an invite link navigates straight to the friends
    // screen, whose own poll (FriendsHomeView's `.task`) starts right away
    // and can still be in flight — reflecting pre-add server state — when
    // confirmPendingLinkAdd() finishes. Without `friendsGeneration` guarding
    // against it, that stale response arrives afterward, sees the just-added
    // friend missing from its own snapshot, and archives them again.
    func testConfirmingAPendingLinkAddSurvivesAStaleFriendsFetchThatWasAlreadyInFlight() async {
        let client = MockFriendChatClient()
        await client.setLinkTokenOwner(.init(code: "ALICE1", name: "Alice", roomID: "room-a"), token: "LINKTOKEN1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.add(url: URL(string: "studiquo://friend/add?token=LINKTOKEN1")!)

        // Simulates FriendsHomeView's `.task` poll, already fetching the
        // (friend-less) pre-add friends list when the link was opened.
        await client.holdFriends()
        let staleFetch = Task { await store.refreshFriends() }
        try? await Task.sleep(for: .milliseconds(20))

        store.confirmPendingLinkAdd()
        await waitUntil { store.friends.contains { $0.code == "ALICE1" } }

        // The stale fetch (started before the add) now resolves, still
        // showing no friends — this must not undo the add that just happened.
        await client.releaseFriends()
        await staleFetch.value

        XCTAssertTrue(store.friends.contains { $0.code == "ALICE1" }, "a friend that was just added must not be reverted by a slower, now-stale fetch")
        XCTAssertTrue(store.archivedFriends.isEmpty, "the friend must not have been archived by the stale response either")
    }

    /// Same race as the test above, but through `refresh()` (the full
    /// register()+friends() call made once at launch) instead of
    /// `refreshFriends()` — a separate code path with its own
    /// `friendsGeneration` guard that needs its own coverage.
    func testRefreshSurvivesAStaleFriendsFetchThatWasAlreadyInFlight() async {
        let client = MockFriendChatClient()
        await client.setLinkTokenOwner(.init(code: "ALICE1", name: "Alice", roomID: "room-a"), token: "LINKTOKEN1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.add(url: URL(string: "studiquo://friend/add?token=LINKTOKEN1")!)

        await client.holdFriends()
        let staleRefresh = Task { await store.refresh() }
        try? await Task.sleep(for: .milliseconds(20))

        store.confirmPendingLinkAdd()
        await waitUntil { store.friends.contains { $0.code == "ALICE1" } }

        await client.releaseFriends()
        await staleRefresh.value

        XCTAssertTrue(store.friends.contains { $0.code == "ALICE1" }, "a friend just added must not be reverted by refresh()'s own stale fetch")
        XCTAssertTrue(store.archivedFriends.isEmpty)
    }

    func testCancelingAPendingLinkAddNeverRedeemsIt() async {
        let client = MockFriendChatClient()
        await client.setLinkTokenOwner(.init(code: "ALICE1", name: "Alice", roomID: "room-a"), token: "LINKTOKEN1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.add(url: URL(string: "studiquo://friend/add?token=LINKTOKEN1")!)

        store.cancelPendingLinkAdd()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(store.pendingLinkToken)
        let redeemed = await client.linkAddedTokensSnapshot()
        XCTAssertEqual(redeemed, [])
        XCTAssertTrue(store.friends.isEmpty)
    }

    func testConfirmingAPendingLinkAddForOnesOwnTokenIsRejectedLocallyWithoutCallingTheServer() async {
        let client = MockFriendChatClient(identity: .init(code: "ME0000", name: "Me", linkToken: "MYTOKEN1"))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refresh()
        store.add(url: URL(string: "studiquo://friend/add?token=MYTOKEN1")!)

        store.confirmPendingLinkAdd()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(store.errorMessage, "自分自身をフレンドに追加することはできません。")
        let redeemed = await client.linkAddedTokensSnapshot()
        XCTAssertEqual(redeemed, [], "a self-add must be caught before ever reaching the server")
    }

    // Same server rejection as the manual-code path above, reached instead
    // through redeeming a QR/invite link — must show the same dedicated
    // wording, not the link-specific "invalid link" fallback.
    func testConfirmingAPendingLinkAddShowsADedicatedMessageWhenTheOtherPersonIsBlocked() async {
        let client = MockFriendChatClient()
        await client.setLinkTokenOwner(.init(code: "ALICE1", name: "Alice", roomID: "room-a"), token: "LINKTOKEN1")
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.add(url: URL(string: "studiquo://friend/add?token=LINKTOKEN1")!)
        await client.setErrorToThrow(FriendChatService.ServerError(status: 403, message: "This friend cannot be added right now."))

        store.confirmPendingLinkAdd()
        await waitUntil { !store.errorMessage.isEmpty }

        XCTAssertEqual(store.errorMessage, "この相手はブロックされているため追加できません。「ブロック一覧」から解除してから、もう一度お試しください。")
        XCTAssertTrue(store.friends.isEmpty)
    }

    func testAddSurfacesADedicatedMessageWhenRateLimited() async {
        let client = MockFriendChatClient()
        await client.setRateLimited(true)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(code: "ALICE1")
        await waitUntil { store.errorMessage.contains("上限") }

        XCTAssertEqual(store.errorMessage, "フレンド申請の送信回数が上限に達しました。しばらくしてからもう一度お試しください。")
        XCTAssertTrue(store.friends.isEmpty)
    }

    func testAddSurfacesTheServersSpecificReasonInsteadOfAGenericMessage() async {
        let client = MockFriendChatClient()
        await client.setErrorToThrow(FriendChatService.ServerError(status: 400, message: "You cannot add yourself as a friend."))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(code: "ALICE1")
        await waitUntil { !store.errorMessage.isEmpty }

        XCTAssertEqual(store.errorMessage, "自分自身をフレンドに追加することはできません。")
    }

    func testAddFallsBackToTheGenericMessageForAnUnrecognizedServerReason() async {
        let client = MockFriendChatClient()
        await client.setErrorToThrow(FriendChatService.ServerError(status: 500, message: "Something new the client has never heard of."))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        store.add(code: "ALICE1")
        await waitUntil { !store.errorMessage.isEmpty }

        XCTAssertEqual(store.errorMessage, "フレンドコードが見つかりません。")
    }

    // Regression coverage for "the add-friend sheet dismisses before the
    // network call even returns": callers that need to know the outcome
    // (the sheet, deciding whether to close) use addAndWait instead of the
    // fire-and-forget add().

    func testAddAndWaitReturnsTrueOnSuccess() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.addAndWait(code: "ALICE1")

        XCTAssertTrue(succeeded)
    }

    // Regression coverage for "a successful add needlessly re-registers the
    // profile name": only the outgoing/friends lists actually need
    // refreshing after sending a request, not the full refresh() (which
    // also calls register()).
    func testAddAndWaitDoesNotReRegisterTheProfileNameOnSuccess() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        let registerCallsBefore = await client.reportedStudyStatsSnapshot().count

        let succeeded = await store.addAndWait(code: "ALICE1")

        XCTAssertTrue(succeeded)
        let registerCallsAfter = await client.reportedStudyStatsSnapshot().count
        XCTAssertEqual(registerCallsAfter, registerCallsBefore, "a successful add must not trigger another register() call")
    }

    func testAddAndWaitReturnsFalseWhenTheServerRejectsIt() async {
        let client = MockFriendChatClient()
        await client.setErrorToThrow(FriendChatService.ServerError(status: 400, message: "You cannot add yourself as a friend."))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.addAndWait(code: "ALICE1")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.errorMessage, "自分自身をフレンドに追加することはできません。")
    }

    // Regression coverage: adding a code by hand (the QR-scan fallback path
    // too, via submit(code:)) must tell the student *why* it failed when the
    // other person has this room blocked, not the generic "code not found"
    // fallback — same server message, same three call sites, as the block
    // dialog itself.
    func testAddAndWaitShowsADedicatedMessageWhenTheOtherPersonIsBlocked() async {
        let client = MockFriendChatClient()
        await client.setErrorToThrow(FriendChatService.ServerError(status: 403, message: "This friend cannot be added right now."))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        let succeeded = await store.addAndWait(code: "ALICE1")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.errorMessage, "この相手はブロックされているため追加できません。「ブロック一覧」から解除してから、もう一度お試しください。")
    }

    func testAddAndWaitReturnsFalseForAnAlreadyAddedFriendWithoutCallingTheServer() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)]

        let succeeded = await store.addAndWait(code: "ALICE1")

        XCTAssertFalse(succeeded)
    }

    func testAcceptSurfacesTheServersSpecificReasonWhenTheFriendListIsFull() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()
        await client.setErrorToThrow(FriendChatService.ServerError(status: 400, message: "Friend list is full."))

        store.accept(store.incomingRequests[0])
        await waitUntil { !store.errorMessage.isEmpty }

        XCTAssertEqual(store.errorMessage, "フレンドの上限に達しているため追加できません。")
        XCTAssertTrue(store.friends.isEmpty)
    }

    // Third and last of the three call sites that can return this server
    // message (see chat.js) — accepting an incoming request from someone
    // this account has blocked must show the same dedicated wording too.
    func testAcceptShowsADedicatedMessageWhenTheOtherPersonIsBlocked() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()
        await client.setErrorToThrow(FriendChatService.ServerError(status: 403, message: "This friend cannot be added right now."))

        store.accept(store.incomingRequests[0])
        await waitUntil { !store.errorMessage.isEmpty }

        XCTAssertEqual(store.errorMessage, "この相手はブロックされているため追加できません。「ブロック一覧」から解除してから、もう一度お試しください。")
        XCTAssertTrue(store.friends.isEmpty)
    }

    func testRejectSurfacesTheServersSpecificReason() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "MALLRY", name: "Mallory", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()
        await client.setErrorToThrow(FriendChatService.ServerError(status: 404, message: "Request not found."))

        store.reject(store.incomingRequests[0])
        await waitUntil { !store.errorMessage.isEmpty }

        XCTAssertEqual(store.errorMessage, "フレンドコードが見つかりません。")
    }

    func testRefreshIncomingRequestsPopulatesPendingRequestsFromServer() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([
            .init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000),
        ])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refreshIncomingRequests()

        XCTAssertEqual(store.incomingRequests.map(\.code), ["ALICE1"])
        XCTAssertEqual(store.incomingRequests.first?.name, "Alice")
    }

    func testRefreshIncomingRequestsCountsAFreshRequestAsUnseen() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refreshIncomingRequests()

        XCTAssertEqual(store.unseenIncomingRequestCount, 1)
    }

    func testMarkIncomingRequestsSeenClearsTheUnseenCountWithoutTouchingTheRequestsThemselves() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()

        store.markIncomingRequestsSeen()

        XCTAssertEqual(store.unseenIncomingRequestCount, 0)
        XCTAssertEqual(store.incomingRequests.map(\.code), ["ALICE1"], "seeing a request must not act on it")
    }

    func testASecondRefreshAfterMarkingSeenDoesNotReCountTheSameRequest() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()
        store.markIncomingRequestsSeen()

        await store.refreshIncomingRequests()

        XCTAssertEqual(store.unseenIncomingRequestCount, 0, "already-seen request shouldn't rearm the badge on a later poll")
    }

    func testANewRequestArrivingAlongsideAnAlreadySeenOneIsCountedOnItsOwn() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()
        store.markIncomingRequestsSeen()
        await client.setPendingRequests([
            .init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000),
            .init(code: "BOB222", name: "Bob", requestedAt: 1_700_000_001_000),
        ])

        await store.refreshIncomingRequests()

        XCTAssertEqual(store.unseenIncomingRequestCount, 1)
    }

    func testSeenStatusPersistsAcrossARelaunchSoTheBadgeDoesNotReappearForAnAlreadySeenRequest() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let firstLaunch = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await firstLaunch.refreshIncomingRequests()
        firstLaunch.markIncomingRequestsSeen()

        let secondLaunch = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await secondLaunch.refreshIncomingRequests()

        XCTAssertEqual(secondLaunch.unseenIncomingRequestCount, 0)
    }

    func testRefreshOutgoingRequestsPopulatesSentButUnansweredRequestsFromServer() async {
        let client = MockFriendChatClient()
        await client.setOutgoingRequests([
            .init(code: "BOB222", name: "Bob", requestedAt: 1_700_000_000_000),
        ])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        await store.refreshOutgoingRequests()

        XCTAssertEqual(store.outgoingRequests.map(\.code), ["BOB222"])
        XCTAssertEqual(store.outgoingRequests.first?.name, "Bob")
    }

    func testAcceptMovesAPendingRequestIntoFriendsAndClearsIt() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()

        store.accept(store.incomingRequests[0])
        await waitUntil { await client.acceptedCodesSnapshot() == ["ALICE1"] }

        XCTAssertEqual(store.friends.map(\.code), ["ALICE1"])
        XCTAssertEqual(store.friends.first?.roomID, "room-a")
        XCTAssertTrue(store.incomingRequests.isEmpty)
    }

    func testAcceptDoesNotCreateADuplicateFriendIfOneAlreadyExists() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()
        // Simulates a fast double-tap on "承認", or a refresh() landing in
        // between the request and its response — either way, Alice is
        // already a friend by the time this accept's response arrives.
        store.friends = [FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)]

        store.accept(store.incomingRequests[0])
        await waitUntil { await client.acceptedCodesSnapshot() == ["ALICE1"] }

        XCTAssertEqual(store.friends.filter { $0.code == "ALICE1" }.count, 1)
        XCTAssertTrue(store.incomingRequests.isEmpty)
    }

    // Regression coverage for "a fast double-tap on 承認/拒否 fires the
    // operation twice": the guard must block a second call for a code that
    // already has one in flight, before the first network call even
    // completes — the view uses `pendingRequestActions` to disable the
    // buttons for the same reason.

    func testAcceptIgnoresASecondCallForTheSameCodeWhileTheFirstIsStillInFlight() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()

        store.accept(store.incomingRequests[0])
        store.accept(store.incomingRequests[0]) // simulates a rapid double-tap
        await waitUntil { store.friends.contains(where: { $0.code == "ALICE1" }) }

        let accepted = await client.acceptedCodesSnapshot()
        XCTAssertEqual(accepted, ["ALICE1"], "a second tap while the first is still in flight must not fire a second network call")
        XCTAssertEqual(store.friends.filter { $0.code == "ALICE1" }.count, 1)
    }

    func testRejectIgnoresASecondCallForTheSameCodeWhileTheFirstIsStillInFlight() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "MALLRY", name: "Mallory", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()

        store.reject(store.incomingRequests[0])
        store.reject(store.incomingRequests[0])
        await waitUntil { store.incomingRequests.isEmpty }

        let rejected = await client.rejectedCodesSnapshot()
        XCTAssertEqual(rejected, ["MALLRY"])
    }

    func testPendingRequestActionsTracksAnAcceptInFlightAndClearsOnceItFinishes() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()

        store.accept(store.incomingRequests[0])
        XCTAssertTrue(store.pendingRequestActions.contains("ALICE1"), "the code must be marked in-flight synchronously, before the network call resolves")

        await waitUntil { !store.pendingRequestActions.contains("ALICE1") }
        XCTAssertTrue(store.friends.contains(where: { $0.code == "ALICE1" }))
    }

    func testRejectIsIgnoredWhileAnAcceptForTheSameCodeIsStillInFlight() async {
        let client = MockFriendChatClient(friends: [.init(code: "ALICE1", name: "Alice", roomID: "room-a")])
        await client.setPendingRequests([.init(code: "ALICE1", name: "Alice", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()

        store.accept(store.incomingRequests[0])
        store.reject(store.incomingRequests[0]) // must be ignored — accept already owns this code
        await waitUntil { store.friends.contains(where: { $0.code == "ALICE1" }) }

        let rejected = await client.rejectedCodesSnapshot()
        XCTAssertTrue(rejected.isEmpty, "reject must not fire while accept is already in flight for the same code")
    }

    func testRejectClearsThePendingRequestWithoutCreatingAFriendship() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "MALLRY", name: "Mallory", requestedAt: 1_700_000_000_000)])
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()

        store.reject(store.incomingRequests[0])
        await waitUntil { await client.rejectedCodesSnapshot() == ["MALLRY"] }

        XCTAssertTrue(store.friends.isEmpty)
        XCTAssertTrue(store.incomingRequests.isEmpty)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
    }
}

@MainActor
private final class FriendChatMaintenanceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            isWaiting = true
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}

private actor MockFriendChatClient: FriendChatClient {
    struct SentMessage: Equatable {
        let text: String
        let roomID: String
    }

    var identity: FriendChatService.Identity
    var remoteFriends: [FriendChatService.Friend]
    var roomMessages: [String: [FriendChatService.Message]]
    var inboxStates: [FriendChatService.InboxState] = []
    var blocked: [FriendChatService.BlockedContact] = []
    var readCalls: [(roomID: String, throughID: Int)] = []
    var sent: [SentMessage] = []
    var pendingRequests: [FriendChatService.IncomingRequest] = []
    var outgoingPendingRequests: [FriendChatService.OutgoingRequest] = []
    var acceptedCodes: [String] = []
    var rejectedCodes: [String] = []
    var addedCodes: [String] = []
    var isRateLimited = false
    var errorToThrow: Error?
    var messagesAfterRequests: [Int] = []
    var reportedStudyStats: [(seconds: Int?, date: String?)] = []
    var uploadedAttachments: [(roomID: String, contentType: String, data: Data, id: String)] = []

    init(
        identity: FriendChatService.Identity = .init(code: "ME0000", name: "Me"),
        friends: [FriendChatService.Friend] = [],
        roomMessages: [String: [FriendChatService.Message]] = [:]
    ) {
        self.identity = identity
        self.remoteFriends = friends
        self.roomMessages = roomMessages
    }

    func register(name: String, todayStudySeconds: Int?, studyDate: String?) async throws -> FriendChatService.Identity {
        reportedStudyStats.append((todayStudySeconds, studyDate))
        return identity
    }

    func reportedStudyStatsSnapshot() -> [(seconds: Int?, date: String?)] {
        reportedStudyStats
    }

    private var friendsGateOpen = true
    private var friendsWaiters: [CheckedContinuation<Void, Never>] = []

    /// Makes the next `friends()` call(s) suspend until `releaseFriends()`
    /// is called — lets a test hold a friends-list fetch "in flight" while
    /// it performs some other, more-recent action, to reproduce a stale
    /// response arriving late.
    func holdFriends() {
        friendsGateOpen = false
    }

    func releaseFriends() {
        friendsGateOpen = true
        let waiters = friendsWaiters
        friendsWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func friends() async throws -> [FriendChatService.Friend] {
        if let errorToThrow { throw errorToThrow }
        if !friendsGateOpen {
            await withCheckedContinuation { friendsWaiters.append($0) }
        }
        return remoteFriends
    }

    func inbox() async throws -> [FriendChatService.InboxState] { inboxStates }

    func setInbox(_ value: [FriendChatService.InboxState]) { inboxStates = value }

    func blockedContacts() async throws -> [FriendChatService.BlockedContact] { blocked }

    func setBlockedContacts(_ value: [FriendChatService.BlockedContact]) { blocked = value }

    func removeFriend(code: String) async throws -> FriendChatService.RemoveFriendResult {
        remoteFriends.removeAll { $0.code == code }
        return .init(status: "removed")
    }

    func markRead(roomID: String, throughID: Int) async throws -> FriendChatService.ReadResult {
        readCalls.append((roomID, throughID))
        return .init(status: "read", throughID: throughID)
    }

    func readCallsSnapshot() -> [(roomID: String, throughID: Int)] { readCalls }

    func setFriends(_ value: [FriendChatService.Friend]) {
        remoteFriends = value
    }

    var uploadedAvatars: [(contentType: String, data: Data)] = []
    var avatarsByCode: [String: Data] = [:]

    func uploadAvatar(contentType: String, data: Data) async throws -> FriendChatService.AvatarUploadResult {
        if let errorToThrow { throw errorToThrow }
        uploadedAvatars.append((contentType, data))
        return .init(avatarUpdatedAt: Date().timeIntervalSince1970 * 1_000)
    }

    func uploadedAvatarsSnapshot() -> [(contentType: String, data: Data)] {
        uploadedAvatars
    }

    func setAvatar(_ data: Data, forCode code: String) {
        avatarsByCode[code] = data
    }

    func downloadAvatar(code: String) async throws -> Data {
        if let errorToThrow { throw errorToThrow }
        guard let data = avatarsByCode[code] else { throw URLError(.fileDoesNotExist) }
        return data
    }

    func add(code: String) async throws -> FriendChatService.AddFriendResult {
        addedCodes.append(code)
        if isRateLimited { throw FriendChatService.RateLimitedError() }
        if let errorToThrow { throw errorToThrow }
        guard remoteFriends.contains(where: { $0.code == code }) else {
            throw URLError(.badServerResponse)
        }
        return .init(status: "pending")
    }

    func addedCodesSnapshot() -> [String] {
        addedCodes
    }

    var linkAddedTokens: [String] = []
    var linkTokenOwner: FriendChatService.Friend?
    var linkToken = "LINK0000"

    func addViaLink(token: String) async throws -> FriendChatService.LinkAddResult {
        linkAddedTokens.append(token)
        if isRateLimited { throw FriendChatService.RateLimitedError() }
        if let errorToThrow { throw errorToThrow }
        guard let owner = linkTokenOwner, token == linkToken else {
            throw FriendChatService.ServerError(status: 404, message: "This invite link is no longer valid.")
        }
        return .init(status: "added", code: owner.code, name: owner.name, roomID: owner.roomID)
    }

    /// Registers the token an `addViaLink(token:)` call must match, and the
    /// friend it resolves to on success — mirrors how a real invite link's
    /// token is tied to one specific account server-side.
    func setLinkTokenOwner(_ friend: FriendChatService.Friend, token: String) {
        linkTokenOwner = friend
        linkToken = token
    }

    func linkAddedTokensSnapshot() -> [String] {
        linkAddedTokens
    }

    func setRateLimited(_ value: Bool) {
        isRateLimited = value
    }

    func setErrorToThrow(_ error: Error?) {
        errorToThrow = error
    }

    func incomingRequests() async throws -> [FriendChatService.IncomingRequest] {
        pendingRequests
    }

    func outgoingRequests() async throws -> [FriendChatService.OutgoingRequest] {
        outgoingPendingRequests
    }

    func setOutgoingRequests(_ requests: [FriendChatService.OutgoingRequest]) {
        outgoingPendingRequests = requests
    }

    var remoteGroups: [FriendChatService.Group] = []
    var remoteGroupInvites: [FriendChatService.GroupInvite] = []
    private var groupsGateOpen = true
    private var groupWaiters: [CheckedContinuation<Void, Never>] = []

    func holdGroups() {
        groupsGateOpen = false
    }

    func releaseGroups() {
        groupsGateOpen = true
        let waiters = groupWaiters
        groupWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func isGroupFetchWaiting() -> Bool {
        !groupWaiters.isEmpty
    }

    func groups() async throws -> [FriendChatService.Group] {
        if let errorToThrow { throw errorToThrow }
        // Capture before suspension so this behaves like a real HTTP response
        // that was produced before a concurrent create completed, but arrived
        // at the client afterward.
        let response = remoteGroups
        if !groupsGateOpen {
            await withCheckedContinuation { groupWaiters.append($0) }
        }
        return response
    }

    func groupInvites() async throws -> [FriendChatService.GroupInvite] {
        if let errorToThrow { throw errorToThrow }
        return remoteGroupInvites
    }

    func setGroups(_ value: [FriendChatService.Group]) {
        remoteGroups = value
    }

    func setGroupInvites(_ value: [FriendChatService.GroupInvite]) {
        remoteGroupInvites = value
    }

    var createGroupCalls: [(name: String, memberCodes: [String])] = []
    /// The roomID `createGroup` hands back — fixed rather than random so a
    /// test can assert on it (e.g. to check for duplicate-add protection)
    /// without having to capture whatever value was generated.
    var createdGroupRoomID = String(repeating: "c", count: 64)

    func createGroup(name: String, memberCodes: [String]) async throws -> FriendChatService.Group {
        createGroupCalls.append((name, memberCodes))
        if let errorToThrow { throw errorToThrow }
        return FriendChatService.Group(
            roomID: createdGroupRoomID, name: name,
            members: [.init(code: identity.code, name: identity.name)]
        )
    }

    func createGroupCallsSnapshot() -> [(name: String, memberCodes: [String])] { createGroupCalls }

    var inviteToGroupCalls: [(roomID: String, code: String)] = []
    var inviteToGroupResultStatus = "pending"

    func setInviteToGroupResultStatus(_ status: String) {
        inviteToGroupResultStatus = status
    }

    func inviteToGroup(roomID: String, code: String) async throws -> FriendChatService.GroupActionResult {
        inviteToGroupCalls.append((roomID, code))
        if let errorToThrow { throw errorToThrow }
        return .init(status: inviteToGroupResultStatus)
    }

    func inviteToGroupCallsSnapshot() -> [(roomID: String, code: String)] { inviteToGroupCalls }

    var acceptedGroupInviteRoomIDs: [String] = []
    var acceptGroupInviteResult: FriendChatService.Group?

    func acceptGroupInvite(roomID: String) async throws -> FriendChatService.Group {
        acceptedGroupInviteRoomIDs.append(roomID)
        if let errorToThrow { throw errorToThrow }
        if let acceptGroupInviteResult { return acceptGroupInviteResult }
        return FriendChatService.Group(roomID: roomID, name: "Group", members: [.init(code: identity.code, name: identity.name)])
    }

    func acceptedGroupInviteRoomIDsSnapshot() -> [String] { acceptedGroupInviteRoomIDs }

    func setAcceptGroupInviteResult(_ value: FriendChatService.Group) {
        acceptGroupInviteResult = value
    }

    var rejectedGroupInviteRoomIDs: [String] = []

    func rejectGroupInvite(roomID: String) async throws -> FriendChatService.GroupActionResult {
        rejectedGroupInviteRoomIDs.append(roomID)
        if let errorToThrow { throw errorToThrow }
        return .init(status: "rejected")
    }

    func rejectedGroupInviteRoomIDsSnapshot() -> [String] { rejectedGroupInviteRoomIDs }

    var renameGroupCalls: [(roomID: String, name: String)] = []

    func renameGroup(roomID: String, name: String) async throws -> FriendChatService.RenameGroupResult {
        renameGroupCalls.append((roomID, name))
        if let errorToThrow { throw errorToThrow }
        return .init(status: "ok", name: name)
    }

    func renameGroupCallsSnapshot() -> [(roomID: String, name: String)] { renameGroupCalls }

    var removeGroupMemberCalls: [(roomID: String, code: String)] = []
    var groupAvatarUploads: [(roomID: String, contentType: String, data: Data)] = []
    var groupAvatarsByRoomID: [String: Data] = [:]

    func removeGroupMember(roomID: String, code: String) async throws -> FriendChatService.GroupActionResult {
        removeGroupMemberCalls.append((roomID, code))
        if let errorToThrow { throw errorToThrow }
        return .init(status: "removed")
    }

    func removeGroupMemberCallsSnapshot() -> [(roomID: String, code: String)] { removeGroupMemberCalls }

    func uploadGroupAvatar(roomID: String, contentType: String, data: Data) async throws -> FriendChatService.GroupAvatarUploadResult {
        if let errorToThrow { throw errorToThrow }
        groupAvatarUploads.append((roomID, contentType, data))
        groupAvatarsByRoomID[roomID] = data
        return .init(avatarUpdatedAt: 456)
    }

    func downloadGroupAvatar(roomID: String) async throws -> Data {
        if let errorToThrow { throw errorToThrow }
        guard let data = groupAvatarsByRoomID[roomID] else { throw URLError(.fileDoesNotExist) }
        return data
    }

    func setGroupAvatar(_ data: Data, roomID: String) {
        groupAvatarsByRoomID[roomID] = data
    }

    func groupAvatarUploadsSnapshot() -> [(roomID: String, contentType: String, data: Data)] {
        groupAvatarUploads
    }

    func accept(code: String) async throws -> FriendChatService.Friend {
        if let errorToThrow { throw errorToThrow }
        guard let friend = remoteFriends.first(where: { $0.code == code }) else {
            throw URLError(.badServerResponse)
        }
        acceptedCodes.append(code)
        pendingRequests.removeAll { $0.code == code }
        return friend
    }

    func reject(code: String) async throws -> FriendChatService.RejectResult {
        if let errorToThrow { throw errorToThrow }
        rejectedCodes.append(code)
        pendingRequests.removeAll { $0.code == code }
        return .init(status: "rejected")
    }

    func setPendingRequests(_ requests: [FriendChatService.IncomingRequest]) {
        pendingRequests = requests
    }

    func acceptedCodesSnapshot() -> [String] {
        acceptedCodes
    }

    func rejectedCodesSnapshot() -> [String] {
        rejectedCodes
    }

    func messages(roomID: String, after: Int) async throws -> [FriendChatService.Message] {
        messagesAfterRequests.append(after)
        if let errorToThrow { throw errorToThrow }
        return roomMessages[roomID, default: []].filter { $0.id > after }
    }

    func messagesAfterRequestsSnapshot() -> [Int] {
        messagesAfterRequests
    }

    func send(_ text: String, roomID: String, clientMessageID: String) async throws -> FriendChatService.Message {
        sent.append(.init(text: text, roomID: roomID))
        if let errorToThrow { throw errorToThrow }
        let nextID = (roomMessages[roomID, default: []].map(\.id).max() ?? 0) + 1
        let message = FriendChatService.Message(
            id: nextID, text: text, sentAt: Date().timeIntervalSince1970 * 1_000, isMine: true,
            clientMessageID: clientMessageID
        )
        roomMessages[roomID, default: []].append(message)
        return message
    }

    var canceledMessages: [(roomID: String, messageID: Int)] = []

    func cancelMessage(roomID: String, messageID: Int) async throws -> FriendChatService.CancelMessageResult {
        canceledMessages.append((roomID: roomID, messageID: messageID))
        if let errorToThrow { throw errorToThrow }
        if let index = roomMessages[roomID, default: []].firstIndex(where: { $0.id == messageID }) {
            let original = roomMessages[roomID]![index]
            roomMessages[roomID]![index] = FriendChatService.Message(
                id: original.id, text: "", sentAt: original.sentAt, isMine: original.isMine,
                clientMessageID: original.clientMessageID, isCanceled: true
            )
        }
        return .init(status: "canceled")
    }

    func canceledMessagesSnapshot() -> [(roomID: String, messageID: Int)] {
        canceledMessages
    }

    var editedMessages: [(roomID: String, messageID: Int, text: String)] = []

    func editMessage(roomID: String, messageID: Int, text: String) async throws -> FriendChatService.EditMessageResult {
        if let errorToThrow { throw errorToThrow }
        guard let index = roomMessages[roomID, default: []].firstIndex(where: { $0.id == messageID }) else {
            return .init(status: "not_found")
        }
        let original = roomMessages[roomID]![index]
        if original.isCanceled == true { return .init(status: "canceled") }
        editedMessages.append((roomID: roomID, messageID: messageID, text: text))
        roomMessages[roomID]![index] = FriendChatService.Message(
            id: original.id, text: text, sentAt: original.sentAt, isMine: original.isMine,
            clientMessageID: original.clientMessageID, isCanceled: original.isCanceled
        )
        return .init(status: "edited")
    }

    func editedMessagesSnapshot() -> [(roomID: String, messageID: Int, text: String)] {
        editedMessages
    }

    func messages(roomID: String, ids: [Int]) async throws -> [FriendChatService.Message] {
        if let errorToThrow { throw errorToThrow }
        let idSet = Set(ids)
        return roomMessages[roomID, default: []].filter { idSet.contains($0.id) }
    }

    func uploadAttachment(roomID: String, contentType: String, data: Data) async throws -> FriendChatService.AttachmentUploadResult {
        if let errorToThrow { throw errorToThrow }
        let id = UUID().uuidString
        uploadedAttachments.append((roomID: roomID, contentType: contentType, data: data, id: id))
        return .init(id: id)
    }

    func uploadedAttachmentsSnapshot() -> [(roomID: String, contentType: String, data: Data, id: String)] {
        uploadedAttachments
    }

    func downloadAttachment(roomID: String, id: String) async throws -> Data {
        if let errorToThrow { throw errorToThrow }
        guard let match = uploadedAttachments.first(where: { $0.roomID == roomID && $0.id == id }) else {
            throw URLError(.badServerResponse)
        }
        return match.data
    }

    var blockedByMeRooms: Set<String> = []
    var reportedMessages: [(roomID: String, messageID: Int, reason: String)] = []

    func block(roomID: String) async throws -> FriendChatService.BlockResult {
        if let errorToThrow { throw errorToThrow }
        blockedByMeRooms.insert(roomID)
        // Keeps `blocked` (what blockedContacts() reads back) in sync with
        // blockedByMeRooms — the store's own block() re-fetches via
        // refreshBlockedContacts() right after this call, so a mock that
        // only updated blockedByMeRooms would have that refresh silently
        // wipe the block back out.
        if !blocked.contains(where: { $0.roomID == roomID }) {
            blocked.append(.init(code: roomID, name: roomID, roomID: roomID))
        }
        return .init(status: "blocked")
    }

    func unblock(roomID: String) async throws -> FriendChatService.BlockResult {
        if let errorToThrow { throw errorToThrow }
        blockedByMeRooms.remove(roomID)
        blocked.removeAll { $0.roomID == roomID }
        return .init(status: "unblocked")
    }

    func blockStatus(roomID: String) async throws -> FriendChatService.BlockStatus {
        if let errorToThrow { throw errorToThrow }
        return .init(blockedByMe: blockedByMeRooms.contains(roomID), blockedByOther: false)
    }

    func report(roomID: String, messageID: Int, reason: String) async throws -> FriendChatService.ReportResult {
        if let errorToThrow { throw errorToThrow }
        reportedMessages.append((roomID: roomID, messageID: messageID, reason: reason))
        return .init(status: "reported")
    }

    func blockedByMeRoomsSnapshot() -> Set<String> {
        blockedByMeRooms
    }

    func reportedMessagesSnapshot() -> [(roomID: String, messageID: Int, reason: String)] {
        reportedMessages
    }

    func setMessages(_ messages: [String: [FriendChatService.Message]]) {
        roomMessages = messages
    }

    func appendMessage(_ message: FriendChatService.Message, to roomID: String) {
        roomMessages[roomID, default: []].append(message)
    }

    func sentMessages() -> [SentMessage] {
        sent
    }
}
