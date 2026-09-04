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
        if enabled {
            defaults.set(association(for: userID), forKey: associationKey)
        } else {
            defaults.removeObject(forKey: associationKey)
        }
    }

    private static func association(for userID: String) -> String {
        SHA256.hash(data: Data(userID.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

    private let notificationCenter: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var deviceToken: String?
    private var boundContext: BoundContext?
    private var isSynchronizing = false
    private var needsSynchronization = false
    private var isAcceptingDeviceTokens = false
    private var accountUserID: String?
    private var bindingRefreshTask: Task<Void, Never>?

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
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
    }

    /// Requests notification permission only after a completed fan login, then
    /// binds the volatile APNs token through that same protected fan session.
    /// The token is deliberately never written to UserDefaults, Keychain or logs.
    func synchronize(with account: FanAccountStore) async {
        let eligibleUserID = account.pushEligibleUserID
        guard eligibleUserID != nil else {
            await stopDeliveryLocally(unbindingFrom: account)
            accountContextDidChange(to: nil)
            shouldPresentAuthorizationRationale = false
            return
        }
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

        let settings = await notificationCenter.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        guard notificationsEnabled else {
            await stopDeliveryLocally(unbindingFrom: account)
            return
        }
        switch settings.authorizationStatus {
        case .notDetermined:
            shouldPresentAuthorizationRationale = true
        case .authorized, .provisional, .ephemeral:
            shouldPresentAuthorizationRationale = false
            guard notificationsEnabled else { return }
            isAcceptingDeviceTokens = true
            UIApplication.shared.registerForRemoteNotifications()
            await bindIfPossible(to: account)
        case .denied:
            shouldPresentAuthorizationRationale = false
            await stopDeliveryLocally(unbindingFrom: account)
        @unknown default:
            shouldPresentAuthorizationRationale = false
            await stopDeliveryLocally(unbindingFrom: account)
        }
    }

    func requestAuthorizationAfterRationale(for account: FanAccountStore) async {
        shouldPresentAuthorizationRationale = false
        guard notificationsEnabled else { return }
        guard account.hasPushEligibleSession else {
            await stopDeliveryLocally(unbindingFrom: account)
            return
        }
        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            authorizationStatus = (await notificationCenter.notificationSettings())
                .authorizationStatus
            if granted, notificationsEnabled, account.hasPushEligibleSession {
                isAcceptingDeviceTokens = true
                UIApplication.shared.registerForRemoteNotifications()
                await bindIfPossible(to: account)
            } else {
                await stopDeliveryLocally(unbindingFrom: account)
            }
        } catch {
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
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
        shouldPresentAuthorizationRationale = false
    }

    func forgetSessionBinding() {
        boundContext = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
    }

    func setNotificationsEnabled(_ enabled: Bool, for account: FanAccountStore) async {
        guard let userID = account.pushEligibleUserID else { return }
        guard notificationsEnabled != enabled else {
            if enabled { await synchronize(with: account) }
            return
        }
        isUpdatingPreference = true
        notificationsEnabled = enabled
        PushNotificationPreferencePolicy.setEnabled(
            enabled,
            for: userID,
            in: defaults,
            preferenceKey: Self.preferenceKey,
            associationKey: Self.associationKey
        )
        if enabled {
            await synchronize(with: account)
        } else {
            shouldPresentAuthorizationRationale = false
            await stopDeliveryLocally(unbindingFrom: account)
        }
        isUpdatingPreference = false
    }

    private func bindIfPossible(to account: FanAccountStore) async {
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
            scheduleBindingRefresh(for: account)
        } catch {
            // Foreground/session reconciliation retries without logging the token.
            scheduleBindingRefresh(for: account, after: 5 * 60)
        }
    }

    private func unbindIfPossible(from account: FanAccountStore) async {
        guard account.hasPushUnbindingSession else {
            boundContext = nil
            return
        }
        let contextBeforeRequest = boundContext
        do {
            try await account.unbindPushDevice()
            if boundContext == contextBeforeRequest {
                boundContext = nil
            }
        } catch {
            // Keep the context so a later foreground reconciliation can retry.
        }
    }

    private func stopDeliveryLocally(unbindingFrom account: FanAccountStore) async {
        // Reject callbacks before the network await so a late APNs registration
        // can never resurrect a denied, revoked, switched or signed-out context.
        isAcceptingDeviceTokens = false
        UIApplication.shared.unregisterForRemoteNotifications()
        deviceToken = nil
        boundContext = nil
        bindingRefreshTask?.cancel()
        bindingRefreshTask = nil
        await unbindIfPossible(from: account)
        // unbindIfPossible deliberately retains a failed context for ordinary
        // reconciliation; local stop is stricter and always forgets it.
        boundContext = nil
    }

    private func scheduleBindingRefresh(
        for account: FanAccountStore,
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
