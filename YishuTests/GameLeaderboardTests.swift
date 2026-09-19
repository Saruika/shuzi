import XCTest
@testable import Yishu

@MainActor
private final class LeaderboardTestAccount: GameLeaderboardAccount {
    var gameLeaderboardContext: FanNotificationContext? = .init(userID: "synthetic-a", sessionGeneration: 1)
    var response: GameLeaderboardPage
    var failure: Error?
    var pauseNext = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls: [String] = []
    private(set) var submissions: [GameRunSubmission] = []

    init(response: GameLeaderboardPage) { self.response = response }

    func fetchGameLeaderboard() async throws -> GameLeaderboardPage { try await reply("GET") }
    func submitGameScore(_ run: GameRunSubmission) async throws -> GameLeaderboardPage {
        submissions.append(run)
        return try await reply("POST")
    }
    func removeGameScore() async throws -> GameLeaderboardPage { try await reply("DELETE") }

    private func reply(_ method: String) async throws -> GameLeaderboardPage {
        calls.append(method)
        let capturedPage = response
        let capturedFailure = failure
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { continuation = $0 }
        }
        if let capturedFailure { throw capturedFailure }
        return capturedPage
    }

    func resume() { let pending = continuation; continuation = nil; pending?.resume() }
}

@MainActor
final class GameLeaderboardTests: XCTestCase {
    func testCompletedGamePublishesWithoutOpeningLeaderboardOrConfirmingAgain() async throws {
        let account = LeaderboardTestAccount(response: try page(isMe: true))
        let store = GameLeaderboardStore()
        await store.complete(try payload(), using: account)
        XCTAssertEqual(account.calls, ["POST"])
        XCTAssertEqual(account.submissions.first?.choices, [0])
        XCTAssertEqual(store.myEntry, account.response.myEntry)
        XCTAssertTrue(store.pendingRuns.isEmpty)
        XCTAssertNil(store.preparedRun)
        await store.flushCompletedRuns(using: account)
        await store.refresh(using: account)
        XCTAssertEqual(account.calls, ["POST", "GET"], "Opening or refreshing must not republish a completed run")
    }

    func testAutomaticSubmissionSerializesGamesFinishedDuringSlowRequest() async throws {
        let account = LeaderboardTestAccount(response: try page(isMe: true))
        let store = GameLeaderboardStore()
        account.pauseNext = true
        let first = Task { await store.complete(try payload(), using: account) }
        await waitForCalls(1, on: account)
        await store.complete(try payload([1, 2]), using: account)
        XCTAssertEqual(store.pendingRuns.count, 2)
        XCTAssertEqual(account.calls, ["POST"])
        account.resume()
        try await first.value
        XCTAssertEqual(account.submissions.map(\.choices), [[0], [1, 2]])
        XCTAssertTrue(store.pendingRuns.isEmpty)
        XCTAssertFalse(store.isWriting)
    }

