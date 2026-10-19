import UIKit
import UserNotifications
import CryptoKit

enum PushDeviceTokenPolicy {
    static func encodedToken(from data: Data) -> String? {
        let token = data.map { String(format: "%02x", $0) }.joined()
        return isValid(token) ? token : nil
    }

    static func isValid(_ token: String) -> Bool {
        (2...512).contains(token.count)
            && token.count.isMultiple(of: 2)
            && token.range(of: #"^[a-f0-9]+$"#, options: .regularExpression) != nil
    }
}

enum PushNotificationPreferencePolicy {
    static func isEnabled(
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String,
        userID: String?
    ) -> Bool {
        guard let userID else { return false }
        return savedChoice(for: userID, in: defaults, preferenceKey: preferenceKey,
                           associationKey: associationKey) == true
    }

    static func setEnabled(
        _ enabled: Bool,
        for userID: String,
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String
    ) {
        // Keep each account's choice, especially opt-out, when another account
        // signs in. The legacy pair still describes the last selected account.
        var choices = defaults.dictionary(forKey: choicesKey(preferenceKey)) as? [String: Bool] ?? [:]
        if defaults.object(forKey: preferenceKey) != nil {
            if let previous = defaults.string(forKey: associationKey), choices[previous] == nil {
                choices[previous] = defaults.bool(forKey: preferenceKey)
            } else if defaults.string(forKey: associationKey) == nil,
                      !defaults.bool(forKey: preferenceKey) {
                defaults.set(true, forKey: legacyOptOutKey(preferenceKey))
            }
        }
        choices[association(for: userID)] = enabled
        defaults.set(choices, forKey: choicesKey(preferenceKey))
        defaults.set(enabled, forKey: preferenceKey)
        defaults.set(association(for: userID), forKey: associationKey)
    }

    static func hasExplicitChoice(
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String,
        userID: String
    ) -> Bool {
        savedChoice(for: userID, in: defaults, preferenceKey: preferenceKey,
                    associationKey: associationKey) != nil
    }

    /// iOS authorization is the user's opt-in; a second App toggle is not
    /// required. Quiet/temporary authorization is not an explicit Allow.
    /// Call only after validating the current account and session.
    static func enableAfterSystemAuthorization(
        _ status: UNAuthorizationStatus,
        for userID: String,
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String
    ) {
        guard status == .authorized,
              !hasExplicitChoice(in: defaults, preferenceKey: preferenceKey,
                                 associationKey: associationKey, userID: userID) else { return }
        setEnabled(true, for: userID, in: defaults, preferenceKey: preferenceKey,
                   associationKey: associationKey)
    }

    static func remove(
        for userID: String,
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String
    ) {
        var choices = defaults.dictionary(forKey: choicesKey(preferenceKey)) as? [String: Bool] ?? [:]
        choices.removeValue(forKey: association(for: userID))
        if choices.isEmpty {
            defaults.removeObject(forKey: choicesKey(preferenceKey))
        } else {
            defaults.set(choices, forKey: choicesKey(preferenceKey))
        }
        if defaults.string(forKey: associationKey) == association(for: userID) {
            defaults.removeObject(forKey: preferenceKey)
            defaults.removeObject(forKey: associationKey)
        }
    }

    private static func savedChoice(
        for userID: String,
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String
    ) -> Bool? {
        let identifier = association(for: userID)
        if let choices = defaults.dictionary(forKey: choicesKey(preferenceKey)) as? [String: Bool],
           let choice = choices[identifier] { return choice }
        if defaults.object(forKey: preferenceKey) != nil {
            if defaults.string(forKey: associationKey) == identifier {
                return defaults.bool(forKey: preferenceKey)
            }
            // Build 45's unscoped explicit opt-out cannot safely be assigned
            // to one account. Preserve it unless that account explicitly opts in.
            if defaults.string(forKey: associationKey) == nil,
               !defaults.bool(forKey: preferenceKey) { return false }
        }
        return defaults.bool(forKey: legacyOptOutKey(preferenceKey)) ? false : nil
    }

