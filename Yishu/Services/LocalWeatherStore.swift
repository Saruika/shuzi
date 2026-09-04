import CoreLocation
import MapKit
import Observation
import WeatherKit

enum LocalWeatherPhase: Equatable {
    case idle
    case locating
    case loading
    case ready
    case denied
    case unavailable
}

@MainActor
@Observable
final class LocalWeatherStore: NSObject {
    private(set) var locationText = "位置与天气"
    private(set) var weatherText = "轻点开启"
    private(set) var symbolName = "location.fill"
    private(set) var phase: LocalWeatherPhase = .idle
    private(set) var attributionMarkURL: URL?
    private(set) var attributionLegalURL = WeatherAttributionPresentation.officialLegalURL
    private(set) var weatherProviderName = WeatherAttributionPresentation.defaultProviderName

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let weatherService = WeatherService.shared
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var locationNameTask: Task<Void, Never>?
    @ObservationIgnored private var locationWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var weatherWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var attributionTask: Task<Void, Never>?
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var lastUpdated: Date?
    @ObservationIgnored private var activeRequestID = 0
    @ObservationIgnored private var usesSimulatedWeather = false
    @ObservationIgnored private var attributionDidResolve = false

    var needsSettings: Bool {
        phase == .denied
    }

    var accessibilitySummary: String {
        "当前位置：\(locationText)，天气：\(weatherText)"
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-simulate-ready-weather-for-visual-testing"
        ) || ProcessInfo.processInfo.environment[
            "YISHU_SIMULATE_READY_WEATHER_FOR_VISUAL_TESTING"
        ] == "1" {
            usesSimulatedWeather = true
            locationText = "杭州"
            weatherText = "晴 24°"
            symbolName = "sun.max.fill"
            phase = .ready
            attributionDidResolve = true
        }
#endif
    }

    deinit {
        weatherTask?.cancel()
        locationNameTask?.cancel()
        locationWatchdogTask?.cancel()
        weatherWatchdogTask?.cancel()
        attributionTask?.cancel()
    }

    func activate() {
        guard !usesSimulatedWeather else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            showUnavailableLocation()
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            // A tap is an explicit retry. It must also recover a request whose
            // callback was lost while the app or network changed state.
            requestLocation(force: true)
        case .denied, .restricted:
            showDenied()
        @unknown default:
            showUnavailableLocation()
        }
    }

    func refreshIfAuthorized() {
        guard !usesSimulatedWeather else { return }
        guard locationManager.authorizationStatus == .authorizedWhenInUse
                || locationManager.authorizationStatus == .authorizedAlways else { return }

        if let lastUpdated,
           Date().timeIntervalSince(lastUpdated) < 10 * 60,
           phase == .ready {
            return
        }
        requestLocation()
    }

    private func requestLocation(force: Bool = false) {
        guard !usesSimulatedWeather else { return }
        guard force || (phase != .locating && phase != .loading) else { return }
        beginNewRequest()
        let requestID = activeRequestID
        phase = .locating
        locationText = "正在定位"
        weatherText = "获取天气"
        symbolName = "location.fill"
        locationManager.requestLocation()

        locationWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
                guard let self,
                      !Task.isCancelled,
                      self.activeRequestID == requestID,
                      self.phase == .locating else { return }

                if let cachedLocation = self.locationManager.location,
                   Self.isUsable(cachedLocation) {
                    self.loadWeather(for: cachedLocation)
                    return
                }

                self.weatherText = "正在重试"
                self.locationManager.requestLocation()

                try await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled,
                      self.activeRequestID == requestID,
                      self.phase == .locating else { return }
                AppDiagnostics.shared.recordWeatherUpdate(
                    succeeded: false,
                    errorCode: WeatherFailureCategory.locationTimedOut.rawValue
                )
                self.showUnavailableLocation()
            } catch { }
        }
    }

    private func loadWeather(for location: CLLocation) {
        if let lastLocation,
           let lastUpdated,
           location.distance(from: lastLocation) < 5_000,
           Date().timeIntervalSince(lastUpdated) < 10 * 60,
           phase == .ready {
            return
        }

        beginNewRequest()
        let requestID = activeRequestID
        phase = .loading
        locationText = "当前位置"
        weatherText = "获取天气"

        // Reverse geocoding is helpful context, but it must never block the
        // forecast. MapKit and WeatherKit therefore run independently.
        locationNameTask = Task { [weak self] in
            guard let self else { return }
            let resolvedLocation = await self.locationName(for: location)
            guard !Task.isCancelled,
                  self.activeRequestID == requestID else { return }
            self.locationText = resolvedLocation
        }

        weatherWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
                guard let self,
                      !Task.isCancelled,
                      self.activeRequestID == requestID,
                      self.phase == .loading else { return }
                self.weatherTask?.cancel()
                self.weatherText = "天气连接超时"
                self.symbolName = "arrow.clockwise"
                self.phase = .unavailable
                AppDiagnostics.shared.recordWeatherUpdate(
                    succeeded: false,
                    errorCode: WeatherFailureCategory.weatherTimedOut.rawValue
                )
            } catch { }
        }

        weatherTask = Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await self.currentWeatherWithRetry(for: location)
                guard !Task.isCancelled else {
                    return
                }
                guard self.activeRequestID == requestID else {
                    return
                }

                let temperature = current.temperature.converted(to: .celsius).value
                self.weatherText = "\(WeatherPresentation.conditionText(for: current.condition)) \(Int(temperature.rounded()))°"
                self.symbolName = current.symbolName
                self.lastLocation = location
                self.lastUpdated = Date()
                self.phase = .ready
                self.weatherWatchdogTask?.cancel()
                self.loadAttribution(for: requestID)
                AppDiagnostics.shared.recordWeatherUpdate(succeeded: true)
            } catch {
                guard !Task.isCancelled,
                      self.activeRequestID == requestID else { return }
                self.weatherWatchdogTask?.cancel()
                self.weatherText = WeatherFailurePresentation.message(for: error)
                self.symbolName = "arrow.clockwise"
                self.phase = .unavailable
                AppDiagnostics.shared.recordWeatherUpdate(
                    succeeded: false,
                    errorCode: WeatherFailurePresentation.diagnosticCode(for: error)
                )
            }
        }
    }

    private func currentWeatherWithRetry(for location: CLLocation) async throws -> CurrentWeather {
        do {
            return try await weatherService.weather(for: location, including: .current)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(700))
            return try await weatherService.weather(for: location, including: .current)
        }
    }

    private func loadAttribution(for requestID: Int) {
        attributionTask?.cancel()
        attributionTask = Task { [weak self] in
            guard let self else { return }
            let attribution = try? await self.weatherService.attribution
            guard !Task.isCancelled,
                  self.activeRequestID == requestID else { return }

            // The official Apple attribution page is usable immediately and
            // remains the stable destination if WeatherKit's optional
            // attribution metadata is unavailable. This prevents the legal
            // entry from getting stuck behind an indefinite loading state.
            self.weatherProviderName = WeatherAttributionPresentation.providerName(
                attribution?.serviceName
            )
            self.attributionMarkURL = attribution?.combinedMarkDarkURL
            self.attributionLegalURL = WeatherAttributionPresentation.legalURL(
                from: attribution?.legalPageURL
            )
            self.attributionDidResolve = true
            self.attributionTask = nil
        }
    }

    private func locationName(for location: CLLocation) async -> String {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                return "当前位置"
            }
            request.preferredLocale = Locale(identifier: "zh-Hans")
            guard let item = try? await request.mapItems.first,
                  let address = item.addressRepresentations else {
                return "当前位置"
            }
            return address.cityName ?? address.cityWithContext ?? address.regionName ?? "当前位置"
        }
        return await legacyLocationName(for: location)
    }

    @available(iOS, introduced: 17.0, obsoleted: 26.0)
    private func legacyLocationName(for location: CLLocation) async -> String {
        let geocoder = CLGeocoder()
        let placemark = try? await geocoder.reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "zh-Hans")
        ).first
        return placemark?.locality
            ?? placemark?.subAdministrativeArea
            ?? placemark?.administrativeArea
            ?? placemark?.country
            ?? "当前位置"
    }

    private func showDenied() {
        beginNewRequest()
        phase = .denied
        locationText = "位置未开启"
        weatherText = "前往设置"
        symbolName = "location.slash"
    }

    private func showUnavailableLocation() {
        beginNewRequest()
        phase = .unavailable
        locationText = "无法定位"
        weatherText = "轻点重试"
        symbolName = "location.slash"
    }

    private func beginNewRequest() {
        activeRequestID &+= 1
        weatherTask?.cancel()
        locationNameTask?.cancel()
        locationWatchdogTask?.cancel()
        weatherWatchdogTask?.cancel()
        attributionTask?.cancel()
        weatherTask = nil
        locationNameTask = nil
        locationWatchdogTask = nil
        weatherWatchdogTask = nil
        attributionTask = nil
        attributionDidResolve = false
        attributionMarkURL = nil
        attributionLegalURL = WeatherAttributionPresentation.officialLegalURL
        weatherProviderName = WeatherAttributionPresentation.defaultProviderName
    }

    private static func isUsable(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 100_000
            && abs(location.timestamp.timeIntervalSinceNow) <= 30 * 60
    }
}

