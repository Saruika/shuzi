import Foundation
import Combine

enum GameRules {
    static let version = "life-v1"
    static let origins: Set<String> = ["peasant", "worker", "teacher", "official", "business", "soldier"]
    // The original game score is signed, not a normalized percentage.
    static let scoreRange = -16_777_216...16_777_215
}

enum GameLeaderboardError: LocalizedError {
    case invalidRun, invalidResponse, signInRequired, confirmationRequired, busy, unavailable

    var errorDescription: String? {
        switch self {
        case .invalidRun: "本局记录无效，请重新完成游戏。"
        case .invalidResponse: "排行榜数据暂时无法读取，请稍后刷新。"
        case .signInRequired: "请登录后查看或发布排行榜成绩。"
        case .confirmationRequired: "本局同步状态已变化，请重新打开排行榜。"
        case .busy: "上一项操作尚未完成，请稍候。"
        case .unavailable: "操作暂未完成，请检查网络后刷新排行榜。"
        }
    }
}

/// The JS bridge may send choices, never a client-calculated score or identity.
struct GameRunPayload: Decodable, Equatable {
    let origin: String
    let choices: [Int]

    init(origin: String, choices: [Int]) throws {
        guard GameRules.origins.contains(origin), (1...108).contains(choices.count),
              choices.allSatisfy({ (0...3).contains($0) }) else { throw GameLeaderboardError.invalidRun }
        self.origin = origin
        self.choices = choices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Field.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["origin", "choices"] else {
            throw GameLeaderboardError.invalidRun
        }
        let origin = try container.decode(String.self, forKey: Field("origin"))
        var values = try container.nestedUnkeyedContainer(forKey: Field("choices"))
        guard values.count.map({ (1...108).contains($0) }) != false else {
            throw GameLeaderboardError.invalidRun
        }
        var choices: [Int] = []
        while !values.isAtEnd {
            guard choices.count < 108 else { throw GameLeaderboardError.invalidRun }
            // JSONDecoder's Int decoder rejects booleans and fractional numbers.
            choices.append(try values.decode(Int.self))
        }
        try self.init(origin: origin, choices: choices)
    }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
}

/// Prepared after the game's start notice. Only replay inputs are encoded.
struct GameRunSubmission: Encodable, Equatable {
    let rulesVersion = GameRules.version
    let origin: String
    let choices: [Int]
    let consent = true
    // Distinguish identical runs prepared by different accounts or at different times.
    // A delayed operation must not accidentally publish another preparation.
    private let preparationID = UUID()

    init(payload: GameRunPayload) {
        origin = payload.origin
        choices = payload.choices
    }

    init(origin: String, choices: [Int]) throws {
        self.init(payload: try GameRunPayload(origin: origin, choices: choices))
    }

    private enum CodingKeys: String, CodingKey { case rulesVersion, origin, choices, consent }
}

struct GameLeaderboardEntry: Decodable, Identifiable, Equatable {
    let rank: Int
    let displayName: String
    let score: Int
    let endingTitle: String
    let originName: String
    let answered: Int
    let achievedAt: Date
    let isMe: Bool
    var id: Int { rank }