    private static func choicesKey(_ preferenceKey: String) -> String { preferenceKey + "-account-choices" }
    private static func legacyOptOutKey(_ preferenceKey: String) -> String { preferenceKey + "-legacy-opt-out" }

    static func association(for userID: String) -> String {
        SHA256.hash(data: Data(userID.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@MainActor
protocol PushAuthorizationClient {
    func currentStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
}

struct SystemPushAuthorizationClient: PushAuthorizationClient {
    nonisolated init() {}

    func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
}

@MainActor
protocol PushDeviceRegistrationClient {
    func register()
    func unregister()
}

struct SystemPushDeviceRegistrationClient: PushDeviceRegistrationClient {
    nonisolated init() {}

    func register() { UIApplication.shared.registerForRemoteNotifications() }
    func unregister() { UIApplication.shared.unregisterForRemoteNotifications() }
}

@MainActor
protocol PushNotificationSleeper {
    func sleep(for duration: Duration) async throws
}

struct SystemPushNotificationSleeper: PushNotificationSleeper {
    nonisolated init() {}

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

enum PushRecoveryPolicy {
    // A bounded burst repairs temporary registration/transport failures without
    // polling forever. A later foreground or explicit retry starts a new burst.
    static let delays: [Duration] = [.seconds(5), .seconds(15), .seconds(60), .seconds(300), .seconds(300)]

    static func delay(attempt: Int) -> Duration? {
        guard delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }
}

enum PushStartupConsentPolicy {
    private static let pendingKey = "push-notifications-startup-consent-pending"

    static func recordGranted(in defaults: UserDefaults, environment: AppServiceEnvironment = .production) {
        defaults.set(true, forKey: environment.storageKey(pendingKey))
    }

    static func clear(in defaults: UserDefaults, environment: AppServiceEnvironment = .production) {
        defaults.removeObject(forKey: environment.storageKey(pendingKey))
    }

    /// The startup grant can enable exactly one eligible account, never a
    /// subsequent account on this installation or a previously disabled one.
    static func consume(
        for userID: String,
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String,
        environment: AppServiceEnvironment = .production
    ) {
        guard defaults.bool(forKey: environment.storageKey(pendingKey)) else { return }
        clear(in: defaults, environment: environment)
        guard !PushNotificationPreferencePolicy.hasExplicitChoice(
            in: defaults,
            preferenceKey: preferenceKey,
            associationKey: associationKey,
            userID: userID
        ) else { return }
        PushNotificationPreferencePolicy.setEnabled(
            true, for: userID, in: defaults,
            preferenceKey: preferenceKey, associationKey: associationKey
        )
    }
}

enum PushSessionEligibility {
    static func userID(
        profile: FanProfile?,
        hasSessionToken: Bool,
        credentialAccessAllowed: Bool = true,
        now: Date = Date()
    ) -> String? {
        guard credentialAccessAllowed,
              hasSessionToken,
              let profile,
              profile.sessionExpiresAt > now,
              profile.accountStatus == .pending || profile.accountStatus == .active,
              !profile.requiresAccountSetup,
              !profile.requiresPasswordChange,
              !profile.requiresAppleRegistration,
              profile.hasRequiredDouyinID,
              profile.hasConsistentAccountSetupState else { return nil }
        return profile.userID
    }
}

struct PushSynchronizationTaskID: Hashable {
    let serviceEnvironment: AppServiceEnvironment
    let userID: String?
    let fanSessionGeneration: UInt64
    let deviceRegistrationGeneration: UInt64
    let canUnbindPushDevice: Bool
    let appleCredentialAccessState: FanAppleCredentialAccessState

    init(
        userID: String?,
        fanSessionGeneration: UInt64,
        deviceRegistrationGeneration: UInt64,
        canUnbindPushDevice: Bool = false,
        appleCredentialAccessState: FanAppleCredentialAccessState = .notRequired,
        environment: AppServiceEnvironment = .production
    ) {
        self.serviceEnvironment = environment
        self.userID = userID
        self.fanSessionGeneration = fanSessionGeneration
        self.deviceRegistrationGeneration = deviceRegistrationGeneration
        self.canUnbindPushDevice = canUnbindPushDevice
        self.appleCredentialAccessState = appleCredentialAccessState
    }
}

enum PushAccountTransitionPolicy {
    static func requiresRegistrationReset(
        previousUserID: String?,
        currentUserID: String?
    ) -> Bool {
        previousUserID != currentUserID
    }
}

enum PushBindingRefreshPolicy {
    static let maximumBindingAge: TimeInterval = 24 * 60 * 60

    static func needsRefresh(boundAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(boundAt) >= maximumBindingAge
    }

    static func delayUntilRefresh(boundAt: Date, now: Date = Date()) -> TimeInterval {
        max(1, maximumBindingAge - now.timeIntervalSince(boundAt))
    }
}

enum PushDeviceRegistrationState {
    case inactive
    case connecting
    case ready
    case failed
    case requiresSignIn
}

@MainActor
protocol PushNotificationAccount: AnyObject {
    var serviceEnvironment: AppServiceEnvironment { get }
    var pushEligibleUserID: String? { get }
    var pushSessionGeneration: UInt64 { get }
    var hasPushEligibleSession: Bool { get }
    var hasPushUnbindingSession: Bool { get }
    func bindPushDevice(deviceToken: String) async throws
    func unbindPushDevice() async throws
}

extension FanAccountStore: PushNotificationAccount {}

@MainActor
final class PushNotificationCoordinator: ObservableObject {
    let serviceEnvironment: AppServiceEnvironment
    private(set) var isRetired = false
    private var preferenceKey: String { serviceEnvironment.storageKey("push-notifications-enabled") }
    private var associationKey: String { serviceEnvironment.storageKey("push-notifications-enabled-user") }

    @Published private(set) var registrationGeneration: UInt64 = 0
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isUpdatingPreference = false
    @Published private(set) var shouldPresentAuthorizationRationale = false
    @Published private(set) var deviceRegistrationState: PushDeviceRegistrationState = .inactive
    @Published private(set) var pendingNotification: PendingFanNotification?
    @Published private(set) var notificationReceiptGeneration: UInt64 = 0

    private struct BoundContext: Equatable {
        let userID: String
        let deviceToken: String
        let fanSessionGeneration: UInt64
        let boundAt: Date

        func matches(
            userID: String,
            deviceToken: String,
            fanSessionGeneration: UInt64
        ) -> Bool {
            self.userID == userID
                && self.deviceToken == deviceToken
                && self.fanSessionGeneration == fanSessionGeneration
        }
    }

    private let authorizationClient: any PushAuthorizationClient
    private let registrationClient: any PushDeviceRegistrationClient
    private let sleeper: any PushNotificationSleeper
    private let defaults: UserDefaults
    private let registrationTimeout: Duration
    private var deviceToken: String?
    private var boundContext: BoundContext?
    private var isSynchronizing = false
    private var needsSynchronization = false
    private var isAcceptingDeviceTokens = false
    private var accountUserID: String?
    private var isRequestingAuthorization = false
    private var preferenceGeneration: UInt64 = 0
    private var bindingRefreshTask: Task<Void, Never>?
    private var registrationTimeoutTask: Task<Void, Never>?
    private var registrationTimeoutSession: UInt64?
    private weak var registrationAccount: (any PushNotificationAccount)?
    private struct RecoveryContext: Equatable {
        let userID: String
        let sessionGeneration: UInt64
        let preferenceGeneration: UInt64
    }
    private var recoveryContext: RecoveryContext?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempt = 0
    private var recoveryGeneration: UInt64 = 0

    init(
        authorizationClient: any PushAuthorizationClient = SystemPushAuthorizationClient(),
        defaults: UserDefaults = .standard,
        registrationTimeout: Duration = .seconds(30),
        registrationClient: any PushDeviceRegistrationClient = SystemPushDeviceRegistrationClient(),
        sleeper: any PushNotificationSleeper = SystemPushNotificationSleeper(),
        environment: AppServiceEnvironment = .production
    ) {
        self.serviceEnvironment = environment
        self.authorizationClient = authorizationClient
        self.registrationClient = registrationClient
        self.sleeper = sleeper
        self.defaults = defaults
        self.registrationTimeout = registrationTimeout
        // No account identity is known during initialization. The preference is
        // restored only after it is matched to the same signed-in fan account.
        notificationsEnabled = false
    }

    func receive(deviceToken data: Data) {
        guard !isRetired else { return }
        guard isAcceptingDeviceTokens else {
            deviceToken = nil
            boundContext = nil
            return
        }
        guard let encoded = PushDeviceTokenPolicy.encodedToken(from: data) else {
            deviceToken = nil
            boundContext = nil
            return
        }
        // iOS may deliver the same token again after each registration call.
        // Publishing only real changes prevents a register/callback task loop.
        guard deviceToken != encoded else { return }
        deviceToken = encoded
        boundContext = nil
        registrationGeneration &+= 1
    }

    func receiveNotification(userInfo: [AnyHashable: Any], opened: Bool) {
        guard !isRetired else { return }
        guard let rawID = userInfo["notificationID"] as? String,
              let id = FanNotificationValidation.canonicalID(rawID) else { return }
        notificationReceiptGeneration &+= 1
        if opened { pendingNotification = PendingFanNotification(id: id) }
    }

    func clearPendingNotification() { pendingNotification = nil }

    func registrationFailed() {
        guard !isRetired else { return }
        guard isAcceptingDeviceTokens, let account = registrationAccount,
              deviceRegistrationState != .requiresSignIn,
              recoveryContext == currentRecoveryContext(for: account) else { return }
        deviceToken = nil
        boundContext = nil
        deviceRegistrationState = .failed
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
        scheduleRecovery(for: account)
    }

    /// Read-only form of the startup request's guards, so the app can explain
    /// the system prompt first without changing when that prompt is allowed.
    func needsStartupAuthorization() async -> Bool {
        guard !isRetired, !isRequestingAuthorization else { return false }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-skip-startup-notification-authorization-for-testing") {
            return false
        }
#endif
        let status = await authorizationClient.currentStatus()
        let hasOptedOut = defaults.object(forKey: preferenceKey) != nil
            && !defaults.bool(forKey: preferenceKey)
        return !isRetired && status == .notDetermined && !hasOptedOut
    }

    /// System permission is app-wide and may be requested before login. Device
    /// registration and server binding still require an eligible fan session.
    func requestStartupAuthorizationIfNeeded() async {
        guard !isRetired else { return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-skip-startup-notification-authorization-for-testing") {
            return
        }
#endif
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        let generation = preferenceGeneration
        defer {
            isRequestingAuthorization = false
            registrationGeneration &+= 1
        }
        authorizationStatus = await authorizationClient.currentStatus()
        guard !isRetired else { return }
        // A stored false is an explicit opt-out, including Build 45's legacy
        // opt-out without an account association. Never undo it on upgrade.
        let hasOptedOut = defaults.object(forKey: preferenceKey) != nil
            && !defaults.bool(forKey: preferenceKey)
        guard authorizationStatus == .notDetermined, !hasOptedOut else { return }
        do {
            let granted = try await authorizationClient.requestAuthorization()
            authorizationStatus = await authorizationClient.currentStatus()
            if granted, !isRetired, generation == preferenceGeneration {
                PushStartupConsentPolicy.recordGranted(in: defaults, environment: serviceEnvironment)
            }
        } catch {
            // An interrupted request can be retried on a later foreground;
            // without an affirmative result no account is opted in.
        }
    }

    /// After system notification consent and a completed fan login,
    /// binds the volatile APNs token through that same protected fan session.
    /// The token is deliberately never written to UserDefaults, Keychain or logs.
    func synchronize(with account: any PushNotificationAccount) async {
        await synchronize(with: account, resetRecoveryBudget: true)
    }

    private func synchronize(
        with account: any PushNotificationAccount,
        resetRecoveryBudget: Bool
    ) async {
        // Each coordinator owns one immutable workspace. Reject a mismatched
        // account before changing preferences, registering, binding or unbinding.
        guard !isRetired, account.serviceEnvironment == serviceEnvironment else { return }
        guard let eligibleUserID = account.pushEligibleUserID else {
            accountContextDidChange(to: nil)
            shouldPresentAuthorizationRationale = false
            await stopDeliveryLocally(unbindingFrom: account)
            return
        }
        let sessionGeneration = account.pushSessionGeneration
        accountContextDidChange(to: eligibleUserID)
        let context = currentRecoveryContext(for: account)
        if resetRecoveryBudget || recoveryContext != context {
            cancelRecovery(resetAttempts: true)
        }
        recoveryContext = context
        registrationAccount = account
        guard !isSynchronizing else {
            needsSynchronization = true
            return
        }
        isSynchronizing = true
        defer {
            isSynchronizing = false
            if needsSynchronization {
                needsSynchronization = false
                Task { await self.synchronize(with: account, resetRecoveryBudget: false) }
            }
        }

        guard !isRequestingAuthorization else { return }
        let status = await authorizationClient.currentStatus()
        guard !isRetired, !Task.isCancelled,
              account.pushEligibleUserID == eligibleUserID,
              account.pushSessionGeneration == sessionGeneration else { return }
        authorizationStatus = status
        PushNotificationPreferencePolicy.enableAfterSystemAuthorization(
            status, for: eligibleUserID, in: defaults,
            preferenceKey: preferenceKey, associationKey: associationKey
        )
        if status == .authorized || status == .provisional || status == .ephemeral {
            PushStartupConsentPolicy.consume(
                for: eligibleUserID, in: defaults,
                preferenceKey: preferenceKey, associationKey: associationKey,
                environment: serviceEnvironment
            )
            notificationsEnabled = PushNotificationPreferencePolicy.isEnabled(
                in: defaults, preferenceKey: preferenceKey,
                associationKey: associationKey, userID: eligibleUserID
            )
        } else if status == .denied {
            PushStartupConsentPolicy.clear(in: defaults, environment: serviceEnvironment)
        }
        guard notificationsEnabled else {
            await stopDeliveryLocally(unbindingFrom: account)
            return
        }
        switch status {
        case .notDetermined:
            shouldPresentAuthorizationRationale = true
        case .authorized, .provisional, .ephemeral:
            shouldPresentAuthorizationRationale = false
            guard notificationsEnabled else { return }
            isAcceptingDeviceTokens = true
            beginDeviceRegistration(for: account)
            await bindIfPossible(to: account)
        case .denied:
            shouldPresentAuthorizationRationale = false
            await stopDeliveryLocally(unbindingFrom: account)
        @unknown default:
            shouldPresentAuthorizationRationale = false
            await stopDeliveryLocally(unbindingFrom: account)
        }
    }

    func requestAuthorizationAfterRationale(for account: any PushNotificationAccount) async {
        guard !isRetired, account.serviceEnvironment == serviceEnvironment else { return }
        shouldPresentAuthorizationRationale = false
        guard !isRequestingAuthorization, notificationsEnabled,
              let userID = account.pushEligibleUserID,
              accountUserID == userID else { return }
        let sessionGeneration = account.pushSessionGeneration
        isRequestingAuthorization = true
        defer {
            isRequestingAuthorization = false
            registrationGeneration &+= 1
        }
        do {
            let granted = try await authorizationClient.requestAuthorization()
            let status = await authorizationClient.currentStatus()
            guard !isRetired, account.pushEligibleUserID == userID,
                  account.pushSessionGeneration == sessionGeneration,
                  accountUserID == userID else { return }
            authorizationStatus = status
            if granted, notificationsEnabled, account.hasPushEligibleSession {
                isAcceptingDeviceTokens = true
                beginDeviceRegistration(for: account)
                await bindIfPossible(to: account)
            } else {
                await stopDeliveryLocally(unbindingFrom: account)
            }
        } catch {
            guard !isRetired, account.pushEligibleUserID == userID,
                  account.pushSessionGeneration == sessionGeneration else { return }
            // Notification permission is optional and never blocks App access,
            // but an indeterminate result must stop delivery fail closed.
            await stopDeliveryLocally(unbindingFrom: account)
        }
    }

    func dismissAuthorizationRationale() {
        shouldPresentAuthorizationRationale = false
    }

    func accountContextDidChange(to userID: String?) {
        guard !isRetired else { return }
        guard accountUserID != userID else { return }
        // A tap received before any account is known may wait for first login;
        // a tap associated with an existing account must never follow a switch.
        if accountUserID != nil { clearPendingNotification() }
        accountUserID = userID
        notificationsEnabled = PushNotificationPreferencePolicy.isEnabled(
            in: defaults,
            preferenceKey: preferenceKey,
            associationKey: associationKey,
            userID: userID
        )
        registrationClient.unregister()
        isAcceptingDeviceTokens = false
        deviceToken = nil
        boundContext = nil
        deviceRegistrationState = .inactive
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
        shouldPresentAuthorizationRationale = false
        cancelRecovery(resetAttempts: true)
        recoveryContext = nil
        registrationAccount = nil
    }

    func forgetSessionBinding() {
        boundContext = nil
        deviceRegistrationState = .inactive
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
        cancelRecovery(resetAttempts: true)
    }

    func removePreferenceForDeletedAccount(_ userID: String) {
        guard !isRetired else { return }
        PushNotificationPreferencePolicy.remove(
            for: userID, in: defaults, preferenceKey: preferenceKey, associationKey: associationKey
        )
        if accountUserID == userID { accountContextDidChange(to: nil) }
    }

    func setNotificationsEnabled(_ enabled: Bool, for account: any PushNotificationAccount) async {
        guard !isRetired, account.serviceEnvironment == serviceEnvironment else { return }
        guard let userID = account.pushEligibleUserID else { return }
        accountContextDidChange(to: userID)
        preferenceGeneration &+= 1
        PushStartupConsentPolicy.clear(in: defaults, environment: serviceEnvironment)
        if !enabled { shouldPresentAuthorizationRationale = false }
        PushNotificationPreferencePolicy.setEnabled(
            enabled, for: userID, in: defaults,
            preferenceKey: preferenceKey, associationKey: associationKey
        )
        guard notificationsEnabled != enabled else {
            if enabled { await synchronize(with: account) }
            return
        }
        isUpdatingPreference = true
        notificationsEnabled = enabled
        if enabled {
            await synchronize(with: account)
        } else {
            shouldPresentAuthorizationRationale = false
            await stopDeliveryLocally(unbindingFrom: account)
        }
        isUpdatingPreference = false
    }

    private func bindIfPossible(to account: any PushNotificationAccount) async {
        guard !isRetired, account.serviceEnvironment == serviceEnvironment else { return }
        guard let userID = account.pushEligibleUserID,
              let deviceToken,
              PushDeviceTokenPolicy.isValid(deviceToken) else { return }
        let sessionGeneration = account.pushSessionGeneration
        if let boundContext,
           boundContext.matches(
            userID: userID,
            deviceToken: deviceToken,
            fanSessionGeneration: sessionGeneration
           ),
           !PushBindingRefreshPolicy.needsRefresh(boundAt: boundContext.boundAt) {
            scheduleBindingRefresh(
                for: account,
                after: PushBindingRefreshPolicy.delayUntilRefresh(
                    boundAt: boundContext.boundAt
                )
            )
            return
        }
        do {
            try await account.bindPushDevice(deviceToken: deviceToken)
            guard !isRetired, account.pushEligibleUserID == userID,
                  account.pushSessionGeneration == sessionGeneration,
                  self.deviceToken == deviceToken,
                  notificationsEnabled else {
                needsSynchronization = true
                return
            }
            boundContext = BoundContext(
                userID: userID,
                deviceToken: deviceToken,
                fanSessionGeneration: sessionGeneration,
                boundAt: Date()
            )
            deviceRegistrationState = .ready
            cancelRecovery(resetAttempts: true)
            registrationTimeoutTask?.cancel()
            registrationTimeoutTask = nil
            scheduleBindingRefresh(for: account)
        } catch {
            guard !isRetired, account.pushEligibleUserID == userID,
                  account.pushSessionGeneration == sessionGeneration,
                  notificationsEnabled else { return }
            registrationTimeoutTask?.cancel()
            registrationTimeoutTask = nil
            bindingRefreshTask?.cancel()
            bindingRefreshTask = nil
            if case FanAccountError.sessionExpired = error {
                deviceRegistrationState = .requiresSignIn
                cancelRecovery(resetAttempts: true)
                return
            }
            deviceRegistrationState = .failed
            scheduleRecovery(for: account)
        }
    }

    private func stopDeliveryLocally(unbindingFrom account: any PushNotificationAccount) async {
        guard !isRetired, account.serviceEnvironment == serviceEnvironment else { return }
        // Reject callbacks before the network await so a late APNs registration
        // can never resurrect a denied, revoked, switched or signed-out context.
        isAcceptingDeviceTokens = false
        registrationClient.unregister()
        deviceToken = nil
        boundContext = nil
        deviceRegistrationState = .inactive
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
        cancelRecovery(resetAttempts: true)
        registrationAccount = nil
        recoveryContext = nil
        guard account.hasPushUnbindingSession else { return }
        // All local cleanup must happen before suspension. An older unbind
        // response must not erase a newer account's successful binding. The
        // server orders requests by the installation's monotonic generation.
        try? await account.unbindPushDevice()
    }

    private func beginDeviceRegistration(for account: any PushNotificationAccount) {
        guard !isRetired, account.serviceEnvironment == serviceEnvironment else { return }
        let hasCurrentBinding = boundContext.map {
            $0.userID == account.pushEligibleUserID
                && $0.fanSessionGeneration == account.pushSessionGeneration
                && !PushBindingRefreshPolicy.needsRefresh(boundAt: $0.boundAt)
        } ?? false
        if !hasCurrentBinding {
            deviceRegistrationState = .connecting
            if registrationTimeoutSession != account.pushSessionGeneration {
                registrationTimeoutTask?.cancel()
                registrationTimeoutTask = nil
            }
            if registrationTimeoutTask == nil {
                let userID = account.pushEligibleUserID
                let sessionGeneration = account.pushSessionGeneration
                registrationTimeoutSession = sessionGeneration
                registrationTimeoutTask = Task { [weak self, weak account] in
                    guard let timeout = self?.registrationTimeout else { return }
                    guard let sleeper = self?.sleeper else { return }
                    do { try await sleeper.sleep(for: timeout) } catch { return }
                    guard !Task.isCancelled, let self, !self.isRetired, let account,
                          account.pushEligibleUserID == userID,
                          account.pushSessionGeneration == sessionGeneration,
                          self.deviceRegistrationState == .connecting else { return }
                    self.deviceRegistrationState = .failed
                    self.registrationTimeoutTask = nil
                    self.scheduleRecovery(for: account)
                }
            }
        }
        registrationAccount = account
        registrationClient.register()
    }

    private func currentRecoveryContext(for account: any PushNotificationAccount) -> RecoveryContext? {
        guard !isRetired, account.serviceEnvironment == serviceEnvironment,
              let userID = account.pushEligibleUserID else { return nil }
        return RecoveryContext(
            userID: userID,
            sessionGeneration: account.pushSessionGeneration,
            preferenceGeneration: preferenceGeneration
        )
    }

    private func cancelRecovery(resetAttempts: Bool) {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryGeneration &+= 1
        if resetAttempts { recoveryAttempt = 0 }
    }

    private func scheduleRecovery(for account: any PushNotificationAccount) {
        guard !isRetired, notificationsEnabled, isAcceptingDeviceTokens,
              accountUserID == account.pushEligibleUserID,
              let context = currentRecoveryContext(for: account),
              recoveryContext == context,
              deviceRegistrationState != .requiresSignIn,
              recoveryTask == nil,
              let delay = PushRecoveryPolicy.delay(attempt: recoveryAttempt) else { return }
        recoveryAttempt += 1
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        recoveryTask = Task { [weak self, weak account] in
            guard let sleeper = self?.sleeper else { return }
            do { try await sleeper.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, let account,
                  self.recoveryGeneration == generation,
                  self.recoveryContext == context,
                  self.currentRecoveryContext(for: account) == context,
                  self.notificationsEnabled, self.isAcceptingDeviceTokens else { return }
            self.recoveryTask = nil
            await self.synchronize(with: account, resetRecoveryBudget: false)
        }
    }

    private func scheduleBindingRefresh(
        for account: any PushNotificationAccount,
        after delay: TimeInterval = PushBindingRefreshPolicy.maximumBindingAge
    ) {
        bindingRefreshTask?.cancel()
        bindingRefreshTask = Task { [weak self, weak account] in
            guard let sleeper = self?.sleeper else { return }
            do {
                try await sleeper.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, !self.isRetired, let account else { return }
            await self.synchronize(with: account, resetRecoveryBudget: false)
        }
    }

    /// Terminal shutdown for a discarded workspace. Do not erase the user's
    /// stored preference, but invalidate every old callback and retry task.
    func retire() {
        guard !isRetired else { return }
        isRetired = true
        preferenceGeneration &+= 1
        accountUserID = nil
        notificationsEnabled = false
        isAcceptingDeviceTokens = false
        deviceToken = nil
        boundContext = nil
        registrationAccount = nil
        recoveryContext = nil
        needsSynchronization = false
        deviceRegistrationState = .inactive
        shouldPresentAuthorizationRationale = false
        clearPendingNotification()
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
        cancelRecovery(resetAttempts: true)
        registrationClient.unregister()
    }
}

/// APNs is app-wide, but authenticated inboxes and bindings are workspace-owned.
/// Legacy unlabelled payloads belong to production only; a payload never changes
/// the selected workspace or supplies credentials for reading its message.
@MainActor
final class PushNotificationRouter {
    static let shared = PushNotificationRouter()
    private(set) weak var activeCoordinator: PushNotificationCoordinator?
    private var hasActivated = false
    private var startupMessage: (environment: AppServiceEnvironment, id: String)?

    func activate(_ coordinator: PushNotificationCoordinator) {
        guard !coordinator.isRetired else { return }
        if activeCoordinator !== coordinator { activeCoordinator?.retire() }
        activeCoordinator = coordinator
        hasActivated = true
        if let message = startupMessage, message.environment == coordinator.serviceEnvironment {
            coordinator.receiveNotification(userInfo: ["notificationID": message.id], opened: true)
        }
        startupMessage = nil
    }

    func deactivate(_ coordinator: PushNotificationCoordinator) {
        guard activeCoordinator === coordinator else { return }
        activeCoordinator = nil
    }

    func receive(deviceToken: Data) { activeCoordinator?.receive(deviceToken: deviceToken) }
    func registrationFailed() { activeCoordinator?.registrationFailed() }

    @discardableResult
    func receiveNotification(userInfo: [AnyHashable: Any], opened: Bool) -> Bool {
        let environment: AppServiceEnvironment
        if let raw = userInfo["serviceEnvironment"] {
            guard let raw = raw as? String, let parsed = AppServiceEnvironment(rawValue: raw) else { return false }
            environment = parsed
        } else {
            environment = .production
        }
        guard let id = userInfo["notificationID"] as? String,
              FanNotificationValidation.canonicalID(id) != nil else { return false }
        if !hasActivated, activeCoordinator == nil, opened {
            startupMessage = (environment, id)
            return true
        }
        guard let coordinator = activeCoordinator, !coordinator.isRetired,
              coordinator.serviceEnvironment == environment else { return false }
        coordinator.receiveNotification(userInfo: userInfo, opened: opened)
        return true
    }
}

@MainActor
final class YishuApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotificationRouter.shared.receive(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationRouter.shared.registrationFailed()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let accepted = PushNotificationRouter.shared.receiveNotification(
            userInfo: notification.request.content.userInfo, opened: false
        )
        return accepted ? [.banner, .list, .sound] : []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Only a canonical opaque ID crosses into navigation. Title/body/URL
        // payload fields are never trusted as the authenticated message detail.
        PushNotificationRouter.shared.receiveNotification(
            userInfo: response.notification.request.content.userInfo, opened: true
        )
    }
}
