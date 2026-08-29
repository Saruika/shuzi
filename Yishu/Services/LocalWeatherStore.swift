import CoreLocation
import MapKit

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

    private let locationManager = CLLocationManager()
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
        weatherTask = Task { [weak self] in
            guard let self else { return }
            phase = .loading
            let resolvedLocation = await locationName(for: location)
            guard !Task.isCancelled else { return }
            locationText = resolvedLocation

            do {
                let current = try await fetchWeather(for: location)
                guard !Task.isCancelled else { return }

                weatherText = "\(current.conditionText) \(Int(current.temperature.rounded()))°"
                symbolName = current.symbolName
                attributionMarkURL = nil
                attributionLegalURL = URL(string: "https://docs.api.met.no/doc/License.html")
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

    private func fetchWeather(for location: CLLocation) async throws -> WeatherSnapshot {
        var components = URLComponents(
            string: "https://api.met.no/weatherapi/locationforecast/2.0/compact"
        )!
        components.queryItems = [
            // Weather does not need street-level coordinates. Quantize before
            // anything leaves the device (roughly 1 km at this latitude).
            URLQueryItem(name: "lat", value: String(format: "%.2f", location.coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.2f", location.coordinate.longitude)),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue(
            "Yishu-iOS/1.0 www.shuzijun.com.cn 369476120@qq.com",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 2 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }

        let forecast = try JSONDecoder().decode(MetWeatherResponse.self, from: data)
        guard let point = forecast.properties.timeseries.first else {
            throw URLError(.zeroByteResource)
        }
        let symbolCode = point.data.nextOneHour?.summary.symbolCode
            ?? point.data.nextSixHours?.summary.symbolCode
            ?? "cloudy"
        let presentation = weatherPresentation(for: symbolCode)
        return WeatherSnapshot(
            temperature: point.data.instant.details.airTemperature,
            conditionText: presentation.text,
            symbolName: presentation.symbol
        )
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

    private func weatherPresentation(for rawCode: String) -> (text: String, symbol: String) {
        let code = rawCode
            .replacingOccurrences(of: "_day", with: "")
            .replacingOccurrences(of: "_night", with: "")
            .replacingOccurrences(of: "_polartwilight", with: "")

        if code == "clearsky" { return ("晴", "sun.max.fill") }
        if code == "fair" { return ("晴间多云", "cloud.sun.fill") }
        if code == "partlycloudy" { return ("多云", "cloud.sun.fill") }
        if code == "cloudy" { return ("阴", "cloud.fill") }
        if code == "fog" { return ("雾", "cloud.fog.fill") }
        if code.contains("thunder") { return ("雷雨", "cloud.bolt.rain.fill") }
        if code.contains("snow") { return ("有雪", "cloud.snow.fill") }
        if code.contains("sleet") { return ("雨雪", "cloud.sleet.fill") }
        if code.contains("rain") {
            return code.contains("heavy")
                ? ("大雨", "cloud.heavyrain.fill")
                : ("有雨", "cloud.rain.fill")
        }
        return ("多云", "cloud.fill")
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

private struct WeatherSnapshot {
    let temperature: Double
    let conditionText: String
    let symbolName: String
}

private struct MetWeatherResponse: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let timeseries: [TimePoint]
    }

    struct TimePoint: Decodable {
        let data: WeatherData
    }

    struct WeatherData: Decodable {
        let instant: Instant
        let nextOneHour: Period?
        let nextSixHours: Period?

        enum CodingKeys: String, CodingKey {
            case instant
            case nextOneHour = "next_1_hours"
            case nextSixHours = "next_6_hours"
        }
    }

    struct Instant: Decodable {
        let details: Details
    }

    struct Details: Decodable {
        let airTemperature: Double

        enum CodingKeys: String, CodingKey {
            case airTemperature = "air_temperature"
        }
    }

    struct Period: Decodable {
        let summary: Summary
    }

    struct Summary: Decodable {
        let symbolCode: String

        enum CodingKeys: String, CodingKey {
            case symbolCode = "symbol_code"
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
        if (error as? CLError)?.code == .denied {
            showDenied()
        } else {
            showUnavailableLocation()
        }
    }
}
