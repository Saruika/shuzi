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
        guard let userID,
              defaults.object(forKey: preferenceKey) != nil,
              defaults.bool(forKey: preferenceKey),
              let storedAssociation = defaults.string(forKey: associationKey) else {
            return false
        }
        return storedAssociation == association(for: userID)
    }

    static func setEnabled(
        _ enabled: Bool,
        for userID: String,
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String
    ) {
        defaults.set(enabled, forKey: preferenceKey)
        defaults.set(association(for: userID), forKey: associationKey)
    }

    static func hasExplicitChoice(
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String,
        userID: String
    ) -> Bool {
        guard defaults.object(forKey: preferenceKey) != nil else { return false }
        if let storedAssociation = defaults.string(forKey: associationKey) {
            return storedAssociation == association(for: userID)
        }
        // Build 45 removed the association when someone explicitly switched
        // notifications off. Respect that existing opt-out after upgrading.
        return !defaults.bool(forKey: preferenceKey)
    }

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

enum PushStartupConsentPolicy {
    private static let pendingKey = "push-notifications-startup-consent-pending"

    static func recordGranted(in defaults: UserDefaults) {
        defaults.set(true, forKey: pendingKey)
    }

    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingKey)
    }

    /// The startup grant can enable exactly one eligible account, never a
    /// subsequent account on this installation or a previously disabled one.
    static func consume(
        for userID: String,
        in defaults: UserDefaults,
        preferenceKey: String,
        associationKey: String
    ) {
        guard defaults.bool(forKey: pendingKey) else { return }
        clear(in: defaults)
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
        appleCredentialAccessState: FanAppleCredentialAccessState = .notRequired
    ) {
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
    static let shared = PushNotificationCoordinator()
    private static let preferenceKey = "push-notifications-enabled"
    private static let associationKey = "push-notifications-enabled-user"

    @Published private(set) var registrationGeneration: UInt64 = 0
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isUpdatingPreference = false
    @Published private(set) var shouldPresentAuthorizationRationale = false
    @Published private(set) var deviceRegistrationState: PushDeviceRegistrationState = .inactive

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

    init(
        authorizationClient: any PushAuthorizationClient = SystemPushAuthorizationClient(),
        defaults: UserDefaults = .standard,
        registrationTimeout: Duration = .seconds(30)
    ) {
        self.authorizationClient = authorizationClient
        self.defaults = defaults
        self.registrationTimeout = registrationTimeout
        // No account identity is known during initialization. The preference is
        // restored only after it is matched to the same signed-in fan account.
        notificationsEnabled = false
    }

    func receive(deviceToken data: Data) {
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

    func registrationFailed() {
        deviceToken = nil
        boundContext = nil
        if isAcceptingDeviceTokens { deviceRegistrationState = .failed }
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
    }

    /// System permission is app-wide and may be requested before login. Device
    /// registration and server binding still require an eligible fan session.
    func requestStartupAuthorizationIfNeeded() async {
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
        // A stored false is an explicit opt-out, including Build 45's legacy
        // opt-out without an account association. Never undo it on upgrade.
        let hasOptedOut = defaults.object(forKey: Self.preferenceKey) != nil
            && !defaults.bool(forKey: Self.preferenceKey)
        guard authorizationStatus == .notDetermined, !hasOptedOut else { return }
        do {
            let granted = try await authorizationClient.requestAuthorization()
            authorizationStatus = await authorizationClient.currentStatus()
            if granted, generation == preferenceGeneration {
                PushStartupConsentPolicy.recordGranted(in: defaults)
            }
        } catch {
            // An interrupted request can be retried on a later foreground;
            // without an affirmative result no account is opted in.
        }
    }

    /// After explicit notification consent and a completed fan login,
    /// binds the volatile APNs token through that same protected fan session.
    /// The token is deliberately never written to UserDefaults, Keychain or logs.
    func synchronize(with account: any PushNotificationAccount) async {
        guard let eligibleUserID = account.pushEligibleUserID else {
            accountContextDidChange(to: nil)
            shouldPresentAuthorizationRationale = false
            await stopDeliveryLocally(unbindingFrom: account)
            return
        }
        let sessionGeneration = account.pushSessionGeneration
        accountContextDidChange(to: eligibleUserID)
        guard !isSynchronizing else {
            needsSynchronization = true
            return
        }
        isSynchronizing = true
        defer {
            isSynchronizing = false
            if needsSynchronization {
                needsSynchronization = false
                Task { await self.synchronize(with: account) }
            }
        }

        guard !isRequestingAuthorization else { return }
        let status = await authorizationClient.currentStatus()
        guard !Task.isCancelled,
              account.pushEligibleUserID == eligibleUserID,
              account.pushSessionGeneration == sessionGeneration else { return }
        authorizationStatus = status
        if status == .authorized || status == .provisional || status == .ephemeral {
            PushStartupConsentPolicy.consume(
                for: eligibleUserID, in: defaults,
                preferenceKey: Self.preferenceKey, associationKey: Self.associationKey
            )
            notificationsEnabled = PushNotificationPreferencePolicy.isEnabled(
                in: defaults, preferenceKey: Self.preferenceKey,
                associationKey: Self.associationKey, userID: eligibleUserID
            )
        } else if status == .denied {
            PushStartupConsentPolicy.clear(in: defaults)
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
            guard account.pushEligibleUserID == userID,
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
            guard account.pushEligibleUserID == userID,
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
        guard accountUserID != userID else { return }
        accountUserID = userID
        notificationsEnabled = PushNotificationPreferencePolicy.isEnabled(
            in: defaults,
            preferenceKey: Self.preferenceKey,
            associationKey: Self.associationKey,
            userID: userID
        )
        UIApplication.shared.unregisterForRemoteNotifications()
        isAcceptingDeviceTokens = false
        deviceToken = nil
        boundContext = nil
        deviceRegistrationState = .inactive
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
        shouldPresentAuthorizationRationale = false
    }

    func forgetSessionBinding() {
        boundContext = nil
        deviceRegistrationState = .inactive
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
    }

    func setNotificationsEnabled(_ enabled: Bool, for account: any PushNotificationAccount) async {
        guard let userID = account.pushEligibleUserID else { return }
        accountContextDidChange(to: userID)
        preferenceGeneration &+= 1
        PushStartupConsentPolicy.clear(in: defaults)
        if !enabled { shouldPresentAuthorizationRationale = false }
        PushNotificationPreferencePolicy.setEnabled(
            enabled, for: userID, in: defaults,
            preferenceKey: Self.preferenceKey, associationKey: Self.associationKey
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
            guard account.pushEligibleUserID == userID,
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
            registrationTimeoutTask?.cancel()
            registrationTimeoutTask = nil
            scheduleBindingRefresh(for: account)
        } catch {
            guard account.pushEligibleUserID == userID,
                  account.pushSessionGeneration == sessionGeneration,
                  notificationsEnabled else { return }
            registrationTimeoutTask?.cancel()
            registrationTimeoutTask = nil
            if case FanAccountError.sessionExpired = error {
                deviceRegistrationState = .requiresSignIn
                bindingRefreshTask?.cancel()
                bindingRefreshTask = nil
                return
            }
            deviceRegistrationState = .failed
            // Foreground/session reconciliation retries without logging the token.
            scheduleBindingRefresh(for: account, after: 5 * 60)
        }
    }

    private func stopDeliveryLocally(unbindingFrom account: any PushNotificationAccount) async {
        // Reject callbacks before the network await so a late APNs registration
        // can never resurrect a denied, revoked, switched or signed-out context.
        isAcceptingDeviceTokens = false
        UIApplication.shared.unregisterForRemoteNotifications()
        deviceToken = nil
        boundContext = nil
        deviceRegistrationState = .inactive
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
        guard account.hasPushUnbindingSession else { return }
        // All local cleanup must happen before suspension. An older unbind
        // response must not erase a newer account's successful binding. The
        // server orders requests by the installation's monotonic generation.
        try? await account.unbindPushDevice()
    }

    private func beginDeviceRegistration(for account: any PushNotificationAccount) {
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
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard !Task.isCancelled, let self, let account,
                          account.pushEligibleUserID == userID,
                          account.pushSessionGeneration == sessionGeneration,
                          self.deviceRegistrationState == .connecting else { return }
                    self.deviceRegistrationState = .failed
                    self.registrationTimeoutTask = nil
                }
            }
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func scheduleBindingRefresh(
        for account: any PushNotificationAccount,
        after delay: TimeInterval = PushBindingRefreshPolicy.maximumBindingAge
    ) {
        bindingRefreshTask?.cancel()
        bindingRefreshTask = Task { [weak self, weak account] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let account else { return }
            await self.synchronize(with: account)
        }
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
        PushNotificationCoordinator.shared.receive(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationCoordinator.shared.registrationFailed()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Notification payloads never choose a URL or privileged destination.
        // Until the App has a protected message inbox, tapping safely activates
        // the existing authenticated interface and performs no custom routing.
    }
}