    func testFailedAutomaticSubmissionRemainsInMemoryAndCanRetryWithoutConsentDialog() async throws {
        let account = LeaderboardTestAccount(response: try page(isMe: true))
        let store = GameLeaderboardStore()
        account.failure = URLError(.notConnectedToInternet)
        await store.complete(try payload(), using: account)
        XCTAssertEqual(store.pendingRuns.count, 1)
        XCTAssertNil(store.myEntry)
        XCTAssertNotNil(store.errorMessage)
        await Task.yield()
        XCTAssertEqual(account.calls, ["POST"], "No unbounded background retry loop")
        account.failure = nil
        await store.flushCompletedRuns(using: account)
        XCTAssertEqual(account.calls, ["POST", "POST"])
        XCTAssertEqual(account.submissions[0], account.submissions[1])
        XCTAssertTrue(store.pendingRuns.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testRemoveClearsFailedQueueAndDoesNotResurrectOldScore() async throws {
        let account = LeaderboardTestAccount(response: try GameLeaderboardPage(entries: []))
        let store = GameLeaderboardStore()
        account.failure = URLError(.timedOut)
        await store.complete(try payload(), using: account)
        account.failure = nil
        await store.remove(using: account)
        await store.flushCompletedRuns(using: account)
        XCTAssertEqual(account.calls, ["POST", "DELETE"])
        XCTAssertTrue(store.pendingRuns.isEmpty)
        await store.complete(try payload([2]), using: account)
        XCTAssertEqual(account.calls, ["POST", "DELETE", "POST"], "Only a newly completed game may rejoin")
        XCTAssertEqual(account.submissions.last?.choices, [2])
    }

    func testNewCompletedGameWaitsForDeletionInsteadOfDroppingItsScore() async throws {
        let account = LeaderboardTestAccount(response: try GameLeaderboardPage(entries: []))
        let store = GameLeaderboardStore()
        account.pauseNext = true
        let removal = Task { await store.remove(using: account) }
        await waitForCalls(1, on: account)
        let finished = Task { await store.complete(try payload([3]), using: account) }
        await Task.yield()
        XCTAssertEqual(account.calls, ["DELETE"])
        account.resume()
        await removal.value
        try await finished.value
        XCTAssertEqual(account.calls, ["DELETE", "POST"])
        XCTAssertTrue(store.pendingRuns.isEmpty)
    }

    func testAutomaticQueueNeverCrossesAccountSessionOrEnvironment() async throws {
        let first = LeaderboardTestAccount(response: try page(name: "first"))
        let second = LeaderboardTestAccount(response: try page(name: "second"))
        second.gameLeaderboardContext = .init(userID: "synthetic-b", sessionGeneration: 2, environment: .review)
        let store = GameLeaderboardStore()
        first.pauseNext = true
        let old = Task { await store.complete(try payload(), using: first) }
        await waitForCalls(1, on: first)
        await store.complete(try payload([1]), using: first)
        store.updateContext(second.gameLeaderboardContext)
        await store.complete(try payload([2]), using: second)
        first.resume()
        try await old.value
        await waitForCalls(1, on: second)
        XCTAssertEqual(first.submissions.map(\.choices), [[0]])
        XCTAssertEqual(second.submissions.map(\.choices), [[2]])
        XCTAssertEqual(store.page, second.response)
        XCTAssertTrue(store.pendingRuns.isEmpty)
    }

    func testSignedOutCompletionAndLogoutCannotPublishPendingRuns() async throws {
        let account = LeaderboardTestAccount(response: try page())
        let store = GameLeaderboardStore()
        account.failure = URLError(.notConnectedToInternet)
        await store.complete(try payload(), using: account)
        account.gameLeaderboardContext = nil
        store.updateContext(nil)
        await store.flushCompletedRuns(using: account)
        await store.complete(try payload([1]), using: account)
        XCTAssertEqual(account.calls, ["POST"])
        XCTAssertTrue(store.pendingRuns.isEmpty)
    }

    private func payload(_ choices: [Int] = [0]) throws -> GameRunPayload {
        try GameRunPayload(origin: "peasant", choices: choices)
    }

    private func entry(rank: Int = 1, name: String = "合成测试用户", score: Int = 0,
                       isMe: Bool = false) throws -> GameLeaderboardEntry {
        try GameLeaderboardEntry(rank: rank, displayName: name, score: score, endingTitle: "合成测试结局",
                                 originName: "农民家庭", answered: 108,
                                 achievedAt: Date(timeIntervalSince1970: 1_800_000_000), isMe: isMe)
    }

    private func page(name: String = "合成测试用户", isMe: Bool = false) throws -> GameLeaderboardPage {
        let item = try entry(name: name, isMe: isMe)
        return try GameLeaderboardPage(entries: [item], myEntry: isMe ? item : nil)
    }

    private func entryJSON() -> [String: Any] {
        ["rank": 1, "displayName": "合成测试用户", "score": -1, "endingTitle": "合成测试结局",
         "originName": "农民家庭", "answered": 108, "achievedAt": "2026-09-17T01:00:00Z", "isMe": false]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json))
    }

    private func waitForCalls(_ count: Int, on account: LeaderboardTestAccount,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while account.calls.count < count, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(account.calls.count, count, file: file, line: line)
    }

    func testPayloadAllowsOnlySixOriginsAndBoundedIntegerChoices() throws {
        for origin in GameRules.origins {
            let value = try decode(GameRunPayload.self, ["origin": origin, "choices": [0, 1, 2, 3]])
            XCTAssertEqual(value.origin, origin)
            XCTAssertEqual(value.choices, [0, 1, 2, 3])
        }
        XCTAssertEqual(try payload(Array(repeating: 3, count: 108)).choices.count, 108)
        for invalidChoices: Any in [[], Array(repeating: 0, count: 109), [-1], [4], [true], [1.5], ["1"], NSNull()] {
            XCTAssertThrowsError(try decode(GameRunPayload.self, ["origin": "peasant", "choices": invalidChoices]))
        }
        for origin in ["", "Peasant", "unknown", "peasant "] {
            XCTAssertThrowsError(try GameRunPayload(origin: origin, choices: [0]))
        }
        for choices in [[], [-1], [4], Array(repeating: 0, count: 109)] {
            XCTAssertThrowsError(try payload(choices))
        }
    }