enum WeatherFailureCategory: Int {
    case unknown = 0
    case permissionDenied = 101
    case weatherUnknown = 102
    case locationTimedOut = 201
    case weatherTimedOut = 202
    case urlLoadingBase = 1_000
}

enum WeatherAttributionPresentation {
    static let defaultProviderName = "Apple Weather"
    static let officialLegalURL = AppURL.make(
        "https://developer.apple.com/weatherkit/data-source-attribution/"
    )

    static func providerName(_ candidate: String?) -> String {
        let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultProviderName : value
    }

    static func legalURL(from candidate: URL?) -> URL {
        guard let candidate,
              candidate.scheme?.lowercased() == "https",
              candidate.user == nil,
              candidate.password == nil,
              candidate.port == nil || candidate.port == 443,
              let host = candidate.host?.lowercased(),
              host == "apple.com" || host.hasSuffix(".apple.com") else {
            return officialLegalURL
        }
        return candidate
    }
}

enum WeatherFailurePresentation {
    static func message(for error: Error) -> String {
        if let weatherError = error as? WeatherError {
            switch weatherError {
            case .permissionDenied:
                return "天气服务未授权"
            case .unknown:
                break
            @unknown default:
                break
            }
        }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "网络未连接"
        }
        return "天气暂不可用"
    }

    static func diagnosticCode(for error: Error) -> Int {
        if let weatherError = error as? WeatherError {
            switch weatherError {
            case .permissionDenied:
                return WeatherFailureCategory.permissionDenied.rawValue
            case .unknown:
                return WeatherFailureCategory.weatherUnknown.rawValue
            @unknown default:
                return WeatherFailureCategory.unknown.rawValue
            }
        }
        if let urlError = error as? URLError {
            return WeatherFailureCategory.urlLoadingBase.rawValue + abs(urlError.code.rawValue)
        }
        return WeatherFailureCategory.unknown.rawValue
    }
}

