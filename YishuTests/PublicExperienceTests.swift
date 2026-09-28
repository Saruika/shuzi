import Foundation
import XCTest
@testable import Yishu

private final class ChunkFixtureRegistry: @unchecked Sendable {
    struct Reply: Sendable {
        var chunks: [Data] = []
        var headers: [String: String] = [:]
        var failure: URLError?
        var staysOpen = false
        var onStart: @Sendable () -> Void = {}
    }
    private let lock = NSLock()
    private var replies: [URL: Reply] = [:]
    func insert(_ reply: Reply, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        replies[url] = reply
    }
    func take(_ url: URL) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        return replies.removeValue(forKey: url)
    }
}

private final class ChunkFixtureProtocol: URLProtocol {
    static let registry = ChunkFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let reply = Self.registry.take(url),
              let response = HTTPURLResponse(url: url, statusCode: 200,
                  httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"].merging(
                    reply.headers, uniquingKeysWith: { _, value in value })) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        reply.onStart()
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !reply.staysOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

final class BoundedResponseLoaderTests: XCTestCase {
    func testUserAgentIncludesEachRequestSource() {
        for source in AppNetworkIdentity.Source.allCases {
            XCTAssertEqual(AppNetworkIdentity.userAgent(for: source),
                           "\(AppNetworkIdentity.userAgent) (\(source.rawValue))")
        }
        XCTAssertEqual(Set(AppNetworkIdentity.Source.allCases.map {
            AppNetworkIdentity.userAgent(for: $0)
        }).count, 5)
    }