    func testPayloadRejectsExtraScoreIdentityConsentAndMissingFields() throws {
        for key in ["score", "userID", "consent", "rulesVersion", "__proto__"] {
            XCTAssertThrowsError(try decode(GameRunPayload.self, ["origin": "peasant", "choices": [0], key: 1]))
        }
        XCTAssertThrowsError(try decode(GameRunPayload.self, ["origin": "peasant"]))
        XCTAssertThrowsError(try decode(GameRunPayload.self, ["choices": [0]]))
        XCTAssertThrowsError(try decode(GameRunPayload.self, ["origin": true, "choices": [0]]))
        XCTAssertThrowsError(try decode(GameRunPayload.self, [["origin": "peasant", "choices": [0]]]))
    }

    func testSubmissionEncodesOnlyServerReplayInputsAndExplicitConsent() throws {
        let run = GameRunSubmission(payload: try payload([0, 3]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["rulesVersion", "origin", "choices", "consent"])
        XCTAssertEqual(json["rulesVersion"] as? String, "life-v1")
        XCTAssertEqual(json["origin"] as? String, "peasant")
        XCTAssertEqual(json["choices"] as? [Int], [0, 3])
        XCTAssertEqual(json["consent"] as? Bool, true)
        XCTAssertThrowsError(try GameRunSubmission(origin: "not-an-origin", choices: [0]))
    }

    func testEntryPreservesOriginalSignedScoreAndParsesISO8601() throws {
        for score in [GameRules.scoreRange.lowerBound, -1, 0, 1201, GameRules.scoreRange.upperBound] {
            var json = entryJSON()
            json["score"] = score
            let item = try decode(GameLeaderboardEntry.self, json)
            XCTAssertEqual(item.score, score)
            XCTAssertEqual(item.id, item.rank)
        }
        var fractional = entryJSON()
        fractional["achievedAt"] = "2026-09-17T01:00:00.125Z"
        XCTAssertEqual(try decode(GameLeaderboardEntry.self, fractional).achievedAt
            .timeIntervalSince(try decode(GameLeaderboardEntry.self, entryJSON()).achievedAt), 0.125, accuracy: 0.001)
    }

    func testEntryRejectsMalformedAndOutOfRangeFields() throws {
        let invalid: [(String, Any)] = [
            ("rank", 0), ("rank", true), ("rank", 1.5),
            ("score", -16_777_217), ("score", 16_777_216), ("score", true), ("score", 3.2),
            ("answered", 0), ("answered", 109), ("answered", true),
            ("displayName", ""), ("displayName", "  "), ("displayName", "姓名\n其他"),
            ("displayName", String(repeating: "名", count: 41)),
            ("endingTitle", ""), ("endingTitle", String(repeating: "结", count: 81)),
            ("originName", ""), ("originName", String(repeating: "家", count: 41)),
            ("achievedAt", "yesterday"), ("achievedAt", 1000), ("isMe", 1)
        ]
        for (key, value) in invalid {
            var json = entryJSON()
            json[key] = value
            XCTAssertThrowsError(try decode(GameLeaderboardEntry.self, json), "Invalid field: \(key)")
        }
        for key in entryJSON().keys {
            var json = entryJSON()
            json.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(GameLeaderboardEntry.self, json), "Required field: \(key)")
        }
    }