enum WeatherPresentation {
    static func compactSummary(location: String, weather: String) -> String {
        "\(conciseLocationText(location)) · \(weather)"
    }

    static func conciseLocationText(_ location: String) -> String {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "当前位置" }

        for suffix in ["特别行政区", "自治州", "地区", "市"] where trimmed.hasSuffix(suffix) {
            let concise = String(trimmed.dropLast(suffix.count))
            if !concise.isEmpty { return concise }
        }
        return trimmed
    }

    static func conditionText(for condition: WeatherCondition) -> String {
        switch condition {
        case .blizzard: "暴风雪"
        case .blowingDust: "沙尘"
        case .blowingSnow: "风吹雪"
        case .breezy: "微风"
        case .clear: "晴"
        case .cloudy: "阴"
        case .drizzle: "毛毛雨"
        case .flurries: "小雪"
        case .foggy: "雾"
        case .freezingDrizzle: "冻毛毛雨"
        case .freezingRain: "冻雨"
        case .frigid: "严寒"
        case .hail: "冰雹"
        case .haze: "霾"
        case .heavyRain: "大雨"
        case .heavySnow: "大雪"
        case .hot: "炎热"
        case .hurricane: "飓风"
        case .isolatedThunderstorms: "局部雷雨"
        case .mostlyClear: "晴间多云"
        case .mostlyCloudy: "多云"
        case .partlyCloudy: "局部多云"
        case .rain: "有雨"
        case .scatteredThunderstorms: "分散雷雨"
        case .sleet: "雨夹雪"
        case .smoky: "烟雾"
        case .snow: "有雪"
        case .strongStorms: "强风暴"
        case .sunFlurries: "晴间小雪"
        case .sunShowers: "晴间阵雨"
        case .thunderstorms: "雷雨"
        case .tropicalStorm: "热带风暴"
        case .windy: "大风"
        case .wintryMix: "雨雪混合"
        @unknown default: condition.description
        }
    }
}

extension LocalWeatherStore: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocation()
        case .denied, .restricted:
            showDenied()
        case .notDetermined:
            break
        @unknown default:
            showUnavailableLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations
            .filter(Self.isUsable)
            .max(by: { $0.timestamp < $1.timestamp }) else {
            guard phase == .locating else { return }
            weatherText = "正在重试"
            return
        }
        loadWeather(for: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        switch (error as? CLError)?.code {
        case .denied:
            showDenied()
        case .locationUnknown:
            // Core Location reports this as a transient condition. Keep the
            // watchdog alive so it can retry and eventually leave loading.
            guard phase == .locating else { return }
            locationText = "正在定位"
            weatherText = "正在重试"
            symbolName = "location.fill"
        default:
            showUnavailableLocation()
        }
    }
}