    // Exercise the real URLSession delegate decision and redirect counter with
    // the same policy used in production; no external requests are performed.
    func testRedirectDelegateRejectsSixthHongguoRedirect() throws {
        let url = try XCTUnwrap(URL(string: "https://novelquickapp.com/s/test"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302,
                                                    httpVersion: nil, headerFields: nil))
        let loader = BoundedResponseLoader(maximumBytes: 100, validate: { _ in },
            allowsRedirect: { DramaLinkPolicy.allowsRedirect($0, count: $1) })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        for count in 1...6 {
            var called = false
            loader.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: url)) { accepted in
                called = true
                if count <= 5 { XCTAssertEqual(accepted?.url, url) }
                else { XCTAssertNil(accepted, "第六次跳转必须被拒绝") }
            }
            XCTAssertTrue(called)
        }
    }

    func testRedirectDelegateRejectsNonHongguoDestination() throws {
        let origin = try XCTUnwrap(URL(string: "https://novelquickapp.com/s/test"))
        let response = try XCTUnwrap(HTTPURLResponse(url: origin, statusCode: 302,
                                                    httpVersion: nil, headerFields: nil))
        let loader = BoundedResponseLoader(maximumBytes: 100, validate: { _ in },
            allowsRedirect: { DramaLinkPolicy.allowsRedirect($0, count: $1) })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin)
        for destination in ["https://example.com/", "https://novelquickapp.com.example.com/"] {
            let url = try XCTUnwrap(URL(string: destination))
            var called = false
            loader.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: url)) { accepted in
                called = true
                XCTAssertNil(accepted, "非红果域名不得跟随")
            }
            XCTAssertTrue(called)
        }
    }

    func testUserAgentUsesActualVersionWithoutUntrustedHeaderCharacters() {
        XCTAssertEqual(AppNetworkIdentity.userAgent(version: "1.5"), "Yishu-iOS/1.5")
        XCTAssertEqual(AppNetworkIdentity.userAgent(version: "2.0.1"), "Yishu-iOS/2.0.1")
        for invalid in [nil, "", "1.5\r\nInjected: true", "１.５"] {
            XCTAssertEqual(AppNetworkIdentity.userAgent(version: invalid), "Yishu-iOS/unknown")
        }
    }
    private func request(_ reply: ChunkFixtureRegistry.Reply) throws -> URLRequest {
        let url = try XCTUnwrap(URL(string: "https://fixture.invalid/\(UUID().uuidString)"))
        ChunkFixtureProtocol.registry.insert(reply, for: url)
        return URLRequest(url: url)
    }

    private func configuration() -> URLSessionConfiguration {
        let config = SecureURLSessionFactory.configuration(
            requestTimeout: 2, resourceTimeout: 3, waitsForConnectivity: false)
        config.protocolClasses = [ChunkFixtureProtocol.self]
        return config
    }

    func testMultipleChunksAtExactLimitArePreserved() async throws {
        let chunks = (0..<4).map { Data(repeating: UInt8($0), count: 65_536) }
        let request = try request(.init(chunks: chunks))
        let (data, response) = try await BoundedResponseLoader.data(
            for: request, configuration: configuration(), maximumBytes: 262_144, validate: { _ in })
        XCTAssertEqual(data, chunks.reduce(into: Data()) { $0.append($1) })
        XCTAssertEqual(response.url, request.url)
    }

    func testUnknownLengthOverLimitIsRejectedDuringChunks() async throws {
        let request = try request(.init(chunks: [Data([1, 2]), Data([3, 4]), Data([5, 6])]))
        do {
            _ = try await BoundedResponseLoader.data(
                for: request, configuration: configuration(), maximumBytes: 5, validate: { _ in })
            XCTFail("Must reject bytes beyond limit")
        } catch let error as URLError { XCTAssertEqual(error.code, .dataLengthExceedsMaximum) }
    }

    func testOversizedDeclaredLengthFailsBeforeWaitingForBody() async throws {
        // URLProtocol may buffer headers until the first body callback. Leave
        // the response unfinished after that callback to prove early rejection.
        let request = try request(.init(chunks: [Data([1])], headers: ["Content-Length": "100"], staysOpen: true))
        do {
            _ = try await BoundedResponseLoader.data(
                for: request, configuration: configuration(), maximumBytes: 5, validate: { _ in })
            XCTFail("Must reject oversized header immediately")
        } catch let error as URLError { XCTAssertEqual(error.code, .dataLengthExceedsMaximum) }
    }

    func testValidatorFailureIsPreservedWithoutReadingBody() async throws {
        let request = try request(.init(chunks: [Data([1])], staysOpen: true))
        do {
            _ = try await BoundedResponseLoader.data(
                for: request, configuration: configuration(), maximumBytes: 5,
                validate: { _ in throw URLError(.unsupportedURL) })
            XCTFail("Validator must fail closed")
        } catch let error as URLError { XCTAssertEqual(error.code, .unsupportedURL) }
    }

    func testCancellationDuringResponseDoesNotWaitForTimeout() async throws {
        let started = expectation(description: "transport started")
        let request = try request(.init(staysOpen: true, onStart: { started.fulfill() }))
        let config = configuration()
        let task = Task {
            try await BoundedResponseLoader.data(
                for: request, configuration: config, maximumBytes: 5, validate: { _ in })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch is CancellationError {}
    }

    func testAlreadyCancelledTaskDoesNotStartRequest() async throws {
        let url = try XCTUnwrap(URL(string: "https://fixture.invalid/not-registered"))
        let config = configuration()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BoundedResponseLoader.data(
                for: URLRequest(url: url), configuration: config, maximumBytes: 5, validate: { _ in })
        }
        do { _ = try await task.value; XCTFail("Must cancel before transport") }
        catch is CancellationError {}
    }

    func testNetworkFailureIsPreserved() async throws {
        let request = try request(.init(failure: URLError(.notConnectedToInternet)))
        do {
            _ = try await BoundedResponseLoader.data(
                for: request, configuration: configuration(), maximumBytes: 5, validate: { _ in })
            XCTFail("Must propagate failure")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
    }

    func testTransportHasNoPersistentCacheCookieOrCredentialStorage() {
        let config = configuration()
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }
}

