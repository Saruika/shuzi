import CoreLocation
import MapKit
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
final class LocalWeatherStore: NSObject, ObservableObject {
    @Published private(set) var locationText = "位置与天气"
    @Published private(set) var weatherText = "轻点开启"
    @Published private(set) var symbolName = "location.fill"
    @Published private(set) var phase: LocalWeatherPhase = .idle
    @Published private(set) var attributionMarkURL: URL?
    @Published private(set) var attributionLegalURL: URL?
    @Published private(set) var weatherProviderName = "Apple Weather"

    private let locationManager = CLLocationManager()
    private let weatherService = WeatherService.shared
    private var weatherTask: Task<Void, Never>?
    private var lastLocation: CLLocation?
    private var lastUpdated: Date?

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
    }

    deinit {
        weatherTask?.cancel()
    }

    func activate() {
        guard CLLocationManager.locationServicesEnabled() else {
            showUnavailableLocation()
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocation()
        case .denied, .restricted:
            showDenied()
        @unknown default:
            showUnavailableLocation()
        }
    }

    func refreshIfAuthorized() {
        guard locationManager.authorizationStatus == .authorizedWhenInUse
                || locationManager.authorizationStatus == .authorizedAlways else { return }

        if let lastUpdated,
           Date().timeIntervalSince(lastUpdated) < 10 * 60,
           phase == .ready {
            return
        }
        requestLocation()
    }

    private func requestLocation() {
        guard phase != .locating, phase != .loading else { return }
        phase = .locating
        locationText = "正在定位"
        weatherText = "获取天气"
        symbolName = "location.fill"
        locationManager.requestLocation()
    }

    private func loadWeather(for location: CLLocation) {
        if let lastLocation,
           let lastUpdated,
           location.distance(from: lastLocation) < 5_000,
           Date().timeIntervalSince(lastUpdated) < 10 * 60,
           phase == .ready {
            return
        }

        weatherTask?.cancel()
        phase = .loading
        weatherTask = Task { [weak self] in
            guard let self else { return }
            let resolvedLocation = await locationName(for: location)
            guard !Task.isCancelled else { return }
            locationText = resolvedLocation

            do {
                async let currentWeather = weatherService.weather(for: location, including: .current)
                async let weatherAttribution = weatherService.attribution
                let (current, attribution) = try await (currentWeather, weatherAttribution)
                guard !Task.isCancelled else { return }

                let temperature = current.temperature.converted(to: .celsius).value
                weatherText = "\(WeatherPresentation.conditionText(for: current.condition)) \(Int(temperature.rounded()))°"
                symbolName = current.symbolName
                weatherProviderName = attribution.serviceName
                attributionMarkURL = attribution.combinedMarkDarkURL
                attributionLegalURL = attribution.legalPageURL
                lastLocation = location
                lastUpdated = Date()
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                weatherText = "天气暂不可用"
                symbolName = "exclamationmark.triangle"
                phase = .unavailable
            }
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
        weatherTask?.cancel()
        phase = .denied
        locationText = "位置未开启"
        weatherText = "前往设置"
        symbolName = "location.slash"
    }

    private func showUnavailableLocation() {
        weatherTask?.cancel()
        phase = .unavailable
        locationText = "无法定位"
        weatherText = "轻点重试"
        symbolName = "location.slash"
    }
}

enum WeatherPresentation {
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
            .filter({ $0.horizontalAccuracy >= 0 })
            .max(by: { $0.timestamp < $1.timestamp }) else {
            showUnavailableLocation()
            return
        }
        loadWeather(for: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        switch (error as? CLError)?.code {
        case .denied:
            showDenied()
        case .locationUnknown:
            // Core Location can emit this temporary error immediately after a
            // valid update. Do not replace an in-flight or completed forecast.
            guard phase != .loading, phase != .ready else { return }
            locationText = "正在定位"
            weatherText = "请稍候"
            symbolName = "location.fill"
        default:
            showUnavailableLocation()
        }
    }
}
