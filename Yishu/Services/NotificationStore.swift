import UIKit
import UserNotifications

@MainActor
final class NotificationStore: ObservableObject {
    static let shared = NotificationStore()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var errorMessage: String?
    @Published var preferences: NotificationPreferences {
        didSet {
            UserDefaults.standard.set(preferences.newWorks, forKey: Self.worksKey)
            UserDefaults.standard.set(preferences.live, forKey: Self.liveKey)
            Task { await uploadCurrentRegistrationIfPossible() }
        }
    }

    private static let worksKey = "fan.notifications.newWorks"
    private static let liveKey = "fan.notifications.live"
    private weak var communityStore: FanCommunityStore?
    private var currentDeviceToken: String?

    private init() {
        let defaults = UserDefaults.standard
        preferences = NotificationPreferences(
            newWorks: defaults.object(forKey: Self.worksKey) as? Bool ?? true,
            live: defaults.object(forKey: Self.liveKey) as? Bool ?? true
        )
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    func configure(communityStore: FanCommunityStore) {
        self.communityStore = communityStore
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        if isAuthorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            await refreshAuthorizationStatus()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
                errorMessage = nil
            } else {
                errorMessage = "通知权限尚未开启，可稍后在系统设置中允许。"
            }
        } catch {
            errorMessage = "暂时无法申请通知权限，请稍后再试。"
        }
    }

    func didReceiveDeviceToken(_ data: Data) {
        currentDeviceToken = data.map { String(format: "%02x", $0) }.joined()
        Task { await uploadCurrentRegistrationIfPossible() }
    }

    func didFailToRegister(_ error: Error) {
        errorMessage = "设备暂时无法连接 Apple 推送服务。"
    }

    private func uploadCurrentRegistrationIfPossible() async {
        guard isAuthorized,
              let token = currentDeviceToken,
              let communityStore else { return }
        do {
            try await communityStore.registerPushToken(
                token,
                preferences: preferences,
                environment: Self.apnsEnvironment
            )
            errorMessage = nil
        } catch {
            errorMessage = "通知偏好暂未同步，App 会在下次启动时重试。"
        }
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}

final class YishuAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
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
        Task { @MainActor in
            NotificationStore.shared.didReceiveDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            NotificationStore.shared.didFailToRegister(error)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let value = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: value),
              FanCommunityLinkPolicy.isTrusted(url) else { return }
        Task { @MainActor in
            UIApplication.shared.open(url)
        }
    }
}