/// A deterministic transport that deliberately ignores cancellation. This models
/// responses already in flight when a guest leaves or changes workspace.
private actor PublicExperienceControlledLoader {
    private var pending: [Int: CheckedContinuation<PublicExperienceManifest, Error>] = [:]
    private(set) var requests: [URLRequest] = []
    private let onRequest: @Sendable (Int) -> Void

    init(onRequest: @escaping @Sendable (Int) -> Void) {
        self.onRequest = onRequest
    }

    func load(_ request: URLRequest) async throws -> PublicExperienceManifest {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            onRequest(index)
        }
    }

    func complete(_ index: Int, with manifest: PublicExperienceManifest) {
        pending.removeValue(forKey: index)?.resume(returning: manifest)
    }

    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: URLError(.notConnectedToInternet))
    }
}

private actor PublicExperienceScriptedLoader {
    enum Reply: Sendable {
        case manifest(PublicExperienceManifest)
        case offline
    }
    private var replies: [Reply]

    init(_ replies: [Reply]) { self.replies = replies }

    func load(_ request: URLRequest) async throws -> PublicExperienceManifest {
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case .manifest(let manifest): return manifest
        case .offline: throw URLError(.notConnectedToInternet)
        }
    }
}

@MainActor
final class PublicExperienceTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func image(_ id: Int = 101, environment: AppServiceEnvironment = .production,
                       url: URL? = nil, altText: String = "公开精选照片") -> PublicExperienceImage {
        PublicExperienceImage(id: id,
            url: url ?? AppURL.make("https://\(environment.mediaHost)/wp-content/uploads/2026/09/public-fixture-\(id).jpg"),
            altText: altText)
    }

    private func album(_ id: Int = 1, title: String = "公开精选", subtitle: String = "作品导览",
                       images: [PublicExperienceImage]? = nil,
                       environment: AppServiceEnvironment = .production) -> PublicExperienceAlbum {
        PublicExperienceAlbum(id: id, title: title, subtitle: subtitle,
                              images: images ?? [image(id * 100 + 1, environment: environment)])
    }

    private func manifest(_ albums: [PublicExperienceAlbum]? = nil, schema: Int = 1,
                          audience: String = "public", updatedAt: Date? = nil,
                          environment: AppServiceEnvironment = .production) -> PublicExperienceManifest {
        PublicExperienceManifest(schemaVersion: schema, contentAudience: audience,
                                 updatedAt: updatedAt ?? timestamp,
                                 albums: albums ?? [album(environment: environment)])
    }

    func testEmptyExplicitPublicManifestIsValid() {
        XCTAssertTrue(PublicExperiencePolicy.isValid(manifest([]), environment: .production),
                      "No published selection is a legitimate empty state, not an excuse to expose member albums")
    }

    func testPublicDTOCodableRoundTripContainsNoPrivateCatalogFields() throws {
        let value = manifest()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(PublicExperienceManifest.self, from: data), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "contentAudience", "updatedAt", "albums"])
        let albums = try XCTUnwrap(object["albums"] as? [[String: Any]])
        let firstAlbum = try XCTUnwrap(albums.first)
        XCTAssertEqual(Set(firstAlbum.keys), ["id", "title", "subtitle", "images"])
        let images = try XCTUnwrap(firstAlbum["images"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(images.first).keys), ["id", "url", "altText"],
                       "A public selection must not expose original/full-size or member-only URL fields")
    }

    func testOnlyCurrentSchemaAndExplicitPublicAudienceAreValid() {
        for schema in [-1, 0, 2, Int.max] {
            XCTAssertFalse(PublicExperiencePolicy.isValid(manifest(schema: schema), environment: .production))
        }
        for audience in ["", "viewer", "administrator", "private", "Public", " public "] {
            XCTAssertFalse(PublicExperiencePolicy.isValid(manifest(audience: audience), environment: .production), audience)
        }
    }

    func testPrivateManifestCannotDecodeAsPublicSelection() throws {
        let data = Data(#"{"schemaVersion":1,"contentAudience":"viewer","updatedAt":"2026-09-22T12:00:00Z","portfolios":[],"heroImages":[],"dramas":[]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(PublicExperienceManifest.self, from: data))
    }

    func testDateBoundsRejectPreEpochAndDistantFuture() {
        for interval: TimeInterval in [0, 4_102_444_800] {
            XCTAssertTrue(PublicExperiencePolicy.isValid(manifest(updatedAt: Date(timeIntervalSince1970: interval)),
                                                        environment: .production))
        }
        for interval: TimeInterval in [-1, 4_102_444_801, .infinity, .nan] {
            XCTAssertFalse(PublicExperiencePolicy.isValid(manifest(updatedAt: Date(timeIntervalSince1970: interval)),
                                                         environment: .production))
        }
    }

    func testAlbumAndImageCountBounds() {
        let maximum = (1...30).map { albumID in
            album(albumID, images: (1...6).map { image($0 + albumID * 100) })
        }
        XCTAssertTrue(PublicExperiencePolicy.isValid(manifest(maximum), environment: .production))
        XCTAssertFalse(PublicExperiencePolicy.isValid(manifest(maximum + [album(31)]), environment: .production))
        XCTAssertFalse(PublicExperiencePolicy.isValid(manifest([album(images: [])]), environment: .production))
        XCTAssertFalse(PublicExperiencePolicy.isValid(manifest([album(images: (1...7).map { image($0) })]),
                                                     environment: .production))
    }

    func testIdentifiersMustBePositiveAndUniqueWithinTheirCollections() {
        for invalidID in [-1, 0] {
            XCTAssertFalse(PublicExperiencePolicy.isValid(manifest([album(invalidID)]), environment: .production))
            XCTAssertFalse(PublicExperiencePolicy.isValid(manifest([album(images: [image(invalidID)])]),
                                                         environment: .production))
        }
        XCTAssertFalse(PublicExperiencePolicy.isValid(manifest([album(), album()]), environment: .production))
        XCTAssertFalse(PublicExperiencePolicy.isValid(manifest([album(images: [image(), image()])]),
                                                     environment: .production))
    }

    func testCopyLengthLimits() {
        let maximum = album(title: String(repeating: "字", count: 160),
                            subtitle: String(repeating: "字", count: 400),
                            images: [image(altText: String(repeating: "字", count: 400))])
        XCTAssertTrue(PublicExperiencePolicy.isValid(manifest([maximum]), environment: .production))
        for invalidTitle in ["", String(repeating: "字", count: 161)] {
            XCTAssertFalse(PublicExperiencePolicy.isValid(manifest([album(title: invalidTitle)]), environment: .production))
        }
        XCTAssertFalse(PublicExperiencePolicy.isValid(manifest([album(subtitle: String(repeating: "字", count: 401))]),
                                                     environment: .production))
        XCTAssertFalse(PublicExperiencePolicy.isValid(manifest([album(images: [image(altText: String(repeating: "字", count: 401))])]),
                                                     environment: .production))
        XCTAssertTrue(PublicExperiencePolicy.isValid(manifest([album(subtitle: "", images: [image(altText: "")])]),
                                                    environment: .production))
    }

    func testMediaURLRequiresApprovedOriginUploadPathAndNoCredentials() {
        let invalidURLs = [
            "http://www.shuzijun.com.cn/wp-content/uploads/example.jpg",
            "https://untrusted.example/wp-content/uploads/example.jpg",
            "https://www.shuzijun.com.cn.untrusted.example/wp-content/uploads/example.jpg",
            "https://www.shuzijun.com.cn:8443/wp-content/uploads/example.jpg",
            "https://fixture:fixture@www.shuzijun.com.cn/wp-content/uploads/example.jpg",
            "https://www.shuzijun.com.cn/wp-json/shuzijun/v1/content",
            "https://www.shuzijun.com.cn/private/example.jpg",
            "https://www.shuzijun.com.cn/wp-content/uploads/example.jpg?access=synthetic",
            "https://www.shuzijun.com.cn/wp-content/uploads/example.jpg#fragment",
            "https://www.shuzijun.com.cn/wp-content/uploads/%2e%2e/private.jpg",
            "https://www.shuzijun.com.cn/wp-content/uploads/%252e%252e/private.jpg",
            "https://www.shuzijun.com.cn/wp-content/uploads/album%2fprivate.jpg",
            "https://www.shuzijun.com.cn/wp-content/uploads/album%5cprivate.jpg",
        ]
        for candidate in invalidURLs {
            let value = manifest([album(images: [image(url: AppURL.make(candidate))])])
            XCTAssertFalse(PublicExperiencePolicy.isValid(value, environment: .production), candidate)
        }
        let cdn = image(url: AppURL.make("https://img.shuzijun.com.cn/wp-content/uploads/2026/09/selected.jpg"))
        XCTAssertTrue(PublicExperiencePolicy.isValid(manifest([album(images: [cdn])]), environment: .production))
    }

    func testProductionAndReviewMediaNeverCrossWorkspaces() {
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            XCTAssertTrue(PublicExperiencePolicy.isValid(manifest(environment: environment), environment: environment))
            XCTAssertFalse(PublicExperiencePolicy.isValid(manifest(environment: other), environment: environment))
        }
    }

    func testAnonymousRequestContainsNoAccountInstallationOrCookieHeaders() throws {
        for environment in AppServiceEnvironment.allCases {
            let request = PublicExperiencePolicy.request(environment: environment)
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, environment.apiHost)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(url.path.hasSuffix("/public-experience"))
            XCTAssertNil(url.query)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertFalse(request.httpShouldHandleCookies)
            for field in ["Authorization", "Cookie", "X-Yishu-Install-ID", "X-Yishu-Installation-ID", "X-WP-Nonce"] {
                XCTAssertNil(request.value(forHTTPHeaderField: field), "A guest request cannot carry \(field)")
            }
        }
    }

    /// Read-only post-deployment acceptance. Never enabled in the ordinary
    /// regression suite, and never run against an installed real-device App.
    /// HEAD verifies response headers and the derivative's declared filename
    /// dimensions only; it does not decode or save the artist's photographs.
    func testOptInLivePublicSelectionThroughNativeAnonymousTransport() async throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["YISHU_VERIFY_PUBLIC_SELECTION"] == "1" else {
            throw XCTSkip("Live public selection acceptance requires YISHU_VERIFY_PUBLIC_SELECTION=1 on an isolated simulator")
        }

        let request = PublicExperiencePolicy.request(environment: .production)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.httpShouldHandleCookies)
        for field in ["Authorization", "Cookie", "X-Yishu-Install-ID", "X-Yishu-Installation-ID", "X-WP-Nonce"] {
            XCTAssertNil(request.value(forHTTPHeaderField: field))
        }
        let live = try await PublicExperienceNetwork.fetch(request)
        guard PublicExperiencePolicy.isValid(live, environment: .production) else {
            XCTFail("Live public manifest was rejected by the shipping production policy")
            return
        }
        let expected: [Int: [Int]] = [6: [18, 19], 7: [33, 34], 39: [76, 77]]
        XCTAssertEqual(live.albums.map(\.id).sorted(), expected.keys.sorted(),
                       "Only the three explicitly approved albums may be public")
        guard live.albums.count == expected.count,
              live.albums.allSatisfy({ $0.images.map(\.id) == expected[$0.id] }) else {
            XCTFail("Live public selection must be exactly 6:[18,19], 7:[33,34], 39:[76,77], with no additional or reordered photographs")
            return
        }

        let session = SecureURLSessionFactory.make(requestTimeout: 12, resourceTimeout: 20,
                                                   waitsForConnectivity: false)
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        let dimensions = try NSRegularExpression(pattern: #"-([1-9][0-9]{2,3})x([1-9][0-9]{2,3})\.jpg$"#)
        for selected in live.albums.flatMap(\.images) {
            try Task.checkCancellation()
            let filename = selected.url.lastPathComponent as NSString
            let match = try XCTUnwrap(dimensions.firstMatch(in: filename as String,
                range: NSRange(location: 0, length: filename.length)),
                "Public photograph \(selected.id) must reference a bounded JPEG derivative, not an original")
            let width = try XCTUnwrap(Int(filename.substring(with: match.range(at: 1))))
            let height = try XCTUnwrap(Int(filename.substring(with: match.range(at: 2))))
            XCTAssertTrue((640...1600).contains(max(width, height)),
                          "Public derivative \(selected.id) has an unexpected declared long edge")
            XCTAssertGreaterThanOrEqual(min(width, height), 600)

            var head = URLRequest(url: selected.url)
            head.httpMethod = "HEAD"
            head.setValue("image/jpeg", forHTTPHeaderField: "Accept")
            head.cachePolicy = .reloadIgnoringLocalCacheData
            head.httpShouldHandleCookies = false
            head.timeoutInterval = 12
            for field in ["Authorization", "Cookie", "X-Yishu-Install-ID", "X-Yishu-Installation-ID", "X-WP-Nonce"] {
                XCTAssertNil(head.value(forHTTPHeaderField: field))
            }
            let (body, response) = try await session.data(for: head)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.url, selected.url, "Redirects are not a successful public image response")
            XCTAssertEqual(http.statusCode, 200, "Public photograph \(selected.id) must be directly available")
            XCTAssertEqual(http.mimeType?.lowercased(), "image/jpeg")
            XCTAssertTrue(body.isEmpty, "A HEAD acceptance check must not transfer image contents")
            let contentLength = try XCTUnwrap(http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) },
                                               "Public photograph \(selected.id) must declare its response size")
            XCTAssertTrue((32_768...524_288).contains(contentLength),
                          "Public photograph \(selected.id) exceeds the expected bounded preview size or is unexpectedly small")
        }
