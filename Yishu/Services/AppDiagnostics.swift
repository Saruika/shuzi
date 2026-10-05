import Foundation
import MetricKit
import OSLog

/// Privacy-preserving runtime diagnostics for TestFlight and production.
/// Only aggregate counts and numeric error categories are logged; URLs,
/// account names, administrator credentials and user content are never logged.
final class AppDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = AppDiagnostics()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cn.com.shuzijun.yishu",
        category: "AppDiagnostics"
    )
    private var isStarted = false

    private override init() {
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        MXMetricManager.shared.add(self)

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: kCFBundleVersionKey as String
        ) as? String ?? "unknown"
        logger.notice(
            "Runtime diagnostics enabled for version \(version, privacy: .public) build \(build, privacy: .public)"
        )
    }

    func recordCatalogRefresh(
        succeeded: Bool,
        portfolioCount: Int = 0,
        imageCount: Int = 0,
        error: Error? = nil
    ) {
        if succeeded {
            logger.info(
                "Catalog refresh succeeded: portfolios=\(portfolioCount, privacy: .public) images=\(imageCount, privacy: .public)"
            )
        } else {
            let code = error.map(DiagnosticsSanitizer.networkErrorCode) ?? 0
            logger.error(
                "Catalog refresh failed: networkCategory=\(code, privacy: .public); cached content retained"
            )
        }
    }


    func recordImageLoadFailure(category: Int) {
        logger.error(
            "Artwork image load failed after bounded retries: category=\(category, privacy: .public)"
        )
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        logger.notice(
            "MetricKit performance payloads received: count=\(payloads.count, privacy: .public)"
        )
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashCount = payloads.reduce(0) { $0 + ($1.crashDiagnostics?.count ?? 0) }
        let hangCount = payloads.reduce(0) { $0 + ($1.hangDiagnostics?.count ?? 0) }
        let cpuCount = payloads.reduce(0) { $0 + ($1.cpuExceptionDiagnostics?.count ?? 0) }
        let diskWriteCount = payloads.reduce(0) {
            $0 + ($1.diskWriteExceptionDiagnostics?.count ?? 0)
        }
        logger.error(
            "MetricKit diagnostics received: payloads=\(payloads.count, privacy: .public) crashes=\(crashCount, privacy: .public) hangs=\(hangCount, privacy: .public) cpu=\(cpuCount, privacy: .public) diskWrites=\(diskWriteCount, privacy: .public)"
        )
    }
}

enum DiagnosticsSanitizer {
    /// Returns only a numeric URL loading category. The error description can
    /// contain a complete URL and therefore must not enter unified logging.
    static func networkErrorCode(_ error: Error) -> Int {
        (error as? URLError)?.code.rawValue ?? 0
    }
}