    func testPageValidatesVersionLimitUniqueRanksAndPersonalEntry() throws {
        XCTAssertTrue(try GameLeaderboardPage(entries: []).entries.isEmpty)
        let hundred = try (1...100).map { try entry(rank: $0) }
        XCTAssertEqual(try GameLeaderboardPage(entries: hundred).entries.count, 100)
        XCTAssertThrowsError(try GameLeaderboardPage(entries: hundred + [entry(rank: 101)]))
        XCTAssertThrowsError(try GameLeaderboardPage(rulesVersion: "life-v2", entries: []))
        XCTAssertThrowsError(try GameLeaderboardPage(entries: [entry(), entry()]))
        XCTAssertThrowsError(try GameLeaderboardPage(entries: [], myEntry: entry(isMe: false)))
        XCTAssertThrowsError(try GameLeaderboardPage(entries: [entry(isMe: true)]))
        XCTAssertThrowsError(try GameLeaderboardPage(entries: [entry(isMe: true), entry(rank: 2, isMe: true)],
                                                    myEntry: entry(isMe: true)))
        XCTAssertThrowsError(try GameLeaderboardPage(entries: [entry()], myEntry: entry(isMe: true)))
        let outOfTop100 = try entry(rank: 101, isMe: true)
        XCTAssertEqual(try GameLeaderboardPage(entries: hundred, myEntry: outOfTop100).myEntry, outOfTop100)
        XCTAssertEqual(try page(isMe: true).entries.first, try page(isMe: true).myEntry)
        XCTAssertThrowsError(try decode(GameLeaderboardPage.self,
                                       ["rulesVersion": "life-v2", "entries": []]))
        XCTAssertThrowsError(try decode(GameLeaderboardPage.self,
                                       ["rulesVersion": "life-v1", "entries": Array(repeating: entryJSON(), count: 101)]))
        XCTAssertEqual(try decode(GameLeaderboardPage.self,
                                 ["rulesVersion": "life-v1", "entries": [entryJSON()], "myEntry": NSNull()]).entries.count, 1)
    }

    func testSignedOutStoreCannotLoadPrepareSubmitOrDelete() async throws {
        let account = LeaderboardTestAccount(response: try page())
        account.gameLeaderboardContext = nil
        let store = GameLeaderboardStore()
        XCTAssertFalse(store.prepare(try payload(), using: account))
        await store.refresh(using: account)
        await store.submit(run: GameRunSubmission(payload: try payload()), using: account)
        await store.remove(using: account)
        XCTAssertTrue(account.calls.isEmpty)
        XCTAssertNil(store.page)
        XCTAssertNil(store.preparedRun)
        XCTAssertNotNil(store.errorMessage)
    }

    func testSubmissionRequiresPreparedRunAndDoesNotAutomaticallyPublish() async throws {
        let account = LeaderboardTestAccount(response: try page(isMe: true))
        let store = GameLeaderboardStore()
        await store.submit(run: GameRunSubmission(payload: try payload()), using: account)
        XCTAssertTrue(account.calls.isEmpty)
        XCTAssertTrue(store.prepare(try payload(), using: account))
        let run = try XCTUnwrap(store.preparedRun)
        XCTAssertTrue(account.calls.isEmpty)
        await store.submit(run: GameRunSubmission(payload: try payload([1])), using: account)
        XCTAssertTrue(account.calls.isEmpty)
        await store.submit(run: run, using: account)
        XCTAssertEqual(account.calls, ["POST"])
        XCTAssertEqual(account.submissions, [run])
        XCTAssertEqual(store.myEntry, account.response.myEntry)
        XCTAssertNil(store.preparedRun)
        await store.submit(run: run, using: account)
        XCTAssertEqual(account.calls, ["POST"], "Completed preparation cannot be published twice")
    }

    func testLateResponsesCannotCrossLogoutUserSessionOrEnvironment() async throws {
        let transitions: [FanNotificationContext?] = [nil,
            .init(userID: "synthetic-b", sessionGeneration: 1),
            .init(userID: "synthetic-a", sessionGeneration: 2),
            .init(userID: "synthetic-a", sessionGeneration: 1, environment: .review)]
        for operation in ["GET", "POST", "DELETE"] {
            for nextContext in transitions {
                let account = LeaderboardTestAccount(response: try page(isMe: true))
                let store = GameLeaderboardStore()
                XCTAssertTrue(store.prepare(try payload(), using: account))
                let run = try XCTUnwrap(store.preparedRun)
                account.pauseNext = true
                let request = Task {
                    switch operation {
                    case "GET": await store.refresh(using: account)
                    case "POST": await store.submit(run: run, using: account)
                    default: await store.remove(using: account)
                    }
                }
                await waitForCalls(1, on: account)
                account.gameLeaderboardContext = nextContext
                // Completion must notice the account change even before a View's onChange callback.
                account.resume()
                await request.value
                XCTAssertNil(store.page, operation)
                XCTAssertNil(store.preparedRun, operation)
                XCTAssertFalse(store.isLoading)
                XCTAssertFalse(store.isWriting)
                XCTAssertNil(store.errorMessage)
            }
        }
    }