#else
        throw XCTSkip("Live public selection acceptance is simulator-only; it never operates on a user's installed App")
#endif
    }

    func testGuestStoreStartsEmptyAndLoadsOnlyExplicitPublicResponse() async {
        let expected = manifest()
        let store = PublicExperienceStore { _ in expected }
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
        await store.load()
        XCTAssertEqual(store.albums, expected.albums)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func testEmptyPublicResponseRemainsEmptyWithoutFallback() async {
        let expected = manifest([])
        let store = PublicExperienceStore { _ in expected }
        await store.load()
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertNil(store.errorMessage)
    }

    func testMemberStoreCannotPopulateGuestStoreOnNetworkFailure() async throws {
        let memberStore = PortfolioStore()
        defer { memberStore.discardProtectedContent() }
        let privateURL = AppURL.make("https://www.shuzijun.com.cn/wp-content/uploads/2026/09/member-fixture.jpg")
        let privateAlbum = Portfolio(id: 8_001, title: "审批专区夹具", subtitle: "不能进入公开区", eyebrow: "",
            slug: "member-fixture", websiteURL: AppURL.make("https://www.shuzijun.com.cn/portfolio/member-fixture/"),
            coverURL: privateURL, images: [PortfolioImage(id: 8_101, url: privateURL, fullSizeURL: privateURL, altText: "审批专区夹具")])
        let privateManifest = AppContentManifest(schemaVersion: 1, updatedAt: timestamp,
            heroImages: [privateURL], aboutPortraitURL: nil, launchPosters: [], showreel: nil, dramas: [],
            portfolios: [privateAlbum], contentAudience: .viewer)
        XCTAssertTrue(memberStore.completeContentRefresh(memberStore.beginContentRefresh(), with: privateManifest))
        let guestStore = PublicExperienceStore { _ in throw URLError(.notConnectedToInternet) }
        await guestStore.load()
        XCTAssertEqual(memberStore.portfolios.map(\.id), [privateAlbum.id])
        XCTAssertTrue(guestStore.albums.isEmpty)
        XCTAssertNotNil(guestStore.errorMessage)
    }

    func testFailedRefreshClearsPreviouslyPublishedGuestSelection() async {
        let loader = PublicExperienceScriptedLoader([.manifest(manifest()), .offline])
        let store = PublicExperienceStore { try await loader.load($0) }
        await store.load()
        XCTAssertFalse(store.albums.isEmpty)
        await store.load()
        XCTAssertTrue(store.albums.isEmpty, "A withdrawn or unverifiable public selection must not remain as stale fallback")
        XCTAssertFalse(store.isLoading)
        XCTAssertNotNil(store.errorMessage)
    }

    func testInvalidAudienceResponseClearsPreviousSelection() async {
        let loader = PublicExperienceScriptedLoader([.manifest(manifest()), .manifest(manifest(audience: "administrator"))])
        let store = PublicExperienceStore { try await loader.load($0) }
        await store.load()
        await store.load()
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    func testReviewLoaderNeverRequestsOrAcceptsProductionContent() async {
        let production = manifest()
        let store = PublicExperienceStore(environment: .review) { request in
            XCTAssertEqual(request.url?.host, AppServiceEnvironment.review.apiHost)
            return production
        }
        await store.load()
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testInvalidateClearsLoadedSelectionAndErrorState() async {
        let expected = manifest()
        let store = PublicExperienceStore { _ in expected }
        await store.load()
        store.invalidate()
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func testLateResponseAfterInvalidateCannotRepopulateGuestSelection() async {
        let started = expectation(description: "public request started")
        let loader = PublicExperienceControlledLoader { _ in started.fulfill() }
        let store = PublicExperienceStore { try await loader.load($0) }
        let task = Task { await store.load() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.isLoading)
        store.invalidate()
        await loader.complete(0, with: manifest())
        await task.value
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func testCancelledRequestCannotAcceptTransportThatIgnoresCancellation() async {
        let started = expectation(description: "public request started")
        let loader = PublicExperienceControlledLoader { _ in started.fulfill() }
        let store = PublicExperienceStore { try await loader.load($0) }
        let task = Task { await store.load() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await loader.complete(0, with: manifest())
        await task.value
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage, "Intentional cancellation is not a user-facing load error")
    }

    func testOnlyLatestConcurrentResponseCanPublish() async {
        let firstStarted = expectation(description: "first request started")
        let secondStarted = expectation(description: "second request started")
        let loader = PublicExperienceControlledLoader { index in
            if index == 0 { firstStarted.fulfill() }
            if index == 1 { secondStarted.fulfill() }
        }
        let store = PublicExperienceStore { try await loader.load($0) }
        let first = Task { await store.load() }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await store.load() }
        await fulfillment(of: [secondStarted], timeout: 2)
        let newest = manifest([album(2)])
        await loader.complete(1, with: newest)
        await second.value
        await loader.complete(0, with: manifest())
        await first.value
        XCTAssertEqual(store.albums, newest.albums)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func testOlderFailureDoesNotClearNewerSuccessfulSelection() async {
        let firstStarted = expectation(description: "first request started")
        let secondStarted = expectation(description: "second request started")
        let loader = PublicExperienceControlledLoader { index in
            if index == 0 { firstStarted.fulfill() }
            if index == 1 { secondStarted.fulfill() }
        }
        let store = PublicExperienceStore { try await loader.load($0) }
        let first = Task { await store.load() }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await store.load() }
        await fulfillment(of: [secondStarted], timeout: 2)
        let newest = manifest([album(2)])
        await loader.complete(1, with: newest)
        await second.value
        await loader.fail(0)
        await first.value
        XCTAssertEqual(store.albums, newest.albums)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    func testInvalidationFollowedByNewLoadAcceptsOnlyNewGeneration() async {
        let firstStarted = expectation(description: "first request started")
        let secondStarted = expectation(description: "second request started")
        let loader = PublicExperienceControlledLoader { index in
            if index == 0 { firstStarted.fulfill() }
            if index == 1 { secondStarted.fulfill() }
        }
        let store = PublicExperienceStore { try await loader.load($0) }
        let first = Task { await store.load() }
        await fulfillment(of: [firstStarted], timeout: 2)
        store.invalidate()
        let second = Task { await store.load() }
        await fulfillment(of: [secondStarted], timeout: 2)
        await loader.complete(0, with: manifest())
        await first.value
        XCTAssertTrue(store.albums.isEmpty)
        XCTAssertTrue(store.isLoading, "The obsolete request cannot finish the new generation's loading state")
        let newest = manifest([album(2)])
        await loader.complete(1, with: newest)
        await second.value
        XCTAssertEqual(store.albums, newest.albums)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
    }
}