    init(rank: Int, displayName: String, score: Int, endingTitle: String, originName: String,
         answered: Int, achievedAt: Date, isMe: Bool) throws {
        guard rank >= 1, Self.validText(displayName, max: 40), GameRules.scoreRange.contains(score),
              Self.validText(endingTitle, max: 80), Self.validText(originName, max: 40),
              (1...108).contains(answered), achievedAt.timeIntervalSince1970.isFinite else {
            throw GameLeaderboardError.invalidResponse
        }
        self.rank = rank
        self.displayName = displayName
        self.score = score
        self.endingTitle = endingTitle
        self.originName = originName
        self.answered = answered
        self.achievedAt = achievedAt
        self.isMe = isMe
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawDate = try values.decode(String.self, forKey: .achievedAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = formatter.date(from: rawDate)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractionalDate ?? formatter.date(from: rawDate) else {
            throw GameLeaderboardError.invalidResponse
        }
        try self.init(rank: values.decode(Int.self, forKey: .rank),
                      displayName: values.decode(String.self, forKey: .displayName),
                      score: values.decode(Int.self, forKey: .score),
                      endingTitle: values.decode(String.self, forKey: .endingTitle),
                      originName: values.decode(String.self, forKey: .originName),
                      answered: values.decode(Int.self, forKey: .answered), achievedAt: date,
                      isMe: values.decode(Bool.self, forKey: .isMe))
    }

    private enum CodingKeys: String, CodingKey {
        case rank, displayName, score, endingTitle, originName, answered, achievedAt, isMe
    }

    private static func validText(_ value: String, max: Int) -> Bool {
        (1...max).contains(value.count)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

struct GameLeaderboardPage: Decodable, Equatable {
    let rulesVersion: String
    let entries: [GameLeaderboardEntry]
    let myEntry: GameLeaderboardEntry?

    init(rulesVersion: String = GameRules.version, entries: [GameLeaderboardEntry],
         myEntry: GameLeaderboardEntry? = nil) throws {
        guard rulesVersion == GameRules.version, entries.count <= 100,
              Set(entries.map(\.rank)).count == entries.count,
              entries.filter(\.isMe).count <= 1, myEntry?.isMe != false else {
            throw GameLeaderboardError.invalidResponse
        }
        if let visibleMe = entries.first(where: \.isMe), visibleMe != myEntry {
            throw GameLeaderboardError.invalidResponse
        }
        if let myEntry, let visibleRank = entries.first(where: { $0.rank == myEntry.rank }),
           visibleRank != myEntry { throw GameLeaderboardError.invalidResponse }
        self.rulesVersion = rulesVersion
        self.entries = entries
        self.myEntry = myEntry
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var items = try values.nestedUnkeyedContainer(forKey: .entries)
        guard items.count.map({ $0 <= 100 }) != false else { throw GameLeaderboardError.invalidResponse }
        var entries: [GameLeaderboardEntry] = []
        while !items.isAtEnd {
            guard entries.count < 100 else { throw GameLeaderboardError.invalidResponse }
            entries.append(try items.decode(GameLeaderboardEntry.self))
        }
        try self.init(rulesVersion: values.decode(String.self, forKey: .rulesVersion), entries: entries,
                      myEntry: values.decodeIfPresent(GameLeaderboardEntry.self, forKey: .myEntry))
    }

    private enum CodingKeys: String, CodingKey { case rulesVersion, entries, myEntry }
}

@MainActor
protocol GameLeaderboardAccount: AnyObject {
    var gameLeaderboardContext: FanNotificationContext? { get }
    func fetchGameLeaderboard() async throws -> GameLeaderboardPage
    func submitGameScore(_ run: GameRunSubmission) async throws -> GameLeaderboardPage
    func removeGameScore() async throws -> GameLeaderboardPage
}

/// Memory-only results. Completed games publish automatically; opening a leaderboard
/// never manufactures a result. Failed requests await an explicit retry, not a retry loop.
@MainActor
final class GameLeaderboardStore: ObservableObject {
    @Published private(set) var page: GameLeaderboardPage?
    @Published private(set) var preparedRun: GameRunSubmission?
    @Published private(set) var isLoading = false
    @Published private(set) var isWriting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingRuns: [GameRunSubmission] = []
    var entries: [GameLeaderboardEntry] { page?.entries ?? [] }
    var myEntry: GameLeaderboardEntry? { page?.myEntry }

    private var context: FanNotificationContext?
    private var accountID: ObjectIdentifier?
    private var generation: UInt64 = 0
    private var readGeneration: UInt64 = 0
    // A switched account cannot start a second write while the old request is in flight.
    private var writeID: UUID?
    private var automaticFlushID: UUID?
    private weak var pendingAccount: (any GameLeaderboardAccount)?

    /// Called only by a completed, locally bundled game after its start notice.
    func complete(_ payload: GameRunPayload, using account: any GameLeaderboardAccount) async {
        bind(account)
        guard context != nil else { errorMessage = GameLeaderboardError.signInRequired.errorDescription; return }
        pendingRuns.append(GameRunSubmission(payload: payload))
        pendingAccount = account
        await flushCompletedRuns(using: account)
    }

    /// Serializes completed runs so a slow POST cannot lose the next game's result.
    /// Same-score requests are idempotent on the server; ambiguous failures are not
    /// automatically replayed after removal or an account/environment change.
    func flushCompletedRuns(using account: any GameLeaderboardAccount) async {
        bind(account)
        guard let expected = context, !pendingRuns.isEmpty, automaticFlushID == nil else { return }
        let epoch = generation
        let flushID = UUID()
        automaticFlushID = flushID
        defer {
            if automaticFlushID == flushID { automaticFlushID = nil }
            // A new login may finish a run while the previous request is ending.
            // Resume only that new account's own queue, never the previous result.
            if generation != epoch, !pendingRuns.isEmpty, let nextAccount = pendingAccount {
                Task {
                    guard self.pendingAccount === nextAccount else { return }
                    await self.flushCompletedRuns(using: nextAccount)
                }
            }
        }
        while !Task.isCancelled, accepts(account, expected: expected, epoch: epoch),
              let run = pendingRuns.first {
            if isWriting {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                continue
            }
            preparedRun = run
            await submit(run: run, using: account)
            guard accepts(account, expected: expected, epoch: epoch), !Task.isCancelled else { return }
            // Failed or cancelled writes leave their exact result available to retry.
            guard preparedRun != run else { return }
            if pendingRuns.first == run { pendingRuns.removeFirst() }
        }
    }

    func updateContext(_ newContext: FanNotificationContext?) {
        guard context != newContext else { return }
        context = newContext
        accountID = nil
        clearAccountState()
    }

    @discardableResult
    func prepare(_ payload: GameRunPayload, using account: any GameLeaderboardAccount) -> Bool {
        bind(account)
        guard context != nil else { errorMessage = GameLeaderboardError.signInRequired.errorDescription; return false }
        // Finishing a new local run does not start a request. Preserve it even
        // while a previous POST/DELETE is waiting on a slow connection.
        preparedRun = GameRunSubmission(payload: payload)
        errorMessage = nil
        return true
    }

    func discardPreparedRun() { preparedRun = nil; pendingRuns = []; pendingAccount = nil }

    func refresh(using account: any GameLeaderboardAccount) async {
        bind(account)
        guard let expected = context else { errorMessage = GameLeaderboardError.signInRequired.errorDescription; return }
        guard !isLoading, !isWriting else { return }
        let epoch = generation
        readGeneration &+= 1
        let request = readGeneration
        isLoading = true
        page = nil
        errorMessage = nil
        defer { if generation == epoch, readGeneration == request { isLoading = false } }
        do {
            let result = try await account.fetchGameLeaderboard()
            guard accepts(account, expected: expected, epoch: epoch), readGeneration == request,
                  !Task.isCancelled else { return }
            page = result
            errorMessage = nil
        } catch {
            guard accepts(account, expected: expected, epoch: epoch), readGeneration == request,
                  !Task.isCancelled else { return }
            fail(error)
        }
    }

    /// Accept only the exact pending result; never accept an arbitrary score or identity.
    func submit(run: GameRunSubmission, using account: any GameLeaderboardAccount) async {
        bind(account)
        guard let expected = context else { errorMessage = GameLeaderboardError.signInRequired.errorDescription; return }
        guard !isWriting else { errorMessage = GameLeaderboardError.busy.errorDescription; return }
        guard preparedRun == run else { errorMessage = GameLeaderboardError.confirmationRequired.errorDescription; return }
        await write(using: account, expected: expected, run: run)
    }

    func remove(using account: any GameLeaderboardAccount) async {
        bind(account)
        guard let expected = context else { errorMessage = GameLeaderboardError.signInRequired.errorDescription; return }
        guard !isWriting else { errorMessage = GameLeaderboardError.busy.errorDescription; return }
        discardPreparedRun()
        await write(using: account, expected: expected, run: nil)
    }

    private func write(using account: any GameLeaderboardAccount, expected: FanNotificationContext,
                       run: GameRunSubmission?) async {
        let epoch = generation
        let request = UUID()
        writeID = request
        isWriting = true
        readGeneration &+= 1 // An older GET cannot overwrite POST/DELETE's authoritative page.
        isLoading = false
        page = nil
        errorMessage = nil
        defer { if writeID == request { writeID = nil; isWriting = false } }
        do {
            let result: GameLeaderboardPage
            if let run { result = try await account.submitGameScore(run) }
            else { result = try await account.removeGameScore() }
            guard accepts(account, expected: expected, epoch: epoch), writeID == request,
                  !Task.isCancelled else { return }
            page = result
            // Consume only the preparation this POST confirmed. A newer run
            // (including one finished during DELETE) stays in its own queue slot.
            if let run, preparedRun == run { preparedRun = nil }
            errorMessage = nil
        } catch {
            guard accepts(account, expected: expected, epoch: epoch), writeID == request,
                  !Task.isCancelled else { return }
            // Do not retry an ambiguous POST. An explicit subsequent user action is required.
            fail(error)
        }
    }

    private func bind(_ account: any GameLeaderboardAccount) {
        updateContext(account.gameLeaderboardContext)
        let identity = ObjectIdentifier(account)
        if let accountID, accountID != identity { clearAccountState() }
        accountID = identity
    }

    private func accepts(_ account: any GameLeaderboardAccount, expected: FanNotificationContext,
                         epoch: UInt64) -> Bool {
        guard accountID == ObjectIdentifier(account), generation == epoch, context == expected else { return false }
        guard account.gameLeaderboardContext == expected else {
            updateContext(account.gameLeaderboardContext)
            return false
        }
        return true
    }

    private func clearAccountState() {
        generation &+= 1
        readGeneration &+= 1
        page = nil
        preparedRun = nil
        pendingRuns = []
        pendingAccount = nil
        isLoading = false
        errorMessage = nil
    }

    private func fail(_ error: Error) {
        page = nil
        // Never surface a raw server body, URL, account identifier or authorization value.
        errorMessage = (error as? GameLeaderboardError)?.errorDescription
            ?? GameLeaderboardError.unavailable.errorDescription
    }
}
