import Foundation

/// Small host-side check; compile with the two production network source files.
@main
struct ServiceEnvironmentSmoke {
    static func main() {
        var checks = 0
        func check(_ value: Bool) {
            precondition(value, "Service environment contract failed")
            checks += 1
        }
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            check(environment.allowsAPIURL(environment.apiRoot))
            check(environment.allowsMediaUploadURL(environment.mediaUploadURL))
            check(!environment.allowsAPIURL(other.apiRoot))
            check(!environment.allowsMediaUploadURL(other.mediaUploadURL))
            check(!environment.allowsAPIURL(nil))
            check(!environment.allowsMediaUploadURL(nil))
            for raw in [
                "http://\(environment.apiHost)/wp-json",
                "https://\(environment.apiHost).example.invalid/wp-json",
                "https://\(environment.apiHost):444/wp-json",
                "https://other@\(environment.apiHost)/wp-json",
                "https://\(environment.apiHost)/wp-json#fragment",
                "https://\(environment.apiHost)/wp-json-extra",
                "https://\(environment.apiHost)/wp-json/%2e%2e/wp-admin",
                "https://\(environment.apiHost)/wp-json/a%2fb",
                "https://\(environment.apiHost)/wp-json/%252e%252e/wp-admin",
            ] {
                check(!environment.allowsAPIURL(URL(string: raw)))
            }
        }
        for key in ["cn.com.shuzijun.yishu.fan-account", "portfolio-cache", "favorites", "recently-viewed"] {
            check(AppServiceEnvironment.production.storageKey(key) == key)
            check(AppServiceEnvironment.review.storageKey(key) == "review." + key)
        }
        print("Service environment contract: \(checks) checks passed")
    }
}