    func testExplicitLogoutClearsVisiblePageAndPreparedRunImmediately() async throws {
        let account = LeaderboardTestAccount(response: try page(isMe: true))
        let store = GameLeaderboardStore()
        await store.refresh(using: account)
        XCTAssertTrue(store.prepare(try payload(), using: account))
        XCTAssertNotNil(store.myEntry)
        store.updateContext(nil)
        XCTAssertNil(store.page)
        XCTAssertNil(store.preparedRun)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testDifferentAccountObjectWithIdenticalContextCannotReceiveOldRunOrReply() async throws {
        let first = LeaderboardTestAccount(response: try page(name: "first"))
        let second = LeaderboardTestAccount(response: try page(name: "second"))
        let store = GameLeaderboardStore()
        XCTAssertTrue(store.prepare(try payload(), using: first))
        let oldRun = try XCTUnwrap(store.preparedRun)
        first.pauseNext = true
        let oldRead = Task { await store.refresh(using: first) }
        await waitForCalls(1, on: first)
        await store.refresh(using: second)
        XCTAssertEqual(store.page, second.response)
        XCTAssertNil(store.preparedRun)
        await store.submit(run: oldRun, using: second)
        XCTAssertEqual(second.calls, ["GET"])
        first.resume()
        await oldRead.value
        XCTAssertEqual(store.page, second.response)
    }

    func testOldReadCannotOverwriteCompletedSubmission() async throws {
        let account = LeaderboardTestAccount(response: try page(name: "before"))
        let store = GameLeaderboardStore()
        account.pauseNext = true
        let read = Task { await store.refresh(using: account) }
        await waitForCalls(1, on: account)
        XCTAssertTrue(store.prepare(try payload(), using: account))
        account.response = try page(name: "after", isMe: true)
        await store.submit(run: try XCTUnwrap(store.preparedRun), using: account)
        account.resume()
        await read.value
        XCTAssertEqual(store.page, account.response)
        XCTAssertEqual(store.myEntry?.displayName, "after")
    }

    func testConcurrentWritesAndRefreshDoNotIssueDuplicateRequests() async throws {
        let account = LeaderboardTestAccount(response: try page(isMe: true))
        let store = GameLeaderboardStore()
        XCTAssertTrue(store.prepare(try payload(), using: account))
        let run = try XCTUnwrap(store.preparedRun)
        account.pauseNext = true
        let first = Task { await store.submit(run: run, using: account) }
        await waitForCalls(1, on: account)
        XCTAssertTrue(store.isWriting)
        await store.submit(run: run, using: account)
        await store.remove(using: account)
        await store.refresh(using: account)
        XCTAssertTrue(store.prepare(try payload([1]), using: account))
        let nextRun = try XCTUnwrap(store.preparedRun)
        await store.submit(run: nextRun, using: account)
        XCTAssertEqual(account.calls, ["POST"])
        account.resume()
        await first.value
        XCTAssertFalse(store.isWriting)
        XCTAssertEqual(store.page, account.response)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.preparedRun, nextRun, "Finishing a new local run during a slow POST must not lose it")
    }

    func testOldConfirmationCannotApproveIdenticalNewAccountPreparation() async throws {
        let account = LeaderboardTestAccount(response: try page(isMe: true))
        let store = GameLeaderboardStore()
        XCTAssertTrue(store.prepare(try payload(), using: account))
        let oldRun = try XCTUnwrap(store.preparedRun)
        account.gameLeaderboardContext = .init(userID: "synthetic-b", sessionGeneration: 1)
        XCTAssertTrue(store.prepare(try payload(), using: account))
        let newRun = try XCTUnwrap(store.preparedRun)
        XCTAssertNotEqual(oldRun, newRun)
        XCTAssertEqual(try JSONEncoder().encode(oldRun).count, try JSONEncoder().encode(newRun).count)
        await store.submit(run: oldRun, using: account)
        XCTAssertTrue(account.calls.isEmpty)
        await store.submit(run: newRun, using: account)
        XCTAssertEqual(account.calls, ["POST"])
    }

    func testSwitchWhileWriteInFlightClearsDataButDoesNotStartAnotherWrite() async throws {
        let account = LeaderboardTestAccount(response: try page(isMe: true))
        let store = GameLeaderboardStore()
        XCTAssertTrue(store.prepare(try payload(), using: account))
        let run = try XCTUnwrap(store.preparedRun)
        account.pauseNext = true
        let write = Task { await store.submit(run: run, using: account) }
        await waitForCalls(1, on: account)
        account.gameLeaderboardContext = .init(userID: "synthetic-b", sessionGeneration: 1)
        store.updateContext(account.gameLeaderboardContext)
        XCTAssertNil(store.page)
        XCTAssertNil(store.preparedRun)
        await store.remove(using: account)
        XCTAssertEqual(account.calls, ["POST"])
        account.resume()
        await write.value
        XCTAssertNil(store.page)
        XCTAssertFalse(store.isWriting)
        await store.refresh(using: account)
        XCTAssertEqual(account.calls, ["POST", "GET"])
    }

