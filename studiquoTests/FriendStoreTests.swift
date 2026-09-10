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

    // Regression coverage for "sharing the QR/invitation link before
    // registration finishes shares the placeholder text instead of a real
    // code": the add-friend screen must know not to show it yet.

    func testIsCodeReadyIsFalseOnAFreshInstallAndTrueAfterRegistering() async {
        let client = MockFriendChatClient(identity: .init(code: "ME1234", name: "Me"))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)

        XCTAssertFalse(store.isCodeReady, "a brand-new install has no persisted code yet")

        await store.refresh()

        XCTAssertTrue(store.isCodeReady)
        XCTAssertEqual(store.myCode, "ME1234")
    }

    func testIsCodeReadyIsTrueImmediatelyWhenALastKnownCodeWasAlreadyPersisted() {
        defaults.set("ME1234", forKey: "studiquoFriendCode")
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

    func testSendDoesNotMarkTheMessageAsFailedWhenTheServerAccepts() async {
        let client = MockFriendChatClient()
        let alice = FriendRecord(id: UUID(), name: "Alice", code: "ALICE1", todayStudySeconds: 0, roomID: "room-a", isDemo: false)
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        store.friends = [alice]

        store.send("hello", to: alice)
        await waitUntil { await client.sentMessages().count == 1 }

        XCTAssertEqual(store.messages(for: alice).first?.sendFailed, nil)
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
        await client.setErrorToThrow(FriendChatService.ServerError(status: 400, message: "Friend list is full."))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()

        store.accept(store.incomingRequests[0])
        await waitUntil { !store.errorMessage.isEmpty }

        XCTAssertEqual(store.errorMessage, "フレンドの上限に達しているため追加できません。")
        XCTAssertTrue(store.friends.isEmpty)
    }

    func testRejectSurfacesTheServersSpecificReason() async {
        let client = MockFriendChatClient()
        await client.setPendingRequests([.init(code: "MALLRY", name: "Mallory", requestedAt: 1_700_000_000_000)])
        await client.setErrorToThrow(FriendChatService.ServerError(status: 404, message: "Request not found."))
        let store = FriendStore(client: client, defaults: defaults, autoRefresh: false)
        await store.refreshIncomingRequests()

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

private actor MockFriendChatClient: FriendChatClient {
    struct SentMessage: Equatable {
        let text: String
        let roomID: String
    }

    var identity: FriendChatService.Identity
    var remoteFriends: [FriendChatService.Friend]
    var roomMessages: [String: [FriendChatService.Message]]
    var sent: [SentMessage] = []
    var pendingRequests: [FriendChatService.IncomingRequest] = []
    var outgoingPendingRequests: [FriendChatService.OutgoingRequest] = []
    var acceptedCodes: [String] = []
    var rejectedCodes: [String] = []
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

    func friends() async throws -> [FriendChatService.Friend] {
        if let errorToThrow { throw errorToThrow }
        return remoteFriends
    }

    func setFriends(_ value: [FriendChatService.Friend]) {
        remoteFriends = value
    }

    func add(code: String) async throws -> FriendChatService.AddFriendResult {
        if isRateLimited { throw FriendChatService.RateLimitedError() }
        if let errorToThrow { throw errorToThrow }
        guard remoteFriends.contains(where: { $0.code == code }) else {
            throw URLError(.badServerResponse)
        }
        return .init(status: "pending")
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
