import Foundation

/// A separate, deliberately small contract. Never decode the member manifest
/// here or reuse its cache: a preview entitlement is not permission to publish.
struct PublicExperienceManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let contentAudience: String
    let updatedAt: Date
    let albums: [PublicExperienceAlbum]
}

struct PublicExperienceAlbum: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    let title: String
    let subtitle: String
    let images: [PublicExperienceImage]
}

struct PublicExperienceImage: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    let url: URL
    let altText: String
}

enum PublicExperiencePolicy {
    static func request(environment: AppServiceEnvironment) -> URLRequest {
        var request = URLRequest(url: environment.apiRoot.appending(path: "shuzijun/v1/public-experience"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 12
        // No bearer, installation ID, cookies, reviewer identity or fan state.
        return request
    }

    static func isValid(_ manifest: PublicExperienceManifest, environment: AppServiceEnvironment) -> Bool {
        let timestamp = manifest.updatedAt.timeIntervalSince1970
        guard manifest.schemaVersion == 1, manifest.contentAudience == "public",
              timestamp.isFinite, (0...4_102_444_800).contains(timestamp),
              manifest.albums.count <= 30,
              Set(manifest.albums.map(\.id)).count == manifest.albums.count else { return false }
        return manifest.albums.allSatisfy { album in
            album.id > 0 && validText(album.title, limit: 160, required: true)
                && validText(album.subtitle, limit: 400)
                && (1...6).contains(album.images.count)
                && Set(album.images.map(\.id)).count == album.images.count
                && album.images.allSatisfy { image in
                    image.id > 0 && validText(image.altText, limit: 400)
                        && isImageURL(image.url, environment: environment)
                }
        }
    }

    private static func validText(_ text: String, limit: Int, required: Bool = false) -> Bool {
        text.count <= limit && (!required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private static func isImageURL(_ url: URL, environment: AppServiceEnvironment) -> Bool {
        guard ContentSecurityPolicy.isTrustedMediaURL(url, environment: environment),
              url.path.hasPrefix("/wp-content/uploads/"), url.query == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let encoded = components.percentEncodedPath.lowercased()
        return !["%2e", "%2f", "%5c", "%25"].contains(where: encoded.contains)
            && !url.path.contains("\\") && !url.path.split(separator: "/").contains("..")
    }
}

enum PublicExperienceNetwork {
    static func fetch(_ request: URLRequest) async throws -> PublicExperienceManifest {
        let session = SecureURLSessionFactory.make(requestTimeout: 12, resourceTimeout: 20, waitsForConnectivity: false)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        let maximumBytes = 256 * 1024
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == request.url, AppNetworkSecurityPolicy.isJSONMIMEType(http.mimeType),
              AppNetworkSecurityPolicy.permitsResponseLength(http.expectedContentLength,
                                                             maximumBytes: Int64(maximumBytes)) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PublicExperienceManifest.self, from: data)
    }
}

@MainActor
final class PublicExperienceStore: ObservableObject {
    @Published private(set) var albums: [PublicExperienceAlbum] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    let environment: AppServiceEnvironment
    private let loader: @Sendable (URLRequest) async throws -> PublicExperienceManifest
    private var generation = UUID()

    init(environment: AppServiceEnvironment = .production,
         loader: @escaping @Sendable (URLRequest) async throws -> PublicExperienceManifest = { try await PublicExperienceNetwork.fetch($0) }) {
        self.environment = environment
        self.loader = loader
    }

    func load() async {
        let expected = UUID()
        generation = expected
        isLoading = true
        errorMessage = nil
        do {
            let manifest = try await loader(PublicExperiencePolicy.request(environment: environment))
            try Task.checkCancellation()
            guard generation == expected else { return }
            guard PublicExperiencePolicy.isValid(manifest, environment: environment) else {
                throw URLError(.cannotParseResponse)
            }
            albums = manifest.albums
            hasLoaded = true
            isLoading = false
        } catch {
            guard generation == expected else { return }
            // Never retain a withdrawn selection after a failed refresh and
            // never fall back to member metadata, assets or original uploads.
            albums = []
            isLoading = false
            hasLoaded = false
            errorMessage = Task.isCancelled ? nil : "暂时无法加载公开精选，请检查网络后重试。审批专区的权限不会因此改变。"
        }
    }

    func invalidate() {
        generation = UUID()
        albums = []
        isLoading = false
        hasLoaded = false
        errorMessage = nil
    }
}

#if DEBUG
extension PublicExperienceStore {
    static func forPreview(environment: AppServiceEnvironment) -> PublicExperienceStore {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-fail-public-experience-for-testing") {
            return PublicExperienceStore(environment: environment) { _ in throw URLError(.notConnectedToInternet) }
        }
        if arguments.contains("-use-public-experience-fixture-for-testing") {
            return PublicExperienceStore(environment: environment) { _ in
                PublicExperienceManifest(schemaVersion: 1, contentAudience: "public", updatedAt: Date(), albums: [
                    PublicExperienceAlbum(id: 901, title: "东方光影", subtitle: "公开精选测试", images: [
                        PublicExperienceImage(id: 9001, url: AppURL.make("https://\(environment.mediaHost)/wp-content/uploads/public-test-1.jpg"), altText: "几何测试图一"),
                        PublicExperienceImage(id: 9002, url: AppURL.make("https://\(environment.mediaHost)/wp-content/uploads/public-test-2.jpg"), altText: "几何测试图二")
                    ])
                ])
            }
        }
        return PublicExperienceStore(environment: environment)
    }
}
#endif