    func testFailuresClearStalePageUseSafeErrorAndNeverRetryPOSTAutomatically() async throws {
        for operation in ["GET", "POST", "DELETE"] {
            let account = LeaderboardTestAccount(response: try page(isMe: true))
            let store = GameLeaderboardStore()
            await store.refresh(using: account)
            XCTAssertNotNil(store.page)
            XCTAssertTrue(store.prepare(try payload(), using: account))
            account.failure = NSError(domain: "synthetic-sensitive-server-body", code: 503,
                                      userInfo: [NSLocalizedDescriptionKey: "DO-NOT-DISPLAY-SERVER-BODY"])
            switch operation {
            case "GET": await store.refresh(using: account)
            case "POST": await store.submit(run: try XCTUnwrap(store.preparedRun), using: account)
            default: await store.remove(using: account)
            }
            XCTAssertNil(store.page)
            XCTAssertEqual(store.errorMessage, GameLeaderboardError.unavailable.errorDescription)
            XCTAssertFalse(store.isLoading)
            XCTAssertFalse(store.isWriting)
            await Task.yield()
            XCTAssertEqual(account.calls, ["GET", operation])
        }
    }

    func testLateFailureDoesNotEraseNewAccountPage() async throws {
        let first = LeaderboardTestAccount(response: try page(name: "first"))
        first.failure = URLError(.timedOut)
        first.pauseNext = true
        let second = LeaderboardTestAccount(response: try page(name: "second"))
        second.gameLeaderboardContext = .init(userID: "synthetic-b", sessionGeneration: 4, environment: .review)
        let store = GameLeaderboardStore()
        let old = Task { await store.refresh(using: first) }
        await waitForCalls(1, on: first)
        await store.refresh(using: second)
        first.resume()
        await old.value
        XCTAssertEqual(store.page, second.response)
        XCTAssertNil(store.errorMessage)
    }

    func testDeleteUsesReturnedPageAndClearsPreparedRun() async throws {
        let account = LeaderboardTestAccount(response: try page(isMe: true))
        let store = GameLeaderboardStore()
        await store.refresh(using: account)
        XCTAssertTrue(store.prepare(try payload(), using: account))
        account.response = try GameLeaderboardPage(entries: [])
        await store.remove(using: account)
        XCTAssertEqual(account.calls, ["GET", "DELETE"])
        XCTAssertEqual(store.page, account.response)
        XCTAssertNil(store.myEntry)
        XCTAssertNil(store.preparedRun)
    }

    func testRunFinishedDuringSlowDeleteRemainsPreparedWithoutAutomaticPublication() async throws {
        let account = LeaderboardTestAccount(response: try GameLeaderboardPage(entries: []))
        let store = GameLeaderboardStore()
        XCTAssertTrue(store.prepare(try payload(), using: account))
        let oldRun = try XCTUnwrap(store.preparedRun)
        account.pauseNext = true
        let removal = Task { await store.remove(using: account) }
        await waitForCalls(1, on: account)
        XCTAssertNil(store.preparedRun, "Delete discards the preparation present at confirmation")
        XCTAssertTrue(store.prepare(try payload([1, 2]), using: account))
        let nextRun = try XCTUnwrap(store.preparedRun)
        XCTAssertNotEqual(nextRun, oldRun)
        await store.submit(run: nextRun, using: account)
        XCTAssertEqual(account.calls, ["DELETE"])
        account.resume()
        await removal.value
        XCTAssertEqual(store.preparedRun, nextRun)
        XCTAssertEqual(store.page, account.response)
        XCTAssertEqual(account.calls, ["DELETE"], "A newly finished local run still requires a separate explicit submission")
    }

    func testCancelledReadDoesNotPublishLatePage() async throws {
        let account = LeaderboardTestAccount(response: try page())
        account.pauseNext = true
        let store = GameLeaderboardStore()
        let request = Task { await store.refresh(using: account) }
        await waitForCalls(1, on: account)
        request.cancel()
        account.resume()
        await request.value
        XCTAssertNil(store.page)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }
}
