import XCTest
import AuthenticationServices
import Combine
import SwiftUI
import UIKit
import UserNotifications
import WeatherKit
import CoreLocation
import Network
import Observation
import Security
@testable import Yishu

final class RetiredGameBundleTests: XCTestCase {
    func testInstalledAppBundleDoesNotContainRetiredGameAssets() throws {
        let root = Bundle.main.bundleURL
        let candidates = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ))
        let retiredNames: Set<String> = ["GameAssets", "legacy-game-assets", "GameReference",
                                        "events.js", "endings.js", "main.js"]
        for case let url as URL in candidates {
            XCTAssertFalse(retiredNames.contains(url.lastPathComponent),
                           "退役游戏资源不得进入实际 App 包：\(url.lastPathComponent)")
        }
    }

    func testCurrentClientPrivacyManifestDoesNotCollectGameplay() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil
        ) as? [String: Any])
        let entries = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        XCTAssertFalse(entries.contains {
            $0["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeGameplayContent"
        })
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
    }
}

final class DramaLinkHealthTests: XCTestCase {
    private func actorPage(name: String = "易姝", status: Int = 0) throws -> Data {
        let payload: [String: Any] = ["loaderData": ["page": ["pageData": [
            "BaseResp": ["StatusCode": status], "actor_data": ["actor_name": name,
                "works": [["series_title": "京春夜"]]]]]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return Data("<script>window._ROUTER_DATA = \(json)</script>".utf8)
    }

    func testSoft404IsExpiredEvenWithStatus200() {
        XCTAssertEqual(DramaLinkPolicy.evaluate(status: 200, body: Data(#"{"message":"404 not found"}"#.utf8)), .expired)
    }

    func testHardExpiryAndTemporaryFailuresAreDifferent() {
        for status in [404, 410] { XCTAssertEqual(DramaLinkPolicy.evaluate(status: status, body: Data()), .expired) }
        for status in [302, 403, 429, 500, 503] {
            XCTAssertEqual(DramaLinkPolicy.evaluate(status: status, body: Data()), .unverified)
        }
    }

    func testOnlyValidArtistPagePasses() throws {
        XCTAssertEqual(DramaLinkPolicy.evaluate(status: 200, body: try actorPage(), requireActor: true), .available)
        XCTAssertEqual(DramaLinkPolicy.evaluate(status: 200, body: try actorPage(name: "其他演员"), requireActor: true), .unverified)
        XCTAssertEqual(DramaLinkPolicy.evaluate(status: 200, body: try actorPage(status: 1)), .unverified)
    }

    func testVerificationPageMalformedAndOversizedDataDoNotPass() {
        for body in [Data("<html>请验证</html>".utf8), Data("window._ROUTER_DATA = {broken}</script>".utf8), Data(repeating: 32, count: 524_289)] {
            XCTAssertEqual(DramaLinkPolicy.evaluate(status: 200, body: body), .unverified)
        }
    }

    func testSeriesPageCannotBecomeAnActorProfile() {
        let body = Data(#"<script>window._ROUTER_DATA = {"loaderData":{"page":{"pageData":{"BaseResp":{"StatusCode":0},"series_data":{"title":"京春夜"}}}}}</script>"#.utf8)
        XCTAssertEqual(DramaLinkPolicy.evaluate(status: 200, body: body), .available)
        XCTAssertEqual(DramaLinkPolicy.evaluate(status: 200, body: body, requireActor: true), .unverified)
    }

    func testUnsafeRedirectDestinationsAreRejected() throws {
        XCTAssertTrue(DramaLinkPolicy.isHongguo(ContentCatalog.hongguoURL))
        for text in ["https://novelquickapp.com.evil.test/", "https://127.0.0.1/", "https://user@novelquickapp.com/", "https://novelquickapp.com:444/", "file:///tmp/test"] {
            XCTAssertFalse(DramaLinkPolicy.isHongguo(try XCTUnwrap(URL(string: text))))
        }
    }

    func testReplacementPreservesPerSeriesLinksAndAllOtherFields() throws {
        let replacement = try XCTUnwrap(URL(string: "https://novelquickapp.com/s/new-test/"))
        let dedicated = try XCTUnwrap(URL(string: "https://novelquickapp.com/s/series-test/"))
        var original = ContentCatalog.dramas
        let first = original[0]
        original[0] = DramaWork(id: first.id, title: first.title, imageURL: first.imageURL, destinationURL: dedicated)
        let result = DramaLinkPolicy.replacing(original, from: ContentCatalog.hongguoURL, to: replacement)
        XCTAssertEqual(result.map(\.id), original.map(\.id))
        XCTAssertEqual(result.map(\.title), original.map(\.title))
        XCTAssertEqual(result.map(\.imageURL), original.map(\.imageURL))
        XCTAssertEqual(result[0].destinationURL, dedicated)
        XCTAssertTrue(result.dropFirst().allSatisfy { $0.destinationURL == replacement })
        XCTAssertEqual(DramaLinkPolicy.profileCandidate(in: result), replacement)
    }

    func testAboutDoesNotChooseASingleSeriesAsProfile() throws {
        let first = ContentCatalog.dramas[0]
        let series = DramaWork(id: first.id, title: first.title, imageURL: first.imageURL,
                               destinationURL: try XCTUnwrap(URL(string: "https://novelquickapp.com/s/series-only/")))
        XCTAssertEqual(DramaLinkPolicy.profileCandidate(in: [series]), ContentCatalog.hongguoURL)
        XCTAssertEqual(DramaLinkPolicy.profileCandidate(in: []), ContentCatalog.hongguoURL)
    }
}

@MainActor
final class PortfolioCaptionRenderingTests: XCTestCase {
    func testCaptionOutlineUsesTheOppositeLuminanceWithoutPaintingABackground() {
        for theme in AppColorTheme.allCases {
            let outline = UIColor(PortfolioCaptionPalette(theme: theme).outline)
            var white: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(outline.getWhite(&white, alpha: &alpha))
            XCTAssertEqual(alpha, 1, accuracy: 0.001)
            XCTAssertEqual(white, theme.colorScheme == .light ? 1 : 0, accuracy: 0.001)
        }
    }

    func testLightCaptionRolesContrastWithTheirUnpaintedThemeBackground() throws {
        for theme in AppColorTheme.allCases where theme.colorScheme == .light {
            let palette = PortfolioCaptionPalette(theme: theme)
            for (role, color) in [("title", palette.title), ("subtitle", palette.subtitle),
                                  ("accent", palette.accent), ("ordinal", palette.ordinal)] {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
                XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &alpha))
                XCTAssertEqual(alpha, 1, accuracy: 0.001, "\(theme) \(role) 必须保持完整字色")
                let glyph = ThemeRGB(red: Double(r), green: Double(g), blue: Double(b))
                XCTAssertGreaterThanOrEqual(glyph.contrast(with: theme.palette.background), 4.5,
                                           "\(theme) \(role) 在等比照片留白上不够清楚")
            }
        }
    }

    func testDarkCaptionPalettePreservesExistingPhotoTypography() {
        for theme in AppColorTheme.allCases where theme.colorScheme == .dark {
            let palette = PortfolioCaptionPalette(theme: theme)
            let roles: [(Color, Color)] = [
                (palette.title, .white),
                (palette.subtitle, .white.opacity(0.92)),
                (palette.ordinal, .white.opacity(0.84)),
                (palette.accent, MediaTheme.gold),
                (palette.shadow, .black.opacity(0.72))
            ]
            for (actual, expected) in roles {
                var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
                var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
                // Compare rendered components, not UIColor's gray/RGB storage.
                XCTAssertTrue(UIColor(actual).getRed(&ar, green: &ag, blue: &ab, alpha: &aa))
                XCTAssertTrue(UIColor(expected).getRed(&er, green: &eg, blue: &eb, alpha: &ea))
                XCTAssertEqual(ar, er, accuracy: 0.001)
                XCTAssertEqual(ag, eg, accuracy: 0.001)
                XCTAssertEqual(ab, eb, accuracy: 0.001)
                XCTAssertEqual(aa, ea, accuracy: 0.001)
            }
        }
    }

    func testCaptionKeepsEmptyPhotoAreaFullyTransparentInBothAppearances() throws {
        for theme in AppColorTheme.allCases {
            let palette = PortfolioCaptionPalette(theme: theme)
            for textSize in [DynamicTypeSize.large, .accessibility3] {
                let caption = Text("相册 · 东方美学")
                    .font(.title3)
                    .foregroundStyle(palette.title)
                    .modifier(PortfolioCaptionLegibility(palette: palette))
                    .padding(24)
                    .frame(width: 640, height: 160)
                    .environment(\.colorScheme, theme.colorScheme)
                    .environment(\.dynamicTypeSize, textSize)
                let renderer = ImageRenderer(content: caption)
                renderer.scale = 1
                renderer.isOpaque = false
                let image = try XCTUnwrap(renderer.cgImage)
                var rgba = [UInt8](repeating: 0, count: 640 * 160 * 4)
                try rgba.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                        width: 640, height: 160, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 160))
                }
                // A caption-sized black gradient or capsule would paint these
                // pixels even though no text is present at the photo boundary.
                for x in stride(from: 0, to: 640, by: 8) {
                    for y in [0, 8, 151, 159] {
                        XCTAssertEqual(rgba[(y * 640 + x) * 4 + 3], 0,
                            "相册文字外侧不应绘制黑色蒙版")
                    }
                }
                XCTAssertTrue(stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] > 0 },
                    "必须实际渲染文字，不能用空视图通过透明度测试")
                if theme.colorScheme == .light {
                    var darkOpaquePixels = 0
                    for offset in stride(from: 0, to: rgba.count, by: 4) {
                        let isDark = rgba[offset] < 128
                            && rgba[offset + 1] < 128
                            && rgba[offset + 2] < 128
                        let isOpaque = rgba[offset + 3] > 250
                        if isDark && isOpaque { darkOpaquePixels += 1 }
                    }
                    XCTAssertGreaterThan(darkOpaquePixels, 20,
                                         "\(theme) 浅色文字不能仍靠白字黑影支撑：\(textSize)")
                }
            }
        }
    }
}

private actor ImagePipelineTestLoader {
    let data: Data
    let responseURL: URL?
    let delayed: Bool
    let initialFailures: [URLError.Code]
    let onRequest: @Sendable (Int) -> Void
    private(set) var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]

    init(data: Data, responseURL: URL? = nil, delayed: Bool = false,
         initialFailures: [URLError.Code] = [],
         onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.data = data; self.responseURL = responseURL; self.delayed = delayed; self.onRequest = onRequest
        self.initialFailures = initialFailures
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        if initialFailures.indices.contains(index) {
            onRequest(index)
            throw URLError(initialFailures[index])
        }
        if !delayed { onRequest(index); return try reply(to: request) }
        // Intentionally ignore cancellation to model a reply already delivered
        // by the network while a workspace/memory purge is taking place.
        return try await withCheckedThrowingContinuation {
            pending[index] = $0
            onRequest(index)
        }
    }

    func complete(_ index: Int) throws {
        guard requests.indices.contains(index), let continuation = pending.removeValue(forKey: index) else { return }
        continuation.resume(returning: try reply(to: requests[index]))
    }

    func cancelPending() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }

    private func reply(to request: URLRequest) throws -> (Data, URLResponse) {
        guard let url = responseURL ?? request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Type": "image/png", "Content-Length": String(data.count)]) else {
            throw ArtworkImageLoadError.invalidResponse
        }
        return (data, response)
    }
}

@MainActor
final class GalleryResizeCompositionTests: XCTestCase {
    func testPortraitPhotoKeepsActualFocalPointAcrossContinuousWidthChangesAt2xAnd4x() {
        assertPhotoFocusIsPreserved(imageSize: CGSize(width: 400, height: 600))
    }

    func testLandscapePhotoKeepsActualFocalPointAcrossContinuousWidthChangesAt2xAnd4x() {
        assertPhotoFocusIsPreserved(imageSize: CGSize(width: 600, height: 400))
    }

    private func assertPhotoFocusIsPreserved(imageSize: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        let url = AppURL.make("https://example.invalid/synthetic-photo.png")
        let photo = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "合成比例测试")
        for scale: CGFloat in [2, 4] {
            for (height, widths): (CGFloat, [CGFloat]) in [
                (600, [980, 940, 860, 780, 700, 620, 700, 860, 980]),
                (1000, [820, 780, 740, 700, 660, 620, 660, 740, 820])
            ] {
                let controller = GalleryZoomViewController(image: photo)
                controller.loadViewIfNeeded()
                let initialSize = CGSize(width: widths[0], height: height)
                controller.view.frame.size = initialSize
                controller.viewDidLayoutSubviews()
                controller.artworkSizeReceiver()(imageSize, url)
                controller.scrollView.setZoomScale(scale, animated: false)
                let initialRect = fittedRect(imageSize, in: initialSize)
                controller.scrollView.contentOffset = CGPoint(
                    x: (initialRect.minX + initialRect.width * 0.7) * scale - initialSize.width / 2,
                    y: (initialRect.minY + initialRect.height * 0.6) * scale - initialSize.height / 2
                )
                let initialFocus = imageFocus(of: controller, in: initialRect)
                let pixel = 1 / max(1, controller.scrollView.traitCollection.displayScale)
                for width in widths.dropFirst() {
                    let size = CGSize(width: width, height: height)
                    controller.view.frame.size = size
                    controller.viewDidLayoutSubviews()
                    let rect = fittedRect(imageSize, in: size)
                    let focus = imageFocus(of: controller, in: rect)
                    XCTAssertEqual(controller.scrollView.zoomScale, scale, accuracy: 0.001, file: file, line: line)
                    XCTAssertEqual(focus.x, initialFocus.x, accuracy: 2 * pixel / (rect.width * scale),
                                   "窗口变化应保留照片坐标，而非包含留白的容器坐标", file: file, line: line)
                    XCTAssertEqual(focus.y, initialFocus.y, accuracy: 2 * pixel / (rect.height * scale),
                                   "宽度变化改变上下留白时，也必须保留照片纵向焦点", file: file, line: line)
                }
            }
        }
    }

    func testFullResolutionGeometryWinsOverLatePreviewAndInvalidSizes() {
        let preview = AppURL.make("https://example.invalid/preview.png")
        let full = AppURL.make("https://example.invalid/full.png")
        let photo = PortfolioImage(id: 1, url: preview, fullSizeURL: full, altText: "合成测试")
        let controller = configuredController(photo)
        let receive = controller.artworkSizeReceiver()
        receive(CGSize(width: 600, height: 400), preview)
        receive(CGSize(width: 400, height: 600), full)
        receive(CGSize(width: 600, height: 400), preview)
        receive(CGSize(width: 600, height: 400), AppURL.make("https://example.invalid/foreign.png"))
        for invalid in [CGSize.zero, CGSize(width: -1, height: 600),
                        CGSize(width: CGFloat.infinity, height: 600), CGSize(width: 400, height: CGFloat.nan)] {
            receive(invalid, full)
        }
        assertKnownPortraitResize(controller)
    }

    func testOldPhotoAndWorkspaceCallbacksCannotRestoreDiscardedGeometry() {
        let url = AppURL.make("https://example.invalid/synthetic-photo.png")
        let photo = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "合成测试")
        let controller = configuredController(photo)
        let oldPhotoReceiver = controller.artworkSizeReceiver()
        oldPhotoReceiver(CGSize(width: 400, height: 600), url)
        controller.update(image: PortfolioImage(id: 2, url: url, fullSizeURL: url, altText: "另一张合成图"))
        // Return to the same photo to exercise an A -> B -> A callback race.
        controller.update(image: photo)
        oldPhotoReceiver(CGSize(width: 400, height: 600), url)
        assertUnknownSizeResize(controller)
        controller.view.frame.size = CGSize(width: 980, height: 600)
        controller.viewDidLayoutSubviews()
        let oldEnvironmentReceiver = controller.artworkSizeReceiver()
        oldEnvironmentReceiver(CGSize(width: 400, height: 600), url)
        controller.update(image: photo, environment: .review)
        controller.update(image: photo, environment: .production)
        oldEnvironmentReceiver(CGSize(width: 400, height: 600), url)
        assertUnknownSizeResize(controller)
    }

    func testKnownPhotoStillResetsOnRotationAndKeepsUnzoomedImageComplete() {
        let url = AppURL.make("https://example.invalid/synthetic-photo.png")
        let photo = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "合成测试")
        let controller = configuredController(photo)
        controller.artworkSizeReceiver()(CGSize(width: 400, height: 600), url)
        assertKnownPortraitResize(controller)
        controller.view.frame.size = CGSize(width: 430, height: 760)
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(controller.scrollView.zoomScale, 1)
        XCTAssertEqual(controller.scrollView.contentOffset, .zero)
        for width: CGFloat in [390, 350, 430] {
            controller.view.frame.size.width = width
            controller.viewDidLayoutSubviews()
            XCTAssertEqual(controller.scrollView.zoomScale, 1)
            XCTAssertEqual(controller.scrollView.contentOffset, .zero)
        }
    }

    func testGalleryPreviewKeepsExistingLoadingPlaceholderAppearance() throws {
        let url = AppURL.make("https://example.invalid/synthetic-photo.png")
        let photo = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "合成测试")
        let size = CGSize(width: 120, height: 180)
        // Rendering this empty state does not start a URL request and uses no
        // real photograph. Compare away from the animated progress glyph.
        let oldRenderer = ImageRenderer(content: ArtworkImage(url: url, contentMode: .fit)
            .frame(width: size.width, height: size.height))
        let newRenderer = ImageRenderer(content: ProgressiveGalleryArtwork(image: photo, targetSize: size))
        oldRenderer.scale = 1
        newRenderer.scale = 1
        let old = try pixels(try XCTUnwrap(oldRenderer.cgImage))
        let new = try pixels(try XCTUnwrap(newRenderer.cgImage))
        XCTAssertEqual(old.count, new.count)
        for x in stride(from: 0, to: 120, by: 10) {
            for y in [0, 10, 169, 179] {
                let offset = (y * 120 + x) * 4
                XCTAssertEqual(Array(old[offset..<(offset + 4)]), Array(new[offset..<(offset + 4)]),
                               "图库加载占位背景不能因焦点修复发生视觉变化")
            }
        }
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func configuredController(_ photo: PortfolioImage) -> GalleryZoomViewController {
        let controller = GalleryZoomViewController(image: photo)
        controller.loadViewIfNeeded()
        controller.view.frame.size = CGSize(width: 980, height: 600)
        controller.viewDidLayoutSubviews()
        return controller
    }

    private func assertKnownPortraitResize(_ controller: GalleryZoomViewController) {
        controller.scrollView.setZoomScale(2, animated: false)
        controller.scrollView.contentOffset = CGPoint(x: 710, y: 420)
        controller.view.frame.size = CGSize(width: 700, height: 600)
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(controller.scrollView.contentOffset.x, 570, accuracy: 1,
                       "2:3 照片焦点应为 77.5%，旧容器算法会漂移约 63pt")
        XCTAssertEqual(controller.scrollView.contentOffset.y, 420, accuracy: 1)
    }

    private func assertUnknownSizeResize(_ controller: GalleryZoomViewController) {
        controller.scrollView.setZoomScale(2, animated: false)
        controller.scrollView.contentOffset = CGPoint(x: 710, y: 420)
        controller.view.frame.size = CGSize(width: 700, height: 600)
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(controller.scrollView.contentOffset.x, CGFloat(1200) / 1960 * 1400 - 350, accuracy: 1,
                       "未加载或已切换图片不能沿用旧照片尺寸")
        XCTAssertEqual(controller.scrollView.contentOffset.y, 420, accuracy: 1)
    }

    private func fittedRect(_ image: CGSize, in viewport: CGSize) -> CGRect {
        let ratio = image.width / image.height
        let width = min(viewport.width, viewport.height * ratio)
        let height = width / ratio
        return CGRect(x: (viewport.width - width) / 2, y: (viewport.height - height) / 2,
                      width: width, height: height)
    }

    private func imageFocus(of controller: GalleryZoomViewController, in rect: CGRect) -> CGPoint {
        let scroll = controller.scrollView
        return CGPoint(
            x: ((scroll.contentOffset.x + scroll.bounds.width / 2) / scroll.zoomScale - rect.minX) / rect.width,
            y: ((scroll.contentOffset.y + scroll.bounds.height / 2) / scroll.zoomScale - rect.minY) / rect.height
        )
    }
}

@MainActor
final class ArtworkEnvironmentPipelineTests: XCTestCase {
    func testTransientDisconnectRecoversInsideBoundedImageRetryAndCachesDecodedImage() async throws {
        let loader = ImagePipelineTestLoader(data: try fixture(),
            initialFailures: [.networkConnectionLost, .notConnectedToInternet])
        let pipeline = ArtworkImagePipeline { try await loader.load($0) }
        let url = AppURL.make("https://www.shuzijun.com.cn/test/reconnect.png")
        let image = try await pipeline.image(for: url, maxPixelSize: 320)
        XCTAssertNotNil(image.cgImage)
        let cached = try await pipeline.image(for: url, maxPixelSize: 320)
        XCTAssertTrue(image === cached)
        let requests = await loader.requests
        XCTAssertEqual(requests.count, 3, "恢复后应命中内存缓存，不再发请求")
        await pipeline.purgeMemory()
    }

    func testExhaustedOfflineImageFlightDoesNotPoisonExplicitRetryAfterReconnect() async throws {
        let loader = ImagePipelineTestLoader(data: try fixture(),
            initialFailures: Array(repeating: .notConnectedToInternet, count: 3))
        let pipeline = ArtworkImagePipeline { try await loader.load($0) }
        let url = AppURL.make("https://www.shuzijun.com.cn/test/reconnect.png")
        do {
            _ = try await pipeline.image(for: url, maxPixelSize: 320)
            XCTFail("持续离线不应被伪装成加载成功")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        let failedRequests = await loader.requests
        XCTAssertEqual(failedRequests.count, 3, "离线重试必须有上限")
        let failedPreview = await pipeline.cachedPreview(for: url)
        XCTAssertNil(failedPreview)
        let recovered = try await pipeline.image(for: url, maxPixelSize: 320)
        XCTAssertNotNil(recovered.cgImage)
        let recoveredRequests = await loader.requests
        XCTAssertEqual(recoveredRequests.count, 4, "重连后必须创建新请求而不是复用失败任务")
        await pipeline.purgeMemory()
    }

#if DEBUG
    func testGestureRasterFixtureUsesTheRealDecoderWithoutRemotePhotographs() async throws {
        let url = AppURL.make("https://www.shuzijun.com.cn/wp-content/uploads/gesture-fixture.png")
        let pipeline = ArtworkImagePipeline { try await ArtworkImageUITestFixture.response(for: $0) }
        let image = try await pipeline.image(for: url, maxPixelSize: 640)
        let raster = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(raster.width, 400)
        XCTAssertEqual(raster.height, 600)
        await pipeline.purgeMemory()
    }
#endif

    private func fixture() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try XCTUnwrap(image.pngData())
    }

    func testPipelineRejectsOtherEnvironmentBeforeLoadingAndKeepsMemoryCacheScoped() async throws {
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            let loader = ImagePipelineTestLoader(data: try fixture())
            let pipeline = ArtworkImagePipeline(environment: environment) { try await loader.load($0) }
            let url = AppURL.make("https://\(environment.mediaHost)/test/image.png")
            let foreign = AppURL.make("https://\(other.mediaHost)/test/image.png")
            do { _ = try await pipeline.image(for: foreign, maxPixelSize: 320); XCTFail("Foreign image was requested") }
            catch { XCTAssertEqual(error as? ArtworkImageLoadError, .invalidResponse) }
            let before = await loader.requests
            XCTAssertTrue(before.isEmpty)
            let first = try await pipeline.image(for: url, maxPixelSize: 320)
            let cached = try await pipeline.image(for: url, maxPixelSize: 320)
            XCTAssertTrue(first === cached)
            let requests = await loader.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url, url)
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
            let foreignPreview = await pipeline.cachedPreview(for: foreign)
            XCTAssertNil(foreignPreview)
            await pipeline.purgeMemory()
            let previewAfterPurge = await pipeline.cachedPreview(for: url)
            XCTAssertNil(previewAfterPurge)
        }
    }

    func testPipelineRejectsImageResponseFromOtherEnvironment() async throws {
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            let url = AppURL.make("https://\(environment.mediaHost)/test/image.png")
            let loader = ImagePipelineTestLoader(data: try fixture(), responseURL: AppURL.make("https://\(other.mediaHost)/test/image.png"))
            let pipeline = ArtworkImagePipeline(environment: environment) { try await loader.load($0) }
            do { _ = try await pipeline.image(for: url, maxPixelSize: 320); XCTFail("Foreign response was decoded") }
            catch { XCTAssertEqual(error as? ArtworkImageLoadError, .invalidResponse) }
            let cached = await pipeline.cachedPreview(for: url)
            XCTAssertNil(cached)
            let requests = await loader.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testPurgedLateImageCannotRepopulateCacheOrEraseReplacementFlight() async throws {
        for environment in AppServiceEnvironment.allCases {
            let firstStarted = expectation(description: "Old image request started: \(environment)")
            let replacementStarted = expectation(description: "Replacement started: \(environment)")
            let loader = ImagePipelineTestLoader(data: try fixture(), delayed: true) { index in
                if index == 0 { firstStarted.fulfill() }
                if index == 1 { replacementStarted.fulfill() }
            }
            let pipeline = ArtworkImagePipeline(environment: environment) { try await loader.load($0) }
            let url = AppURL.make("https://\(environment.mediaHost)/test/image.png")
            let old = Task { try await pipeline.image(for: url, maxPixelSize: 320) }
            await fulfillment(of: [firstStarted], timeout: 5)
            await pipeline.purgeMemory()
            let replacement = Task { try await pipeline.image(for: url, maxPixelSize: 320) }
            await fulfillment(of: [replacementStarted], timeout: 5)
            try await loader.complete(0)
            do { _ = try await old.value; XCTFail("Purged request returned an image") }
            catch { XCTAssertTrue(error is CancellationError) }
            let latePreview = await pipeline.cachedPreview(for: url)
            XCTAssertNil(latePreview)
            try await loader.complete(1)
            let loaded = try await replacement.value
            let cached = try await pipeline.image(for: url, maxPixelSize: 320)
            XCTAssertTrue(loaded === cached)
            let requests = await loader.requests
            XCTAssertEqual(requests.count, 2)
            await pipeline.purgeMemory()
            await loader.cancelPending()
        }
    }
}

final class AppServiceEnvironmentTests: XCTestCase {
    func testMatchingUserIDsDoNotMatchAcrossEnvironmentContexts() {
        let production = FanNotificationContext(userID: "synthetic-user", sessionGeneration: 1)
        let review = FanNotificationContext(userID: "synthetic-user", sessionGeneration: 1, environment: .review)
        XCTAssertNotEqual(production, review)
        XCTAssertEqual(Set([production, review]).count, 2)
        XCTAssertNotEqual(
            FanAdministratorContext(userID: "synthetic-user", sessionGeneration: 1),
            FanAdministratorContext(userID: "synthetic-user", sessionGeneration: 1, environment: .review)
        )
    }

    func testEnvironmentsNeverAcceptEachOthersCredentialOrigins() {
        for environment in AppServiceEnvironment.allCases {
            XCTAssertTrue(environment.allowsAPIURL(environment.apiRoot))
            XCTAssertTrue(environment.allowsMediaUploadURL(environment.mediaUploadURL))
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            XCTAssertFalse(environment.allowsAPIURL(other.apiRoot))
            XCTAssertFalse(environment.allowsMediaUploadURL(other.mediaUploadURL))
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
                XCTAssertFalse(environment.allowsAPIURL(URL(string: raw)), raw)
            }
        }
    }

    func testReviewStorageDoesNotReuseProductionKeys() {
        for key in ["cn.com.shuzijun.yishu.fan-account", "portfolio-cache", "favorites", "recently-viewed"] {
            XCTAssertEqual(AppServiceEnvironment.production.storageKey(key), key)
            XCTAssertEqual(AppServiceEnvironment.review.storageKey(key), "review." + key)
        }
    }
}

@MainActor
final class LiveReviewAdministratorTests: XCTestCase {
    private enum CheckFailure: Error {
        case owner, registration, pendingAccess, approval, binding, nativeSession
        case revocation, deletion, deletedLogin, publishedMediaRetention
    }

    /// Opt-in integration of the shipping stores, not a response stub or a UI
    /// access-gate bypass. Run only on a newly owned disposable simulator.
    func testNativeAccountApprovalBindingRevocationAndDeletion() async throws {
        let values = ProcessInfo.processInfo.environment
        guard values["YISHU_LIVE_REVIEW_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires explicit isolated review acceptance setup")
        }
        guard let ownerPassword = values["YISHU_REVIEW_OWNER_ACCESS"], !ownerPassword.isEmpty,
              let password = values["YISHU_REVIEW_DISPOSABLE_PASSWORD"],
              FanAccountValidation.isValidPassword(password),
              let marker = values["YISHU_REVIEW_DISPOSABLE_MARKER"],
              marker.range(of: #"^native_[a-f0-9]{24}$"#, options: .regularExpression) != nil else {
            throw CheckFailure.owner
        }
        // The shipping account store requires a working device-only Keychain.
        // An unsigned simulator build is not a valid live-auth acceptance host.
        let keychainProbe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cn.com.shuzijun.yishu.native-acceptance",
            kSecAttrAccount as String: marker,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(marker.utf8)
        ]
        let keychainStatus = SecItemAdd(keychainProbe as CFDictionary, nil)
        if keychainStatus == errSecSuccess {
            let query = keychainProbe.filter { $0.key != (kSecValueData as String) }
            XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess)
        }
        print("native-review-keychain-status: \(keychainStatus)")
        guard keychainStatus == errSecSuccess else { throw CheckFailure.nativeSession }
        let owner = AdminSessionStore(environment: .review)
        let account = FanAccountStore(environment: .review)
        let bound = AdminSessionStore(environment: .review)
        defer { owner.signOut(); bound.signOut() }
        await owner.signIn(username: "review_bootstrap", applicationPassword: ownerPassword)
        guard owner.canManageFanAdministrators else { throw CheckFailure.owner }
        var failure: Error?
        var identityCode: String?
        var userID: String?
        var temporaryPortfolioID: Int?
        // Fixed phase labels only: never put credentials, identity codes or
        // server response bodies into test diagnostics.
        var phase = "mandatory-douyin"
        do {
            await account.register(displayName: "临时原生验收", douyinID: "",
                                   password: password, passwordConfirmation: password,
                                   acceptedDataUse: true)
            guard account.profile == nil,
                  account.errorMessage == FanAccountError.invalidDouyinID.errorDescription else {
                throw CheckFailure.registration
            }
            phase = "registration"
            await account.register(displayName: "临时原生验收", douyinID: marker,
                                   password: password, passwordConfirmation: password,
                                   acceptedDataUse: true)
            guard let profile = account.profile else {
                // Only allowlisted client error categories enter diagnostics.
                // Server messages, identity codes and credentials stay private.
                let known: [(String, FanAccountError)] = [
                    ("rate-limited", .rateLimited), ("unavailable", .unavailable),
                    ("invalid-response", .invalidResponse), ("consent", .consentRequired),
                    ("douyin", .invalidDouyinID), ("password", .weakPassword)
                ]
                let category = known.first { $0.1.errorDescription == account.errorMessage }?.0 ?? "other"
                print("native-review-registration-category: \(category)")
                throw CheckFailure.registration
            }
            identityCode = profile.identityCode
            userID = profile.userID
            guard account.isAuthenticated, !account.isApproved,
                  account.administratorContext == nil else { throw CheckFailure.pendingAccess }
            phase = "approval"
            _ = try await owner.updateFanAccess(userID: profile.userID, status: "active")
            await account.refreshSession()
            guard account.isApproved, account.administratorContext == nil else { throw CheckFailure.approval }
            phase = "hs-password-login"
            await account.signOut()
            guard !account.isAuthenticated else { throw CheckFailure.nativeSession }
            await account.signIn(identityCode: profile.identityCode, password: password)
            guard account.isAuthenticated, account.isApproved,
                  account.profile?.userID == profile.userID,
                  account.profile?.identityCode == profile.identityCode,
                  account.administratorContext == nil else { throw CheckFailure.nativeSession }
            phase = "binding"
            let before = try await owner.fetchFanUser(userID: profile.userID)
            _ = try await owner.updateFanAdministrator(AdminFanAdministratorUpdate(user: before, administrator: true))
            await account.refreshSession()
            guard account.administratorContext != nil else { throw CheckFailure.binding }
            phase = "bound-session"
            await bound.signIn(using: account)
            guard bound.isAuthenticated, !bound.isIndependentAdministrator,
                  bound.canManageFanAdministrators else { throw CheckFailure.nativeSession }
            // Fetch through the shipping client and actual HS-bound session.
            // A real photo-only review catalog must be editable without fake video.
            phase = "photo-only-content"
            let editable = try await bound.fetchContent()
            guard editable.contentAudience == .administrator,
                  AdminContentEditingPolicy.isFullAdministratorManifest(editable),
                  editable.portfolios.count >= 2 else { throw CheckFailure.nativeSession }
            if values["YISHU_REVIEW_EXPECT_PHOTO_ONLY"] == "1" {
                guard editable.showreel == nil else { throw CheckFailure.nativeSession }
            }
            if values["YISHU_REVIEW_MEDIA_ACCEPTANCE"] == "1" {
                phase = "bound-media-upload-and-gallery"
                let data = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 480)).pngData { context in
                    UIColor.darkGray.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
                    UIColor.white.setFill()
                    context.fill(CGRect(x: 80, y: 120, width: 160, height: 240))
                }
                let first = try await bound.upload(data: data, filename: marker + "-one.png", mimeType: "image/png")
                let second = try await bound.upload(data: data, filename: marker + "-two.png", mimeType: "image/png")
                let created = try await bound.createPortfolio(title: marker,
                    subtitle: "临时合成验收素材，结束后清理", eyebrow: "TEST FIXTURE")
                temporaryPortfolioID = created.portfolioID
                let changed = try await bound.updateGallery(portfolioID: created.portfolioID, mediaIDs: [second.id, first.id])
                guard changed.portfolios.first(where: { $0.id == created.portfolioID })?.images.map(\.id) == [second.id, first.id]
                else { throw CheckFailure.nativeSession }
            }
            phase = "revocation"
            let active = try await owner.fetchFanUser(userID: profile.userID)
            _ = try await owner.updateFanAdministrator(AdminFanAdministratorUpdate(user: active, administrator: false))
            // Do not refresh the fan hint first: an existing native admin
            // session must be denied by the real backend immediately.
            do {
                _ = try await bound.fetchFanUser(userID: profile.userID)
                throw CheckFailure.revocation
            } catch AdminAPIError.insufficientPermission {
                guard !bound.isAuthenticated else { throw CheckFailure.revocation }
            } catch AdminAPIError.invalidCredentials {
                guard !bound.isAuthenticated else { throw CheckFailure.revocation }
            }
            await account.refreshSession()
            guard account.isApproved, account.administratorContext == nil else { throw CheckFailure.revocation }
        } catch {
            print("native-review-failed-phase: \(phase); error-type: \(type(of: error))")
            failure = error
        }
        // Always attempt the normal user-facing delete API, including after a
        // failed intermediate assertion. The runner has a separate recovery path.
        if account.profile != nil {
            await account.deleteAccount(currentPassword: password)
            guard let userID, account.removedAccountUserID == userID,
                  !account.isAuthenticated else { throw CheckFailure.deletion }
        }
        if let failure { throw failure }
        if let temporaryPortfolioID {
            // Removing a staff account must not silently remove artist-owned
            // published gallery media. The runner separately cleans fixtures.
            let afterDeletion = try await owner.fetchContent()
            let remaining = afterDeletion.portfolios.first(where: { $0.id == temporaryPortfolioID })
            print("native-review-media-retention: album-present=\(remaining != nil); image-count=\(remaining?.images.count ?? 0)")
            guard remaining?.images.count == 2 else {
                print("native-review-failed-phase: published-media-after-account-deletion")
                throw CheckFailure.publishedMediaRetention
            }
        }
        guard let identityCode else { throw CheckFailure.registration }
        await account.signIn(identityCode: identityCode, password: password)
        guard !account.isAuthenticated,
              account.errorMessage == FanAccountError.invalidCredentials.errorDescription else {
            throw CheckFailure.deletedLogin
        }
    }
}

@MainActor
private final class BoundAdministratorTestAccount: FanAdministratorAccount {
    var administratorContext: FanAdministratorContext? = .init(userID: "test-user", sessionGeneration: 1)
    let changes = PassthroughSubject<Void, Never>()
    var administratorChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    func authorizeAdministratorRequest(_ request: inout URLRequest, context: FanAdministratorContext) throws {
        guard administratorContext == context else { throw AdminAPIError.invalidCredentials }
        request.setValue("Bearer synthetic-session", forHTTPHeaderField: "Authorization")
        request.setValue("synthetic-installation", forHTTPHeaderField: "X-Yishu-Install-ID")
    }
}

/// Must also run with -configuration Release; the previous CharacterSet method
/// reference behaved differently under Swift 6.4's optimized compilation.
final class ContentIdentifierReleaseRegressionTests: XCTestCase {
    private func manifest(id: String, poster: Bool) throws -> AppContentManifest {
        let image = try XCTUnwrap(URL(string: "https://www.shuzijun.com.cn/test/identifier.jpg"))
        let destination = try XCTUnwrap(URL(string: "https://novelquickapp.com/s/identifier-test/"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let launch = LaunchPosterContent(id: id, isEnabled: true, imageURL: image,
            eyebrow: "东方美学", title: "测试", subtitle: "", startsAt: date,
            endsAt: date.addingTimeInterval(86_400), displaySeconds: 2.5)
        let drama = DramaWork(id: id, title: "测试", imageURL: image, destinationURL: destination)
        let value = AppContentManifest(schemaVersion: 1, updatedAt: date, heroImages: [image],
            aboutPortraitURL: nil, launchPosters: poster ? [launch] : [], showreel: nil,
            dramas: poster ? [] : [drama], portfolios: [], contentAudience: .administrator)
        // Exercise decoded remote input, not only compiler-visible string literals.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppContentManifest.self, from: encoder.encode(value))
    }

    func testEveryAllowedASCIICharacterIsAcceptedForPosterAndDramaIdentifiers() throws {
        let ids = "abcdefghijklmnopqrstuvwxyz0123456789-_".map(String.init)
            + ["synthetic-id", "launch_autumn-2026", "00000000-0000-4000-8000-000000000001",
               String(repeating: "a", count: 80)]
        for poster in [true, false] {
            for id in ids {
                let value = try manifest(id: id, poster: poster)
                XCTAssertTrue(ContentManifestPolicy.isValid(value))
                XCTAssertTrue(ContentSecurityPolicy.isTrusted(value))
            }
        }
    }

    func testNonASCIIAndUnsafeIdentifiersAreRejectedInBothCollections() throws {
        let ids = ["", " ", "UPPER", "has space", "dot.id", "path/id", "query?id",
                   "back\\\\slash", "line\nbreak", "zero\u{0000}byte", "é", "ｅ", "中文", "🙂",
                   "e\u{0301}", String(repeating: "a", count: 81)]
        for poster in [true, false] {
            for id in ids {
                let value = try manifest(id: id, poster: poster)
                XCTAssertFalse(ContentManifestPolicy.isValid(value))
                XCTAssertFalse(ContentSecurityPolicy.isTrusted(value))
            }
        }
    }
}

@MainActor
final class BoundAdministratorSessionTests: XCTestCase {
    func testRoleHintNeverBypassesApprovalIdentityOrSessionRequirements() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let base: [String: Any] = [
            "userID": "00000000-0000-4000-8000-000000000001", "identityCode": "HS-ABCD-2345",
            "displayName": "测试", "douyinID": "test_douyin", "installationCode": "IN-ABC-234",
            "permissions": ["gallery_full"], "status": "active",
            "sessionExpiresAt": "2099-01-01T00:00:00Z", "administratorBound": true,
        ]
        func decode(_ values: [String: Any]) throws -> FanProfile {
            try decoder.decode(FanProfile.self, from: JSONSerialization.data(withJSONObject: values))
        }
        let profile = try decode(base)
        func eligible(_ profile: FanProfile?, token: Bool = true, credential: Bool = true,
                      pendingApple: Bool = false) -> FanAdministratorContext? {
            FanAdministratorEligibility.context(profile: profile, hasSessionToken: token,
                credentialAccessAllowed: credential, hasPendingAppleRegistration: pendingApple,
                sessionGeneration: 4)
        }
        XCTAssertEqual(eligible(profile)?.sessionGeneration, 4)
        XCTAssertNil(eligible(nil))
        XCTAssertNil(eligible(profile, token: false))
        XCTAssertNil(eligible(profile, credential: false))
        XCTAssertNil(eligible(profile, pendingApple: true))
        let changes: [[String: Any]] = [
            ["administratorBound": false], ["status": "pending"], ["status": "suspended"],
            ["status": "rejected"], ["douyinID": ""], ["requiresAccountSetup": true],
            ["requiresPasswordChange": true], ["requiresAppleRegistration": true],
            ["sessionExpiresAt": "2000-01-01T00:00:00Z"],
        ]
        for change in changes {
            XCTAssertNil(eligible(try decode(base.merging(change) { _, new in new })), "\(change)")
        }
        var legacy = base
        legacy.removeValue(forKey: "administratorBound")
        XCTAssertNil(eligible(try decode(legacy)))
        XCTAssertThrowsError(try decode(base.merging(["administratorBound": "true"]) { _, new in new }))
    }

    private func reply(_ request: URLRequest, status: Int = 200, body: String? = nil) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (Data((body ?? #"{"authenticated":true,"role":"yishu_content_manager","displayName":"测试管理员"}"#).utf8), response)
    }

    private func diagnosticManifestData(
        schemaVersion: Int = 1,
        audience: AppContentAudience = .administrator,
        loadedImages: Int = 2,
        totalImages: Int = 2,
        untrustedHero: Bool = false
    ) throws -> Data {
        let imageURL = try XCTUnwrap(URL(string: "https://www.shuzijun.com.cn/wp-content/uploads/diagnostic-fixture.jpg"))
        let heroURL = untrustedHero
            ? try XCTUnwrap(URL(string: "https://untrusted.example/diagnostic-fixture-marker.jpg"))
            : imageURL
        let images = (0..<loadedImages).map { index in
            PortfolioImage(id: index + 1, url: imageURL, fullSizeURL: imageURL, altText: "诊断夹具")
        }
        let portfolio = Portfolio(id: 101, title: "诊断夹具", subtitle: "", eyebrow: "", slug: "diagnostic-fixture",
            websiteURL: try XCTUnwrap(URL(string: "https://www.shuzijun.com.cn/portfolio/diagnostic-fixture/")),
            coverURL: imageURL, images: images, totalImageCount: totalImages)
        let manifest = AppContentManifest(schemaVersion: schemaVersion,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), heroImages: [heroURL],
            aboutPortraitURL: nil, launchPosters: [], showreel: nil, dramas: [],
            portfolios: [portfolio], contentAudience: audience)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func assertAdministratorContentFailure(
        _ expected: AdminContentFailureStage,
        body: Data,
        mime: String = "application/json",
        responseURL: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let account = BoundAdministratorTestAccount()
        var sessionRequests = 0
        var contentRequests = 0
        let admin = AdminSessionStore { request in
            if request.url?.path == "/wp-json/shuzijun/v1/app-admin/session" {
                sessionRequests += 1
                return try self.reply(request)
            }
            contentRequests += 1
            XCTAssertEqual(request.httpMethod, "GET", file: file, line: line)
            XCTAssertEqual(request.url?.path, "/wp-json/shuzijun/v1/app-content", file: file, line: line)
            let url = try XCTUnwrap(responseURL ?? request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": mime]))
            return (body, response)
        }
        defer { admin.lock() }
        await admin.signIn(using: account)
        XCTAssertTrue(admin.isAuthenticated, file: file, line: line)
        do {
            _ = try await admin.fetchContent()
            XCTFail("Invalid administrator content was accepted", file: file, line: line)
        } catch let error as AdminAPIError {
            guard case .contentLoadFailed(let actual) = error else {
                XCTFail("Content failure did not report a bounded diagnostic stage", file: file, line: line)
                return
            }
            XCTAssertEqual(actual, expected, file: file, line: line)
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.contains(expected.rawValue), file: file, line: line)
            for prohibited in ["diagnostic-fixture-marker", "untrusted.example", "synthetic-session", "https://", "<html>"] {
                XCTAssertFalse(message.contains(prohibited), "Diagnostic exposed input content", file: file, line: line)
            }
        } catch {
            XCTFail("Content failure escaped the safe administrator error boundary", file: file, line: line)
        }
        XCTAssertTrue(admin.isAuthenticated, "A content-format failure must not invalidate a verified account", file: file, line: line)
        XCTAssertEqual(sessionRequests, 1, file: file, line: line)
        XCTAssertEqual(contentRequests, 1, "Malformed content must not trigger automatic retries", file: file, line: line)
    }

    func testAdministratorContentStageCodesRemainStableAndMessagesContainNoInput() {
        let expected: [(AdminContentFailureStage, String)] = [
            (.responseTooLarge, "AC01"), (.responseOrigin, "AC02"), (.responseFormat, "AC03"),
            (.decoding, "AC04"), (.contentPolicy, "AC05"), (.incompleteManifest, "AC06"),
        ]
        XCTAssertEqual(AdminContentFailureStage.allCases.count, expected.count)
        for (stage, code) in expected {
            XCTAssertEqual(stage.rawValue, code)
            let message = AdminAPIError.contentLoadFailed(stage).errorDescription ?? ""
            XCTAssertTrue(message.contains(code))
            XCTAssertFalse(message.contains("https://"))
            XCTAssertFalse(message.contains("Bearer"))
        }
    }

    func testAdministratorContentRejectsHTMLAndEmptySuccessfulBodiesAtFormatStage() async throws {
        try await assertAdministratorContentFailure(.responseFormat,
            body: Data("<html>diagnostic-fixture-marker synthetic-session</html>".utf8), mime: "text/html")
        try await assertAdministratorContentFailure(.responseFormat, body: Data())
    }

    func testAdministratorContentReportsMissingAndWrongTypedJSONAtDecodingStage() async throws {
        try await assertAdministratorContentFailure(.decoding, body: Data("{}".utf8))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticManifestData()) as? [String: Any])
        object["heroImages"] = ["invalid": "diagnostic-fixture-marker"]
        try await assertAdministratorContentFailure(.decoding, body: JSONSerialization.data(withJSONObject: object))
    }

    func testAdministratorContentRejectsUnexpectedResponseOriginBeforeDecoding() async throws {
        let other = try XCTUnwrap(URL(string: "https://untrusted.example/diagnostic-fixture-marker"))
        try await assertAdministratorContentFailure(.responseOrigin, body: diagnosticManifestData(), responseURL: other)
    }

    func testAdministratorContentRejectsMoreThanEightMiBAtSizeStage() async throws {
        try await assertAdministratorContentFailure(.responseTooLarge,
            body: Data(repeating: 65, count: 8 * 1024 * 1024 + 1))
    }

    func testAdministratorContentReportsInvalidSchemaAndUntrustedMediaAtPolicyStage() async throws {
        try await assertAdministratorContentFailure(.contentPolicy, body: diagnosticManifestData(schemaVersion: 999))
        try await assertAdministratorContentFailure(.contentPolicy, body: diagnosticManifestData(untrustedHero: true))
    }

    func testAdministratorContentRejectsValidViewerAndPartialAdministratorManifests() async throws {
        try await assertAdministratorContentFailure(.incompleteManifest, body: diagnosticManifestData(audience: .viewer))
        try await assertAdministratorContentFailure(.incompleteManifest,
            body: diagnosticManifestData(loadedImages: 1, totalImages: 2))
    }

    func testAdministratorContentAcceptsACompleteVerifiedManifestWithoutAdditionalRequests() async throws {
        let body = try diagnosticManifestData()
        let account = BoundAdministratorTestAccount()
        var calls = 0
        let admin = AdminSessionStore { request in
            calls += 1
            if request.url?.path == "/wp-json/shuzijun/v1/app-admin/session" { return try self.reply(request) }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/wp-json/shuzijun/v1/app-content")
            return try self.reply(request, body: String(decoding: body, as: UTF8.self))
        }
        defer { admin.lock() }
        await admin.signIn(using: account)
        let manifest = try await admin.fetchContent()
        XCTAssertTrue(admin.isAuthenticated)
        XCTAssertTrue(ContentSecurityPolicy.isTrusted(manifest))
        XCTAssertTrue(AdminContentEditingPolicy.isFullAdministratorManifest(manifest))
        XCTAssertEqual(manifest.portfolios.count, 1)
        XCTAssertEqual(manifest.portfolios.first?.images.count, 2)
        XCTAssertEqual(calls, 2)
    }

    func testAdministratorContentAuthorizationDenialsStillLockAndRetainOriginalErrorCases() async throws {
        for status in [401, 403] {
            let account = BoundAdministratorTestAccount()
            var calls = 0
            let admin = AdminSessionStore { request in
                calls += 1
                if request.url?.path == "/wp-json/shuzijun/v1/app-admin/session" { return try self.reply(request) }
                return try self.reply(request, status: status,
                    body: #"{"code":"forbidden","message":"diagnostic-fixture-marker synthetic-session"}"#)
            }
            await admin.signIn(using: account)
            XCTAssertTrue(admin.isAuthenticated)
            do {
                _ = try await admin.fetchContent()
                XCTFail("Authorization denial was accepted")
            } catch let error as AdminAPIError {
                switch error {
                case .invalidCredentials: XCTAssertEqual(status, 401)
                case .insufficientPermission: XCTAssertEqual(status, 403)
                default: XCTFail("Authorization denial was replaced with a content diagnostic")
                }
                XCTAssertFalse((error.errorDescription ?? "").contains("diagnostic-fixture-marker"))
                XCTAssertFalse((error.errorDescription ?? "").contains("synthetic-session"))
            } catch {
                XCTFail("Authorization denial escaped the safe administrator error boundary")
            }
            XCTAssertFalse(admin.isAuthenticated)
            XCTAssertEqual(calls, 2)
            admin.lock()
        }
    }

    func testAdministratorContentStageDoesNotReplaceSessionProbeErrors() async throws {
        let account = BoundAdministratorTestAccount()
        let admin = AdminSessionStore { request in
            try self.reply(request, body: #"{"displayName":"diagnostic-fixture-marker"}"#)
        }
        defer { admin.lock() }
        await admin.signIn(using: account)
        XCTAssertFalse(admin.isAuthenticated)
        XCTAssertEqual(admin.errorMessage, AdminAPIError.invalidResponse.errorDescription)
    }

    /// Opt-in diagnostic: a runner may place a credential-free content response
    /// in this test host's temporary directory. It is never a bundled fixture,
    /// and both requests below are intercepted without contacting any server.
    func testOptInSimulatorAdministratorContentDiagnosticThroughBoundSession() async throws {
#if targetEnvironment(simulator)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("administrator-content-diagnostic.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("No opt-in administrator content diagnostic fixture")
        }
        let data: Data
        do {
            let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let count = metadata.fileSize, (1...(8 * 1024 * 1024)).contains(count) else {
                XCTFail("administrator-content-diagnostic: fixture-type-or-size-rejected")
                return
            }
            data = try Data(contentsOf: file)
            guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else {
                XCTFail("administrator-content-diagnostic: fixture-size-rejected")
                return
            }
        } catch {
            // Do not include a filesystem path, body, account or raw error.
            XCTFail("administrator-content-diagnostic: fixture-unreadable")
            return
        }

        let account = BoundAdministratorTestAccount()
        var sessionRequests = 0
        var contentRequests = 0
        var unexpectedRequests = 0
        let admin = AdminSessionStore(environment: .production) { request in
            guard request.httpMethod == "GET", let url = request.url else {
                unexpectedRequests += 1
                throw AdminAPIError.invalidResponse
            }
            switch url.path {
            case "/wp-json/shuzijun/v1/app-admin/session":
                sessionRequests += 1
                return try self.reply(request)
            case "/wp-json/shuzijun/v1/app-content":
                contentRequests += 1
                guard let response = HTTPURLResponse(url: url, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json; charset=UTF-8"]) else {
                    throw AdminAPIError.invalidResponse
                }
                return (data, response)
            default:
                unexpectedRequests += 1
                throw AdminAPIError.invalidResponse
            }
        }
        defer { admin.lock() }
        await admin.signIn(using: account)
        guard admin.isAuthenticated else {
            XCTFail("administrator-content-diagnostic: synthetic-session-rejected; requests=\(sessionRequests)")
            return
        }
        XCTAssertFalse(admin.isIndependentAdministrator)
        do {
            let manifest = try await admin.fetchContent()
            XCTAssertTrue(ContentSecurityPolicy.isTrusted(manifest, environment: .production),
                "administrator-content-diagnostic: content-security-policy-rejected")
            XCTAssertTrue(AdminContentEditingPolicy.isFullAdministratorManifest(manifest),
                "administrator-content-diagnostic: administrator-completeness-rejected")
            XCTAssertEqual(sessionRequests, 1)
            XCTAssertEqual(contentRequests, 1)
            XCTAssertEqual(unexpectedRequests, 0)
            print("administrator-content-diagnostic: bytes=\(data.count); portfolios=\(manifest.portfolios.count); images=\(manifest.portfolios.reduce(0) { $0 + $1.images.count }); dramas=\(manifest.dramas.count)")
        } catch {
            let stage: String
            if case let AdminAPIError.contentLoadFailed(failure) = error {
                stage = failure.rawValue
            } else {
                stage = "other"
            }
            XCTFail("administrator-content-diagnostic: fetch-content-rejected; stage=\(stage); bytes=\(data.count); sessionRequests=\(sessionRequests); contentRequests=\(contentRequests); unexpectedRequests=\(unexpectedRequests)")
        }
#else
        throw XCTSkip("Administrator content diagnostic is simulator-only")
#endif
    }

    func testBoundAccountMustPassServerProbeAndNeverBecomesIndependentAdministrator() async throws {
        let account = BoundAdministratorTestAccount()
        var requests = [URLRequest]()
        let admin = AdminSessionStore { request in
            requests.append(request)
            return try self.reply(request)
        }
        XCTAssertFalse(admin.isAuthenticated)
        await admin.signIn(using: account)
        XCTAssertTrue(admin.isAuthenticated)
        XCTAssertFalse(admin.isIndependentAdministrator)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/wp-json/shuzijun/v1/app-admin/session")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Yishu-Install-ID"), "synthetic-installation")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        admin.signOut()
        XCTAssertFalse(admin.isAuthenticated)
    }

    func testMissingLocalEligibilityNeverSendsManagementRequest() async {
        let account = BoundAdministratorTestAccount()
        account.administratorContext = nil
        var calls = 0
        let admin = AdminSessionStore { request in
            calls += 1
            return try self.reply(request)
        }
        await admin.signIn(using: account)
        XCTAssertFalse(admin.isAuthenticated)
        XCTAssertEqual(calls, 0)
    }

    func testOtherEnvironmentCannotSendAnAdministratorProbe() async {
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            let account = BoundAdministratorTestAccount()
            account.administratorContext = .init(userID: "test-user", sessionGeneration: 1, environment: other)
            var calls = 0
            let admin = AdminSessionStore(environment: environment) { request in
                calls += 1
                return try self.reply(request)
            }
            await admin.signIn(using: account)
            XCTAssertEqual(calls, 0)
            XCTAssertFalse(admin.isAuthenticated)
            XCTAssertNotNil(admin.errorMessage)
        }
    }

    func testAdministratorProbeUsesOnlyItsSelectedEnvironment() async {
        for environment in AppServiceEnvironment.allCases {
            let account = BoundAdministratorTestAccount()
            account.administratorContext = .init(userID: "test-user", sessionGeneration: 1, environment: environment)
            var requests = [URLRequest]()
            let admin = AdminSessionStore(environment: environment) { request in
                requests.append(request)
                return try self.reply(request)
            }
            await admin.signIn(using: account)
            XCTAssertTrue(admin.isAuthenticated)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.host, environment.apiHost)
            XCTAssertEqual(requests.first?.url?.path, "/wp-json/shuzijun/v1/app-admin/session")
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
            admin.lock()
        }
    }

    func testAdministratorRejectsSuccessfulResponseFromOtherEnvironment() async throws {
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            let account = BoundAdministratorTestAccount()
            account.administratorContext = .init(userID: "test-user", sessionGeneration: 1, environment: environment)
            let admin = AdminSessionStore(environment: environment) { request in
                let (data, _) = try self.reply(request)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: other.apiRoot.appending(path: "shuzijun/v1/app-admin/session"),
                    statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                return (data, response)
            }
            await admin.signIn(using: account)
            XCTAssertFalse(admin.isAuthenticated)
            XCTAssertNotNil(admin.errorMessage)
        }
    }

    func testEnvironmentReplacementInvalidatesMatchingAdministratorIdentity() async throws {
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            let account = BoundAdministratorTestAccount()
            account.administratorContext = .init(userID: "test-user", sessionGeneration: 1, environment: environment)
            var calls = 0
            let admin = AdminSessionStore(environment: environment) { request in
                calls += 1
                return try self.reply(request)
            }
            await admin.signIn(using: account)
            XCTAssertTrue(admin.isAuthenticated)
            account.administratorContext = .init(userID: "test-user", sessionGeneration: 1, environment: other)
            XCTAssertFalse(admin.isAuthenticated)
            do {
                _ = try await admin.fetchFeatureCapabilities()
                XCTFail("Cross-environment replacement sent a management request")
            } catch { XCTAssertEqual(calls, 1) }
            admin.lock()
        }
    }

    func testIndependentAdministratorUsesSelectedEnvironment() async {
        for environment in AppServiceEnvironment.allCases {
            var requests = [URLRequest]()
            let admin = AdminSessionStore(environment: environment) { request in
                requests.append(request)
                return try self.reply(request)
            }
            await admin.signIn(username: "synthetic-manager", applicationPassword: UUID().uuidString)
            XCTAssertTrue(admin.isIndependentAdministrator)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.host, environment.apiHost)
            XCTAssertTrue(requests.first?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
            admin.lock()
        }
    }

    func testLegacyAdministratorStillUsesSeparateBasicAuthentication() async throws {
        var authorization: String?
        var installation: String?
        let admin = AdminSessionStore { request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            installation = request.value(forHTTPHeaderField: "X-Yishu-Install-ID")
            return try self.reply(request)
        }
        await admin.signIn(username: "synthetic-manager", applicationPassword: UUID().uuidString)
        XCTAssertTrue(admin.isIndependentAdministrator)
        XCTAssertTrue(authorization?.hasPrefix("Basic ") == true)
        XCTAssertNil(installation)
        admin.lock()
    }

    func testLateProbeCannotUnlockForReplacementAccount() async throws {
        let account = BoundAdministratorTestAccount()
        let admin = AdminSessionStore { request in
            account.administratorContext = .init(userID: "other-user", sessionGeneration: 2)
            return try self.reply(request)
        }
        await admin.signIn(using: account)
        XCTAssertFalse(admin.isAuthenticated)
        XCTAssertFalse(admin.isWorking)
        admin.lock()
    }

    func testRevocationAndSameUserSessionReplacementInvalidateBeforeNextRequest() async throws {
        for replacement in [nil, FanAdministratorContext(userID: "test-user", sessionGeneration: 2),
                            FanAdministratorContext(userID: "other-user", sessionGeneration: 1)] {
            let account = BoundAdministratorTestAccount()
            var calls = 0
            let admin = AdminSessionStore { request in
                calls += 1
                return try self.reply(request)
            }
            await admin.signIn(using: account)
            XCTAssertTrue(admin.isAuthenticated)
            // No publisher notification needed to prevent a request with stale credentials.
            account.administratorContext = replacement
            XCTAssertFalse(admin.isAuthenticated)
            do {
                _ = try await admin.fetchFeatureCapabilities()
                XCTFail("Stale account sent a management request")
            } catch { XCTAssertEqual(calls, 1) }
            admin.lock()
        }
    }

    func testServerDenialAndMisleadingSuccessDoNotUnlock() async throws {
        for (status, body) in [(403, #"{"code":"forbidden","message":"无权限"}"#),
                               (200, #"{"displayName":"未验证"}"#),
                               (200, #"{"authenticated":true,"role":"subscriber","displayName":"普通用户"}"#)] {
            let account = BoundAdministratorTestAccount()
            let admin = AdminSessionStore { request in try self.reply(request, status: status, body: body) }
            await admin.signIn(using: account)
            XCTAssertFalse(admin.isAuthenticated)
            XCTAssertNotNil(admin.errorMessage)
        }
    }

    func testLegacyAdministratorRequiresVerifiedRoleAndCanRetryAfterInvalidReply() async throws {
        let invalidReplies = [
            #"{"displayName":"未验证"}"#,
            #"{"authenticated":false,"role":"yishu_content_manager","displayName":"未验证","canManageFanAdministrators":true}"#,
            #"{"authenticated":true,"role":"subscriber","displayName":"普通用户"}"#,
            #"{"authenticated":true,"displayName":"缺少角色"}"#,
            #"{"authenticated":true,"role":"yishu_content_manager","displayName":"  "}"#,
        ]
        for invalidReply in invalidReplies {
            var requests = 0
            let admin = AdminSessionStore { request in
                requests += 1
                return try self.reply(request, body: requests == 1 ? invalidReply : nil)
            }
            let fixture = UUID().uuidString
            await admin.signIn(username: "isolated-test-admin", applicationPassword: fixture)
            XCTAssertFalse(admin.isAuthenticated, invalidReply)
            XCTAssertFalse(admin.isIndependentAdministrator)
            XCTAssertFalse(admin.canManageFanAdministrators)
            XCTAssertNotNil(admin.errorMessage)
            XCTAssertFalse(admin.isWorking)
            do {
                _ = try await admin.fetchFeatureCapabilities()
                XCTFail("Unverified session was allowed to request management data")
            } catch { XCTAssertEqual(requests, 1) }

            await admin.signIn(username: "isolated-test-admin", applicationPassword: fixture)
            XCTAssertTrue(admin.isAuthenticated)
            XCTAssertTrue(admin.isIndependentAdministrator)
            XCTAssertNil(admin.errorMessage)
            XCTAssertEqual(requests, 2)
            admin.signOut()
        }
    }

    func testLateProbeCannotUnlockAfterLogout() async throws {
        let account = BoundAdministratorTestAccount()
        var admin: AdminSessionStore?
        let store = AdminSessionStore { request in
            admin?.signOut()
            return try self.reply(request)
        }
        admin = store
        await store.signIn(using: account)
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(store.isWorking)
    }

    func testVisibilityMutationChecksRequestAndMatchingAdministratorResponse() async throws {
        let account = BoundAdministratorTestAccount()
        var album = Portfolio(id: 91, title: "测试相册", subtitle: "", eyebrow: "", slug: "visibility-test",
            websiteURL: try XCTUnwrap(URL(string: "https://www.shuzijun.com.cn/portfolio/visibility-test/")),
            coverURL: nil, images: [])
        album.isVisible = true
        var saved = album
        saved.isVisible = false
        let content = AppContentManifest(schemaVersion: 1, updatedAt: .now,
            heroImages: [try XCTUnwrap(URL(string: "https://www.shuzijun.com.cn/wp-content/uploads/visibility-test.jpg"))],
            aboutPortraitURL: nil, launchPosters: [], showreel: nil,
            dramas: [], portfolios: [saved], contentAudience: .administrator)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let contentObject = try JSONSerialization.jsonObject(with: encoder.encode(content))
        var returnedID = album.id
        var writes = 0
        let admin = AdminSessionStore { request in
            if request.url?.path.hasSuffix("/session") == true { return try self.reply(request) }
            writes += 1
            XCTAssertTrue(try XCTUnwrap(request.url).path.hasSuffix("/portfolio/\(album.id)/visibility"))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Bool])
            XCTAssertEqual(object, ["isVisible": false, "expectedIsVisible": true])
            let response = try JSONSerialization.data(withJSONObject: [
                "portfolioID": returnedID, "isVisible": false, "content": contentObject])
            return try self.reply(request, body: String(decoding: response, as: UTF8.self))
        }
        await admin.signIn(using: account)
        let accepted = try await admin.updatePortfolioVisibility(album, isVisible: false)
        XCTAssertEqual(accepted.portfolios.first?.isVisible, false)
        returnedID += 1
        do {
            _ = try await admin.updatePortfolioVisibility(album, isVisible: false)
            XCTFail("A response for another album was accepted")
        } catch { XCTAssertEqual(writes, 2, "Mismatched writes must never retry automatically") }
        admin.lock()
    }

    func testVisibilityConflictDoesNotRetryOrSignOutAdministrator() async throws {
        let account = BoundAdministratorTestAccount()
        let album = Portfolio(id: 91, title: "测试相册", subtitle: "", eyebrow: "", slug: "visibility-test",
            websiteURL: try XCTUnwrap(URL(string: "https://www.shuzijun.com.cn/portfolio/visibility-test/")),
            coverURL: nil, images: [])
        var writes = 0
        let admin = AdminSessionStore { request in
            if request.url?.path.hasSuffix("/session") == true { return try self.reply(request) }
            writes += 1
            return try self.reply(request, status: 409,
                body: #"{"code":"portfolio_visibility_conflict","message":"请刷新后重试","data":{"status":409}}"#)
        }
        await admin.signIn(using: account)
        do {
            _ = try await admin.updatePortfolioVisibility(album, isVisible: false)
            XCTFail("Conflict was reported as a successful save")
        } catch { XCTAssertEqual(writes, 1) }
        XCTAssertTrue(admin.isAuthenticated)
        admin.lock()
    }

    func testAccountPublisherLocksVisibleManagementState() async throws {
        let account = BoundAdministratorTestAccount()
        let admin = AdminSessionStore { request in try self.reply(request) }
        await admin.signIn(using: account)
        let locked = expectation(description: "Account removal publishes locked role")
        let observation = admin.$role.dropFirst().sink { role in
            if role == .visitor { locked.fulfill() }
        }
        account.changes.send()
        account.administratorContext = nil
        await fulfillment(of: [locked], timeout: 2)
        XCTAssertFalse(admin.isAuthenticated)
        observation.cancel()
    }

    func testLateManagementResponseCannotCrossAccountBoundary() async throws {
        let account = BoundAdministratorTestAccount()
        var calls = 0
        let admin = AdminSessionStore { request in
            calls += 1
            if calls > 1 {
                account.administratorContext = .init(userID: "other-user", sessionGeneration: 2)
                return try self.reply(request, body: #"{"collaborationEnabled":false}"#)
            }
            return try self.reply(request)
        }
        await admin.signIn(using: account)
        do {
            _ = try await admin.fetchFeatureCapabilities()
            XCTFail("Old account response was accepted")
        } catch let error as AdminAPIError {
            guard case .invalidCredentials = error else { return XCTFail("Wrong rejection: \(error)") }
        }
        XCTAssertFalse(admin.isAuthenticated)
        admin.lock()
    }
}

private enum TestCredentialFixture {
    static let currentValue = makeValue(label: "current")
    static let replacementValue = makeValue(label: "replacement")
    static let unchangedValue = makeValue(label: "unchanged")
    static let temporaryValue = "Tmp-" + String(repeating: "T", count: 24) + "-9!"
    static let weakValue = "weak"

    private static func makeValue(label: String) -> String {
        ["not", "a", "credential", label, "2026"].joined(separator: "-")
    }
}

@MainActor
final class AdministratorBindingTests: XCTestCase {
    func testOrdinaryAdminRequestsDoNotShareLargeUploadDeadlinesOrCaches() {
        let json = AdminTransportPolicy.makeJSONSession()
        let upload = AdminTransportPolicy.makeUploadSession()
        defer { json.invalidateAndCancel(); upload.invalidateAndCancel() }
        XCTAssertFalse(json === upload)
        XCTAssertEqual(json.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(json.configuration.timeoutIntervalForResource, 45)
        XCTAssertEqual(upload.configuration.timeoutIntervalForRequest, 120)
        XCTAssertEqual(upload.configuration.timeoutIntervalForResource, 180)
        for transport in [json, upload] {
            XCTAssertNil(transport.configuration.urlCache)
            XCTAssertNil(transport.configuration.urlCredentialStorage)
            XCTAssertEqual(transport.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        }
        XCTAssertEqual(AdminTransportPolicy.requestTimeout(path: "wp/v2/media"), 120)
        for path in ["shuzijun/v1/app-admin/session", "shuzijun/v1/app-admin/fans",
                     "shuzijun/v1/app-content", "shuzijun/v1/app-admin/push-notifications"] {
            XCTAssertEqual(AdminTransportPolicy.requestTimeout(path: path), 30)
        }
    }

    func testTimedOutAdministratorMutationIsNotAutomaticallyRetriedOrReportedSuccessful() async throws {
        let account = BoundAdministratorTestAccount()
        var calls = 0
        let admin = AdminSessionStore { request in
            calls += 1
            XCTAssertEqual(request.timeoutInterval, 30)
            if calls == 1 { return try self.response(request, body: self.sessionBody) }
            throw URLError(.timedOut)
        }
        await admin.signIn(using: account)
        do {
            _ = try await admin.updateFanAdministrator(.init(user: user(), administrator: true))
            XCTFail("Timed-out mutation was reported successful")
        } catch let error as AdminAPIError {
            guard case .networkUnavailable = error else { return XCTFail("Unexpected failure") }
        }
        XCTAssertEqual(calls, 2, "Do not retry a write whose server outcome is unknown")
        XCTAssertTrue(admin.isAuthenticated, "Network outage is not credential revocation")
        admin.retireForEnvironmentSwitch()
    }

    private func user(bound: Bool? = false, revision: Int? = 7, status: String = "active",
                      douyin: String = "test_douyin", userID: String = "00000000-0000-4000-8000-000000000001") -> AdminFanUser {
        AdminFanUser(userID: userID, identityCode: "HS-ABCD-2345", displayName: "测试用户",
                     douyinID: douyin, permissions: ["gallery_full"], status: status,
                     registeredAt: Date(timeIntervalSince1970: 1_700_000_000), reviewedAt: nil,
                     administratorBound: bound, administratorRevision: revision)
    }

    private func response(_ request: URLRequest, code: Int = 200, body: Data) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        return (body, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])))
    }

    private func profileBody(_ user: AdminFanUser) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(["user": user])
    }

    private let sessionBody = Data(#"{"authenticated":true,"role":"yishu_content_manager","displayName":"测试管理员","canManageFanAdministrators":true}"#.utf8)

    func testRequestRequiresKnownRevisionAndContainsOnlyExplicitBindingFields() throws {
        let update = try AdminFanAdministratorUpdate(user: user(), administrator: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["administrator", "expectedAdministrator", "expectedRevision"])
        XCTAssertEqual(body["administrator"] as? Bool, true)
        XCTAssertEqual(body["expectedAdministrator"] as? Bool, false)
        XCTAssertEqual(body["expectedRevision"] as? Int, 7)
        for invalid in [user(bound: nil, revision: nil), user(bound: nil), user(revision: nil),
                        user(revision: -1), user(revision: Int.max), user(status: "pending"),
                        user(status: "suspended"), user(douyin: ""), user(userID: "../other")] {
            XCTAssertThrowsError(try AdminFanAdministratorUpdate(user: invalid, administrator: true))
        }
        XCTAssertNoThrow(try AdminFanAdministratorUpdate(user: user(bound: true, status: "suspended"), administrator: false))
        XCTAssertFalse(FanAccountValidation.isValidAdminFanUser(user(bound: true, revision: nil)))
        XCTAssertTrue(FanAccountValidation.isValidAdminFanUser(user(bound: nil, revision: nil)))
    }

    func testResponseMustMatchUserDesiredRoleAndExactRevision() throws {
        let change = try AdminFanAdministratorUpdate(user: user(), administrator: true)
        XCTAssertTrue(change.accepts(user(bound: true, revision: 8)))
        XCTAssertFalse(change.accepts(user(bound: true, revision: 7)))
        XCTAssertFalse(change.accepts(user(bound: true, revision: 9)))
        XCTAssertFalse(change.accepts(user(bound: false, revision: 8)))
        XCTAssertFalse(change.accepts(user(bound: true, revision: 8,
                                         userID: "00000000-0000-4000-8000-000000000002")))
        let noop = try AdminFanAdministratorUpdate(user: user(bound: true), administrator: true)
        XCTAssertTrue(noop.accepts(user(bound: true)))
    }

    func testGrantAndRevokeUseServerCapabilityAndExpectedState() async throws {
        for desired in [true, false] {
            let account = BoundAdministratorTestAccount()
            let before = user(bound: !desired)
            let after = user(bound: desired, revision: 8)
            var calls = 0
            let admin = AdminSessionStore { request in
                calls += 1
                XCTAssertEqual(request.timeoutInterval, 30)
                if calls == 1 { return try self.response(request, body: self.sessionBody) }
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/wp-json/shuzijun/v1/app-admin/fans/\(before.userID)/administrator")
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(body["administrator"] as? Bool, desired)
                XCTAssertEqual(body["expectedRevision"] as? Int, 7)
                return try self.response(request, body: self.profileBody(after))
            }
            await admin.signIn(using: account)
            XCTAssertTrue(admin.canManageFanAdministrators)
            let result = try await admin.updateFanAdministrator(.init(user: before, administrator: desired))
            XCTAssertEqual(result, after)
            XCTAssertEqual(calls, 2)
            admin.lock()
            XCTAssertFalse(admin.canManageFanAdministrators)
        }
    }

    func testMissingCapabilityAndSelfChangeAreRejectedBeforeMutation() async throws {
        for selfChange in [false, true] {
            let account = BoundAdministratorTestAccount()
            if selfChange { account.administratorContext = .init(userID: user().userID, sessionGeneration: 1) }
            var calls = 0
            let admin = AdminSessionStore { request in
                calls += 1
                let body = selfChange ? self.sessionBody
                    : Data(#"{"authenticated":true,"role":"yishu_content_manager","displayName":"旧服务端"}"#.utf8)
                return try self.response(request, body: body)
            }
            await admin.signIn(using: account)
            do {
                _ = try await admin.updateFanAdministrator(.init(user: user(), administrator: true))
                XCTFail("Unauthorized mutation was allowed")
            } catch { XCTAssertEqual(calls, 1) }
            admin.lock()
        }
    }

    func testConflictIsNotRetriedAndDoesNotLockValidAdministrator() async throws {
        let account = BoundAdministratorTestAccount()
        var calls = 0
        let admin = AdminSessionStore { request in
            calls += 1
            if calls == 1 { return try self.response(request, body: self.sessionBody) }
            return try self.response(request, code: 409,
                body: Data(#"{"code":"fan_admin_conflict","message":"refresh required"}"#.utf8))
        }
        await admin.signIn(using: account)
        do {
            _ = try await admin.updateFanAdministrator(.init(user: user(), administrator: true))
            XCTFail("Conflict was treated as success")
        } catch let error as AdminAPIError {
            guard case .administratorConflict = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(admin.isAuthenticated)
        admin.lock()
    }

    func testRefreshUsesExactUserAndRejectsDifferentUserResponse() async throws {
        for wrongUser in [false, true] {
            let account = BoundAdministratorTestAccount()
            let target = user()
            var calls = 0
            let admin = AdminSessionStore { request in
                calls += 1
                if calls == 1 { return try self.response(request, body: self.sessionBody) }
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/wp-json/shuzijun/v1/app-admin/fans/\(target.userID)")
                let returned = wrongUser ? self.user(userID: "00000000-0000-4000-8000-000000000002") : target
                return try self.response(request, body: self.profileBody(returned))
            }
            await admin.signIn(using: account)
            do {
                let result = try await admin.fetchFanUser(userID: target.userID)
                XCTAssertFalse(wrongUser)
                XCTAssertEqual(result, target)
            } catch { XCTAssertTrue(wrongUser) }
            admin.lock()
        }
    }
}

@MainActor
private final class TestPushAuthorizationClient: PushAuthorizationClient {
    enum Outcome {
        case granted
        case denied
        case interrupted
    }

    var status: UNAuthorizationStatus
    var outcomes: [Outcome]
    var requestStarted: (() -> Void)?
    var pauseRequest = false
    private(set) var requestCount = 0
    private var requestContinuation: CheckedContinuation<Void, Never>?

    init(status: UNAuthorizationStatus = .notDetermined, outcomes: [Outcome] = []) {
        self.status = status
        self.outcomes = outcomes
    }

    func currentStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if pauseRequest, requestCount == 1 {
            await withCheckedContinuation { continuation in
                requestContinuation = continuation
                requestStarted?()
            }
        }
        guard !outcomes.isEmpty else {
            XCTFail("不应出现未配置的系统通知授权请求")
            throw URLError(.unknown)
        }
        switch outcomes.removeFirst() {
        case .granted:
            status = .authorized
            return true
        case .denied:
            status = .denied
            return false
        case .interrupted:
            throw URLError(.cancelled)
        }
    }

    func resumeRequest() {
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class TestPushDeviceRegistrationClient: PushDeviceRegistrationClient {
    private(set) var registrationCount = 0
    private(set) var unregistrationCount = 0
    var onRegister: (() -> Void)?

    func register() {
        registrationCount += 1
        onRegister?()
    }
    func unregister() { unregistrationCount += 1 }
}

@MainActor
private final class TestPushNotificationSleeper: PushNotificationSleeper {
    // Cancellation handlers can run off the main actor. A tiny synchronized
    // gate makes cancelled waits immediately invisible to the virtual clock,
    // including cancellation just before the continuation is installed.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var completed = false
        private var cancelled = false

        var isPending: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !completed
        }

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if completed {
                let wasCancelled = cancelled
                lock.unlock()
                if wasCancelled { continuation.resume(throwing: CancellationError()) }
                else { continuation.resume() }
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(cancelled: Bool = false) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            self.cancelled = cancelled
            let pending = continuation
            continuation = nil
            lock.unlock()
            if cancelled { pending?.resume(throwing: CancellationError()) }
            else { pending?.resume() }
        }
    }
    private struct Waiter {
        let duration: Duration
        let gate: Gate
    }
    private var waiters: [UUID: Waiter] = [:]
    var onSleep: ((Duration) -> Void)?

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let gate = Gate()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                waiters[id] = Waiter(duration: duration, gate: gate)
                onSleep?(duration)
            }
        } onCancel: {
            gate.finish(cancelled: true)
        }
        waiters.removeValue(forKey: id)
    }

    func isWaiting(for duration: Duration) -> Bool {
        waiters.values.contains { $0.duration == duration && $0.gate.isPending }
    }

    func advance(_ duration: Duration) {
        let ids = waiters.compactMap { $0.value.duration == duration ? $0.key : nil }
        for id in ids { waiters.removeValue(forKey: id)?.gate.finish() }
    }

    func cancelAll() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.gate.finish(cancelled: true) }
    }
}

@MainActor
private final class TestPushNotificationAccount: PushNotificationAccount {
    let serviceEnvironment: AppServiceEnvironment
    struct BindingAttempt: Equatable {
        let userID: String?
        let generation: UInt64
        let deviceToken: String
    }

    var pushEligibleUserID: String?
    var pushSessionGeneration: UInt64 = 1
    var hasPushEligibleSession: Bool { pushEligibleUserID != nil }
    var hasPushUnbindingSession = true
    var bindingFailuresRemaining = 0
    var bindingRequiresSignIn = false
    var pauseNextUnbind = false
    var unbindStarted: (() -> Void)?
    var bindingStarted: (() -> Void)?
    var pauseNextBinding = false
    private(set) var bindingAttempts: [BindingAttempt] = []
    private(set) var unbindCount = 0
    private var unbindContinuation: CheckedContinuation<Void, Never>?
    private var bindingContinuation: CheckedContinuation<Void, Never>?

    init(userID: String? = nil, environment: AppServiceEnvironment = .production) {
        serviceEnvironment = environment
        pushEligibleUserID = userID
    }

    func bindPushDevice(deviceToken: String) async throws {
        bindingAttempts.append(BindingAttempt(
            userID: pushEligibleUserID,
            generation: pushSessionGeneration,
            deviceToken: deviceToken
        ))
        bindingStarted?()
        if pauseNextBinding {
            pauseNextBinding = false
            await withCheckedContinuation { bindingContinuation = $0 }
        }
        if bindingRequiresSignIn { throw FanAccountError.sessionExpired }
        if bindingFailuresRemaining > 0 {
            bindingFailuresRemaining -= 1
            throw URLError(.notConnectedToInternet)
        }
    }

    func unbindPushDevice() async throws {
        unbindCount += 1
        if pauseNextUnbind {
            pauseNextUnbind = false
            await withCheckedContinuation { continuation in
                unbindContinuation = continuation
                unbindStarted?()
            }
        }
    }

    func resumeUnbind() {
        let continuation = unbindContinuation
        unbindContinuation = nil
        continuation?.resume()
    }

    func resumeBinding() {
        let continuation = bindingContinuation
        bindingContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class TestAppWorkspace: AppWorkspaceLifecycle {
    let serviceEnvironment: AppServiceEnvironment
    var events: (String) -> Void
    var waitForRetirement = false
    var retirementStarted: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?

    init(environment: AppServiceEnvironment, events: @escaping (String) -> Void) {
        serviceEnvironment = environment
        self.events = events
    }
    func activate() { events("activate-\(serviceEnvironment.rawValue)") }
    func retire() async {
        events("retire-start-\(serviceEnvironment.rawValue)")
        if waitForRetirement {
            await withCheckedContinuation {
                continuation = $0
                retirementStarted?()
            }
        }
        events("retire-end-\(serviceEnvironment.rawValue)")
    }
    func finishRetirement() { continuation?.resume(); continuation = nil }
}

final class ContentAndAccessTests: XCTestCase {
    func testTabSelectionCannotReferenceRevokedVideoTab() {
        for tab in AppTab.allCases {
            XCTAssertEqual(tab.resolved(canViewVideo: true), tab)
            XCTAssertEqual(tab.resolved(canViewVideo: false), tab == .credits ? .home : tab)
        }
    }

    func testGallerySelectionPreservesAvailablePhotoThroughReordering() {
        XCTAssertEqual(GallerySelection.resolve(2, imageIDs: [1, 2, 3]), 2)
        XCTAssertEqual(GallerySelection.resolve(2, imageIDs: [3, 2, 1]), 2)
    }

    func testGallerySelectionResolvesRemovedOrStaleInitialPhotoBeforeRendering() {
        XCTAssertEqual(GallerySelection.resolve(3, imageIDs: [1, 2]), 1)
        XCTAssertEqual(GallerySelection.resolve(99, imageIDs: [2]), 2)
        XCTAssertEqual(GallerySelection.resolve(0, imageIDs: [3, 4]), 3)
    }

    func testGallerySelectionDoesNotInventAPageWhenAccessIsRevoked() {
        XCTAssertNil(GallerySelection.resolve(3, imageIDs: []))
    }

    func testGallerySelectionRemainsValidAcrossSuccessiveManifestChanges() {
        var selection = 2
        for ids in [[1, 2, 3], [1, 3], [3], [], [4, 5]] {
            let resolved = GallerySelection.resolve(selection, imageIDs: ids)
            if let resolved {
                XCTAssertTrue(ids.contains(resolved))
                selection = resolved
            } else {
                XCTAssertTrue(ids.isEmpty)
            }
        }
    }

    func testWorkspaceSelectionPersistsOnlyKnownExplicitLocalValues() throws {
        let suite = "workspace-selection-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppWorkspaceSelection.restore(from: defaults), .production)
        for invalid in ["https://example.invalid", "REVIEW", "", "reviewer"] {
            defaults.set(invalid, forKey: AppWorkspaceSelection.key)
            XCTAssertEqual(AppWorkspaceSelection.restore(from: defaults), .production)
        }
        AppWorkspaceSelection.save(.review, to: defaults)
        XCTAssertEqual(AppWorkspaceSelection.restore(from: defaults), .review)
        AppWorkspaceSelection.save(.production, to: defaults)
        XCTAssertEqual(AppWorkspaceSelection.restore(from: defaults), .production)
    }

    @MainActor
    func testRetiredContentStoreCannotApplyLateManifestOrRestoreItsCache() async throws {
        let store = PortfolioStore(environment: .review)
        let manifest = try environmentManifest(.review)
        let refresh = store.beginContentRefresh()
        XCTAssertTrue(store.completeContentRefresh(refresh, with: manifest))
        XCTAssertFalse(store.portfolios.isEmpty)
        let pending = store.beginContentRefresh()
        store.retireForEnvironmentSwitch()
        XCTAssertFalse(store.completeContentRefresh(pending, with: manifest))
        store.applyPublishedManifest(manifest)
        await store.restoreCachedContent(allowVideo: true)
        XCTAssertTrue(store.portfolios.isEmpty)
        XCTAssertTrue(store.heroImages.isEmpty)
        XCTAssertNil(store.showreel)
        XCTAssertNil(store.selectLaunchPosterForColdLaunch(allowsBundledPreview: true))
        let retry = store.beginContentRefresh()
        XCTAssertFalse(store.isRefreshing)
        XCTAssertFalse(store.completeContentRefresh(retry, with: manifest))
        XCTAssertEqual(store.contentOrigin, .bundled)
    }

    @MainActor
    func testWorkspaceSwitchSerializesCleanupAndRecreatesServicesEvenAfterCallerCancellation() async {
        var events: [String] = []
        var persisted: [AppServiceEnvironment] = []
        let coordinator = AppWorkspaceCoordinator(didSelect: { persisted.append($0) }) { environment in
            events.append("create-\(environment.rawValue)")
            return TestAppWorkspace(environment: environment) { events.append($0) }
        }
        let original = coordinator.current
        XCTAssertEqual(events, ["create-production", "activate-production"])
        let unchanged = await coordinator.switchEnvironment(to: .production)
        XCTAssertFalse(unchanged)
        XCTAssertTrue(persisted.isEmpty)
        original.waitForRetirement = true
        let started = expectation(description: "Old workspace teardown suspended")
        original.retirementStarted = { started.fulfill() }
        let switching = Task { await coordinator.switchEnvironment(to: .review) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(coordinator.isSwitching)
        XCTAssertTrue(coordinator.current === original)
        XCTAssertTrue(persisted.isEmpty, "Do not persist a workspace before teardown completes")
        XCTAssertEqual(events.last, "retire-start-production")
        let concurrent = await coordinator.switchEnvironment(to: .production)
        XCTAssertFalse(concurrent)
        switching.cancel()
        original.finishRetirement()
        let changed = await switching.value
        XCTAssertTrue(changed)
        XCTAssertFalse(coordinator.isSwitching)
        XCTAssertEqual(coordinator.current.serviceEnvironment, .review)
        XCTAssertEqual(persisted, [.review])
        XCTAssertEqual(events, ["create-production", "activate-production", "retire-start-production",
            "retire-end-production", "create-review", "activate-review"])
        let returned = await coordinator.switchEnvironment(to: .production)
        XCTAssertTrue(returned)
        XCTAssertEqual(persisted, [.review, .production])
        XCTAssertFalse(coordinator.current === original, "回到正式环境必须创建新服务，不能复用已退役会话")
    }

    @MainActor
    func testNotificationRouterKeepsLegacyProductionAndExplicitReviewPayloadsSeparate() throws {
        let defaults = try makePushStartupDefaults()
        let router = PushNotificationRouter()
        func make(_ environment: AppServiceEnvironment) -> PushNotificationCoordinator {
            PushNotificationCoordinator(authorizationClient: TestPushAuthorizationClient(), defaults: defaults,
                registrationClient: TestPushDeviceRegistrationClient(), environment: environment)
        }
        let production = make(.production)
        let review = make(.review)
        let id = "11111111-2222-4333-8444-555555555555"
        router.activate(production)
        XCTAssertTrue(router.receiveNotification(userInfo: ["notificationID": id], opened: true))
        XCTAssertEqual(production.pendingNotification?.id, id)
        router.activate(review)
        XCTAssertTrue(production.isRetired)
        XCTAssertNil(production.pendingNotification)
        XCTAssertFalse(router.receiveNotification(userInfo: ["notificationID": id], opened: true))
        XCTAssertNil(review.pendingNotification)
        XCTAssertTrue(router.receiveNotification(userInfo: ["notificationID": id, "serviceEnvironment": "review"], opened: true))
        XCTAssertEqual(review.pendingNotification?.id, id)
        let receipt = review.notificationReceiptGeneration
        for invalid: Any in ["unknown", 1, "", "production"] {
            XCTAssertFalse(router.receiveNotification(userInfo: ["notificationID": id, "serviceEnvironment": invalid], opened: true))
        }
        XCTAssertFalse(router.receiveNotification(userInfo: ["notificationID": "not-an-id", "serviceEnvironment": "review"], opened: true))
        XCTAssertEqual(review.notificationReceiptGeneration, receipt)
        router.deactivate(production)
        XCTAssertTrue(router.activeCoordinator === review, "旧环境不能取消当前路由")
        router.deactivate(review)
        XCTAssertFalse(router.receiveNotification(userInfo: ["notificationID": id, "serviceEnvironment": "review"], opened: true))
        let next = make(.review)
        router.activate(next)
        XCTAssertNil(next.pendingNotification, "切换间隙的旧消息不能在新账号环境中重放")
        next.retire()
        router.activate(production)
        XCTAssertFalse(router.activeCoordinator === production, "不能激活退役协调器")
        review.retire()
    }

    @MainActor
    func testColdNotificationTapWaitsForFirstWorkspaceWithoutSelectingAnEnvironment() throws {
        let defaults = try makePushStartupDefaults()
        for initialEnvironment in AppServiceEnvironment.allCases {
            let router = PushNotificationRouter()
            let id = "11111111-2222-4333-8444-555555555555"
            XCTAssertTrue(router.receiveNotification(userInfo: ["notificationID": id], opened: true))
            XCTAssertNil(router.activeCoordinator)
            let coordinator = PushNotificationCoordinator(authorizationClient: TestPushAuthorizationClient(),
                defaults: defaults, registrationClient: TestPushDeviceRegistrationClient(), environment: initialEnvironment)
            router.activate(coordinator)
            XCTAssertEqual(coordinator.pendingNotification?.id, initialEnvironment == .production ? id : nil)
            coordinator.retire()
        }
    }

    @MainActor
    func testRetiredPushCoordinatorCannotConsumeLateAuthorizationOrAcceptMoreWork() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.granted])
        let registration = TestPushDeviceRegistrationClient()
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults,
            registrationClient: registration)
        let started = expectation(description: "Authorization suspended")
        client.pauseRequest = true
        client.requestStarted = { started.fulfill() }
        let authorizing = Task { await coordinator.requestStartupAuthorizationIfNeeded() }
        await fulfillment(of: [started], timeout: 2)
        coordinator.retire()
        coordinator.retire()
        let unregistrations = registration.unregistrationCount
        client.resumeRequest()
        await authorizing.value
        let account = TestPushNotificationAccount(userID: "old-user")
        await coordinator.setNotificationsEnabled(true, for: account)
        await coordinator.synchronize(with: account)
        await coordinator.requestAuthorizationAfterRationale(for: account)
        await coordinator.requestStartupAuthorizationIfNeeded()
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        coordinator.registrationFailed()
        coordinator.receiveNotification(userInfo: ["notificationID": "11111111-2222-4333-8444-555555555555"], opened: true)
        XCTAssertTrue(coordinator.isRetired)
        XCTAssertTrue(coordinator.deviceRegistrationState == .inactive)
        XCTAssertFalse(coordinator.notificationsEnabled)
        XCTAssertNil(coordinator.pendingNotification)
        XCTAssertNil(defaults.object(forKey: "push-notifications-startup-consent-pending"))
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(registration.registrationCount, 0)
        XCTAssertEqual(registration.unregistrationCount, unregistrations)
        XCTAssertTrue(account.bindingAttempts.isEmpty)
        XCTAssertEqual(account.unbindCount, 0)
    }

    @MainActor
    func testRetiredLateBindingCannotUnregisterOrReplaceNewWorkspaceBinding() async throws {
        let defaults = try makePushStartupDefaults()
        let registration = TestPushDeviceRegistrationClient()
        func make() -> PushNotificationCoordinator {
            PushNotificationCoordinator(authorizationClient: TestPushAuthorizationClient(status: .authorized),
                defaults: defaults, registrationClient: registration)
        }
        let old = make()
        let account = TestPushNotificationAccount(userID: "same-user")
        await old.setNotificationsEnabled(true, for: account)
        old.receive(deviceToken: Data([0x12, 0x34]))
        let started = expectation(description: "Old binding suspended")
        account.pauseNextBinding = true
        account.bindingStarted = { started.fulfill() }
        let binding = Task { await old.synchronize(with: account) }
        await fulfillment(of: [started], timeout: 2)
        old.retire()
        let next = make()
        defer { next.retire() }
        let newAccount = TestPushNotificationAccount(userID: "same-user")
        await next.synchronize(with: newAccount)
        next.receive(deviceToken: Data([0x12, 0x34]))
        await next.synchronize(with: newAccount)
        XCTAssertTrue(next.deviceRegistrationState == .ready)
        let unregistrations = registration.unregistrationCount
        account.resumeBinding()
        await binding.value
        XCTAssertTrue(old.deviceRegistrationState == .inactive)
        XCTAssertTrue(next.deviceRegistrationState == .ready)
        XCTAssertEqual(registration.unregistrationCount, unregistrations)
        XCTAssertEqual(newAccount.bindingAttempts.count, 1)
    }

    func testInlineVideoContextRejectsOtherWorkspaceAndTracksReplacedOrRemovedVideo() throws {
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            let url = try XCTUnwrap(URL(string: "https://\(environment.mediaHost)/video/showreel.m3u8"))
            let context = InlineVideoPlaybackContext(environment: environment, videoURL: url)
            XCTAssertEqual(context.playableURL, url)
            let wrongWorkspace = InlineVideoPlaybackContext(environment: other, videoURL: url)
            XCTAssertNil(wrongWorkspace.playableURL)
            XCTAssertNotEqual(context, wrongWorkspace)
            XCTAssertNotEqual(context, InlineVideoPlaybackContext(environment: environment, videoURL: nil))
            let next = try XCTUnwrap(URL(string: "https://\(environment.mediaHost)/video/new.m3u8"))
            XCTAssertNotEqual(context, InlineVideoPlaybackContext(environment: environment, videoURL: next))
            for invalid in ["http://\(environment.mediaHost)/video.mp4", "https://example.invalid/video.mp4"] {
                XCTAssertNil(InlineVideoPlaybackContext(
                    environment: environment, videoURL: try XCTUnwrap(URL(string: invalid))
                ).playableURL)
            }
        }
    }

    func testPushSynchronizationIdentityIncludesWorkspaceEvenForSameAccountAndGeneration() {
        let production = PushSynchronizationTaskID(userID: "same-user", fanSessionGeneration: 1,
            deviceRegistrationGeneration: 1, environment: .production)
        let review = PushSynchronizationTaskID(userID: "same-user", fanSessionGeneration: 1,
            deviceRegistrationGeneration: 1, environment: .review)
        XCTAssertNotEqual(production, review)
        XCTAssertEqual(Set([production, review]).count, 2)
    }

    @MainActor
    func testPushCoordinatorRejectsOtherWorkspaceWithoutChangingActiveBindingOrPreferences() async throws {
        for environment in AppServiceEnvironment.allCases {
            let defaults = try makePushStartupDefaults()
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            let client = TestPushAuthorizationClient(status: .authorized)
            let registration = TestPushDeviceRegistrationClient()
            let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults,
                registrationClient: registration, environment: environment)
            defer { coordinator.accountContextDidChange(to: nil) }
            let own = TestPushNotificationAccount(userID: "same-user", environment: environment)
            let foreign = TestPushNotificationAccount(userID: "same-user", environment: other)
            await coordinator.setNotificationsEnabled(true, for: own)
            coordinator.receive(deviceToken: Data([0x12, 0x34]))
            await coordinator.synchronize(with: own)
            XCTAssertEqual(own.bindingAttempts.count, 1)
            XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
            let registrations = registration.registrationCount
            let unregistrations = registration.unregistrationCount
            await coordinator.synchronize(with: foreign)
            await coordinator.setNotificationsEnabled(false, for: foreign)
            await coordinator.requestAuthorizationAfterRationale(for: foreign)
            foreign.pushEligibleUserID = nil
            await coordinator.synchronize(with: foreign)
            XCTAssertTrue(foreign.bindingAttempts.isEmpty)
            XCTAssertEqual(foreign.unbindCount, 0)
            XCTAssertEqual(registration.registrationCount, registrations)
            XCTAssertEqual(registration.unregistrationCount, unregistrations)
            XCTAssertEqual(client.requestCount, 0)
            XCTAssertTrue(coordinator.notificationsEnabled)
            XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
            XCTAssertNil(defaults.object(forKey: other.storageKey("push-notifications-enabled")))
        }
    }

    @MainActor
    func testPushStartupConsentAndOptOutRemainScopedAcrossWorkspaces() async throws {
        let defaults = try makePushStartupDefaults()
        let productionRegistration = TestPushDeviceRegistrationClient()
        let reviewRegistration = TestPushDeviceRegistrationClient()
        let production = PushNotificationCoordinator(
            authorizationClient: TestPushAuthorizationClient(status: .authorized), defaults: defaults,
            registrationClient: productionRegistration)
        let review = PushNotificationCoordinator(
            authorizationClient: TestPushAuthorizationClient(status: .authorized), defaults: defaults,
            registrationClient: reviewRegistration, environment: .review)
        defer {
            production.accountContextDidChange(to: nil)
            review.accountContextDidChange(to: nil)
        }
        let own = TestPushNotificationAccount(userID: "same-user")
        let demo = TestPushNotificationAccount(userID: "same-user", environment: .review)
        PushStartupConsentPolicy.recordGranted(in: defaults)
        await review.synchronize(with: demo)
        XCTAssertTrue(review.notificationsEnabled, "系统允许后演示账号独立自动启用")
        XCTAssertEqual(reviewRegistration.registrationCount, 1)
        XCTAssertTrue(defaults.bool(forKey: "push-notifications-startup-consent-pending"),
                      "演示账号不能消费正式环境的旧启动授权记录")
        await production.synchronize(with: own)
        XCTAssertTrue(production.notificationsEnabled)
        await review.setNotificationsEnabled(true, for: demo)
        await review.setNotificationsEnabled(false, for: demo)
        await production.synchronize(with: own)
        XCTAssertTrue(production.notificationsEnabled, "演示退出选择不能覆盖正式偏好")
        PushStartupConsentPolicy.recordGranted(in: defaults, environment: .review)
        PushStartupConsentPolicy.clear(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "review.push-notifications-startup-consent-pending"))
        await review.synchronize(with: demo)
        XCTAssertFalse(review.notificationsEnabled, "新的启动授权不能撤销既有主动关闭")
        XCTAssertNil(defaults.object(forKey: "review.push-notifications-startup-consent-pending"))
    }

    @MainActor
    func testReviewStartupPermissionWritesOnlyReviewConsent() async throws {
        let defaults = try makePushStartupDefaults()
        let coordinator = PushNotificationCoordinator(
            authorizationClient: TestPushAuthorizationClient(outcomes: [.granted]), defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient(), environment: .review)
        await coordinator.requestStartupAuthorizationIfNeeded()
        XCTAssertTrue(defaults.bool(forKey: "review.push-notifications-startup-consent-pending"))
        XCTAssertNil(defaults.object(forKey: "push-notifications-startup-consent-pending"))
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))
    }

    func testGalleryArtworkIdentityIgnoresTransformsButTracksContentAndViewport() throws {
        let preview = try XCTUnwrap(URL(string: "https://img.shuzijun.com.cn/images/test-preview.webp"))
        let full = try XCTUnwrap(URL(string: "https://img.shuzijun.com.cn/images/test-full.webp"))
        let updatedFull = try XCTUnwrap(URL(string: "https://img.shuzijun.com.cn/images/test-full-v2.webp"))
        let photo = PortfolioImage(id: 1, url: preview, fullSizeURL: full, altText: "照片")
        let size = CGSize(width: 430, height: 760)
        let original = ProgressiveGalleryArtwork(image: photo, targetSize: size)
        XCTAssertEqual(original, ProgressiveGalleryArtwork(image: photo, targetSize: size))
        XCTAssertNotEqual(original, ProgressiveGalleryArtwork(
            image: photo, targetSize: CGSize(width: 760, height: 430)
        ))
        XCTAssertNotEqual(original, ProgressiveGalleryArtwork(
            image: PortfolioImage(id: 1, url: preview, fullSizeURL: updatedFull, altText: "照片"),
            targetSize: size
        ))
        XCTAssertNotEqual(original, ProgressiveGalleryArtwork(image: photo, targetSize: size, environment: .review))
        XCTAssertNotEqual(original, ProgressiveGalleryArtwork(image: photo, targetSize: size, loadGeneration: 1),
                          "同一帧 A→B→A 时也必须替换旧图片尺寸回调")
    }

    @MainActor
    func testGalleryZoomHostPreservesEnvironmentUntilExplicitReplacement() {
        let url = AppURL.make("https://example.invalid/synthetic-image.png")
        let photo = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "合成测试")
        let controller = GalleryZoomViewController(image: photo, environment: .review)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 760)
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(controller.serviceEnvironment, .review)
#if DEBUG
        let initialUpdates = controller.contentUpdateCount
#endif
        controller.update(image: photo, environment: .review)
#if DEBUG
        XCTAssertEqual(controller.contentUpdateCount, initialUpdates)
#endif
        controller.scrollView.setZoomScale(2, animated: false)
        controller.update(image: photo, environment: .production)
        XCTAssertEqual(controller.serviceEnvironment, .production)
#if DEBUG
        XCTAssertEqual(controller.contentUpdateCount, initialUpdates + 1)
#endif
        XCTAssertEqual(controller.scrollView.zoomScale, 1)
    }

    func testGalleryAccessibilityReadsTheCurrentNativeZoomScale() throws {
        let url = try XCTUnwrap(URL(string: "https://img.shuzijun.com.cn/images/test-photo.webp"))
        let image = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "照片")
        let controller = GalleryZoomViewController(image: image)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 760)
        controller.viewDidLayoutSubviews()
        let photo = try XCTUnwrap(
            controller.scrollView.accessibilityElements?.first(where: { $0 is UIAccessibilityElement }) as? UIAccessibilityElement
        )
#if DEBUG
        let initialUpdates = controller.contentUpdateCount
#endif
        for scale in [CGFloat(1.25), 2, 4, 1, 3, 1] {
            controller.scrollView.setZoomScale(scale, animated: false)
            XCTAssertEqual(controller.scrollView.zoomScale, scale, accuracy: 0.001)
            XCTAssertEqual(photo.accessibilityValue, "缩放 \(Int((scale * 100).rounded()))%",
                           "辅助功能必须读取当前原生缩放值，不能依赖滞后的手势结束回调")
        }
#if DEBUG
        XCTAssertEqual(controller.contentUpdateCount, initialUpdates,
                       "更新辅助功能缩放值不能重建图片加载子树")
#endif
    }

    func testGalleryHostedRetryControlsPrecedeVirtualPhotoInAccessibilityHitTesting() throws {
        let url = AppURL.make("https://www.shuzijun.com.cn/wp-content/uploads/control-fixture.png")
        let image = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "测试图片")
        let controller = GalleryZoomViewController(image: image)
        controller.loadViewIfNeeded()
        let elements = try XCTUnwrap(controller.scrollView.accessibilityElements)
        XCTAssertEqual(elements.count, 2)
        XCTAssertTrue(elements[0] is UIView, "实际重试按钮的宿主必须先参与命中测试")
        let photo = try XCTUnwrap(elements[1] as? UIAccessibilityElement)
        XCTAssertEqual(photo.accessibilityIdentifier, "gallery-image-1")
        XCTAssertTrue(photo.accessibilityTraits.contains(.adjustable))
    }

    func testNativeGalleryPanDoesNotUpdateHostedArtworkAndRotationResetsZoom() throws {
        let url = try XCTUnwrap(URL(string: "https://img.shuzijun.com.cn/images/test-photo.webp"))
        let image = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "照片")
        let controller = GalleryZoomViewController(image: image)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 760)
        controller.viewDidLayoutSubviews()
#if DEBUG
        let initialUpdates = controller.contentUpdateCount
        XCTAssertEqual(initialUpdates, 1)
#endif
        XCTAssertFalse(controller.scrollView.gestureRecognizerShouldBegin(controller.scrollView.panGestureRecognizer))
        controller.scrollView.setZoomScale(2, animated: false)
        XCTAssertTrue(controller.scrollView.gestureRecognizerShouldBegin(controller.scrollView.panGestureRecognizer))
        for step in 1...100 {
            controller.scrollView.contentOffset = CGPoint(x: step, y: step)
            controller.viewDidLayoutSubviews()
            controller.update(image: image)
        }
#if DEBUG
        XCTAssertEqual(controller.contentUpdateCount, initialUpdates,
                       "拖动/重复 representable 更新不能重建图片加载子树")
#endif
        XCTAssertEqual(controller.scrollView.zoomScale, 2)
        XCTAssertEqual(controller.scrollView.contentOffset, CGPoint(x: 100, y: 100))
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 430)
        controller.viewDidLayoutSubviews()
#if DEBUG
        XCTAssertEqual(controller.contentUpdateCount, initialUpdates + 1)
#endif
        XCTAssertEqual(controller.scrollView.zoomScale, 1)
        XCTAssertEqual(controller.scrollView.contentOffset, .zero)
        XCTAssertFalse(controller.scrollView.gestureRecognizerShouldBegin(controller.scrollView.panGestureRecognizer))
    }

    func testGalleryMinorViewportResizePreservesZoomAndFocus() throws {
        let url = try XCTUnwrap(URL(string: "https://img.shuzijun.com.cn/images/test-photo.webp"))
        let image = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "照片")
        let controller = GalleryZoomViewController(image: image)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 690)
        controller.viewDidLayoutSubviews()
        controller.scrollView.setZoomScale(2, animated: false)
        controller.scrollView.contentOffset = CGPoint(x: 200, y: 150)
        let focus = CGPoint(x: CGFloat(712) / 2048, y: CGFloat(495) / 1380)
        // UIScrollView aligns offsets to physical pixels. Sub-pixel decimal
        // equality would reject correct focus preservation on a 2x/3x screen.
        let pixel = 1 / max(1, controller.scrollView.traitCollection.displayScale)
        for height: CGFloat in [658, 690, 658, 690] {
            controller.view.frame.size.height = height
            controller.viewDidLayoutSubviews()
            XCTAssertEqual(controller.scrollView.zoomScale, 2, accuracy: 0.001,
                           "状态栏/安全区改变不能把刚放大的照片突然恢复到 1x")
            XCTAssertEqual(controller.scrollView.contentOffset.x, focus.x * 1024 * 2 - 512, accuracy: pixel)
            XCTAssertEqual(controller.scrollView.contentOffset.y, focus.y * height * 2 - height / 2, accuracy: pixel,
                           "同方向视口改变应保留正在看的区域")
        }
    }

    func testGalleryUnzoomedResizeAndPhotoChangeKeepFullComposition() throws {
        let url = try XCTUnwrap(URL(string: "https://img.shuzijun.com.cn/images/test-photo.webp"))
        let image = PortfolioImage(id: 1, url: url, fullSizeURL: url, altText: "照片")
        let controller = GalleryZoomViewController(image: image)
        controller.loadViewIfNeeded()
        for size in [CGSize(width: 820, height: 1100), CGSize(width: 700, height: 1068),
                     CGSize(width: 820, height: 1100)] {
            controller.view.frame.size = size
            controller.viewDidLayoutSubviews()
            XCTAssertEqual(controller.scrollView.zoomScale, 1)
            XCTAssertEqual(controller.scrollView.contentOffset, .zero)
            XCTAssertEqual(controller.scrollView.contentSize, size)
        }
        controller.scrollView.setZoomScale(4, animated: false)
        controller.scrollView.contentOffset = CGPoint(x: 400, y: 500)
        controller.update(image: PortfolioImage(id: 2, url: url, fullSizeURL: url, altText: "另一张照片"))
        XCTAssertEqual(controller.scrollView.zoomScale, 1)
        XCTAssertEqual(controller.scrollView.contentOffset, .zero)
    }

    func testScreenProtectionDoesNotAddLifecycleCoverToVerifiedUncapturedColdLaunch() {
        var state = ScreenProtectionPresentationState()
        state.updateCapture(.inactive)

        state.updateScene(isActive: false)

        XCTAssertFalse(state.hasEnteredActiveState)
        XCTAssertFalse(state.isPrivacyCoverVisible)
        XCTAssertFalse(state.shouldShowProtectionCover)
    }

    func testScreenProtectionCoversInactiveSceneAfterProtectedContentWasVisible() {
        var state = ScreenProtectionPresentationState()
        state.updateCapture(.inactive)

        state.updateScene(isActive: true)
        state.updateScene(isActive: false)

        XCTAssertTrue(state.hasEnteredActiveState)
        XCTAssertTrue(state.isPrivacyCoverVisible)
        XCTAssertTrue(state.shouldShowProtectionCover)

        state.updateScene(isActive: true)

        XCTAssertFalse(state.isPrivacyCoverVisible)
        XCTAssertFalse(state.shouldShowProtectionCover)
    }

    func testScreenshotWarningExpiresWhileLifecycleCoverRemainsActive() {
        var state = ScreenProtectionPresentationState()
        state.updateCapture(.inactive)
        state.updateScene(isActive: true)
        let generation = state.beginScreenshotWarning()

        state.updateScene(isActive: false)
        state.expireScreenshotWarning(generation: generation)

        XCTAssertFalse(state.isScreenshotWarningVisible)
        XCTAssertTrue(state.isPrivacyCoverVisible)
        XCTAssertTrue(state.shouldShowProtectionCover)
    }

    func testScreenshotWarningExpiresWhileCaptureCoverRemainsActive() {
        var state = ScreenProtectionPresentationState()
        let generation = state.beginScreenshotWarning()

        XCTAssertTrue(state.updateCapture(.active))
        XCTAssertFalse(state.updateCapture(.active), "重复状态不应重复触发开始录屏副作用")
        state.expireScreenshotWarning(generation: generation)

        XCTAssertFalse(state.isScreenshotWarningVisible)
        XCTAssertTrue(state.isCaptureActive)
        XCTAssertTrue(state.shouldShowProtectionCover)

        XCTAssertFalse(state.updateCapture(.inactive))
        XCTAssertFalse(state.shouldShowProtectionCover)
    }

    func testOlderScreenshotWarningCannotExpireNewerWarning() {
        var state = ScreenProtectionPresentationState()
        state.updateCapture(.inactive)
        let firstGeneration = state.beginScreenshotWarning()
        let secondGeneration = state.beginScreenshotWarning()

        state.expireScreenshotWarning(generation: firstGeneration)
        XCTAssertTrue(state.isScreenshotWarningVisible)

        state.expireScreenshotWarning(generation: secondGeneration)
        XCTAssertFalse(state.isScreenshotWarningVisible)
    }

    func testCancellingScreenshotWarningInvalidatesPendingGeneration() {
        var state = ScreenProtectionPresentationState()
        state.updateCapture(.inactive)
        let generation = state.beginScreenshotWarning()

        state.cancelScreenshotWarning()
        state.expireScreenshotWarning(generation: generation)

        XCTAssertFalse(state.isScreenshotWarningVisible)
        XCTAssertFalse(state.shouldShowProtectionCover)
    }

    func testVerifiedUncapturedWindowLifecycleShieldOnlyAppearsAfterFirstActiveState() {
        var state = WindowLifecycleShieldState()
        state.updateCapture(.inactive)

        state.sceneWillDeactivate()
        state.sceneDidEnterBackground()
        XCTAssertFalse(state.isVisible)

        state.sceneDidActivate()
        XCTAssertTrue(state.hasEnteredActiveState)
        XCTAssertFalse(state.isVisible)

        state.sceneWillDeactivate()
        XCTAssertTrue(state.isVisible)

        state.sceneDidActivate()
        XCTAssertFalse(state.isVisible)
    }

    func testUnknownCaptureInitiallyCoversUntilExplicitInactiveSample() {
        var presentation = ScreenProtectionPresentationState()
        var window = WindowLifecycleShieldState()

        XCTAssertFalse(presentation.isCaptureActive, "未知状态不能误报已经开始录屏")
        XCTAssertTrue(presentation.shouldShowProtectionCover)
        XCTAssertTrue(window.captureNeedsCover)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(presentation.updateCapture(.unknown))
        window.updateCapture(.unknown)
        XCTAssertTrue(presentation.shouldShowProtectionCover)
        XCTAssertTrue(window.isVisible)

        XCTAssertFalse(presentation.updateCapture(.inactive))
        window.updateCapture(.inactive)
        XCTAssertFalse(presentation.isCaptureActive)
        XCTAssertFalse(presentation.shouldShowProtectionCover)
        XCTAssertFalse(window.captureNeedsCover)
        XCTAssertFalse(window.isVisible)
    }

    func testUnknownCaptureCannotOverwritePreviouslyActiveOrInactiveState() {
        var presentation = ScreenProtectionPresentationState()
        var window = WindowLifecycleShieldState()
        XCTAssertTrue(presentation.updateCapture(.active))
        window.updateCapture(.active)

        XCTAssertFalse(presentation.updateCapture(.unknown))
        window.updateCapture(.unknown)
        XCTAssertTrue(presentation.isCaptureActive)
        XCTAssertTrue(presentation.shouldShowProtectionCover)
        XCTAssertTrue(window.captureNeedsCover)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(presentation.updateCapture(.active), "未知采样不能制造第二次开始录屏边沿")

        XCTAssertFalse(presentation.updateCapture(.inactive))
        window.updateCapture(.inactive)
        XCTAssertFalse(presentation.updateCapture(.unknown))
        window.updateCapture(.unknown)
        XCTAssertFalse(presentation.isCaptureActive)
        XCTAssertFalse(presentation.shouldShowProtectionCover)
        XCTAssertFalse(window.captureNeedsCover)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(presentation.updateCapture(.active), "明确结束后重新开始捕获才产生新边沿")
    }

    func testDetachedCaptureSamplesAlwaysRemainUnknown() {
        for sceneStatus in [ScreenCaptureStatus.unknown, .inactive, .active] {
            for screenIsCaptured in [false, true] {
                for isSceneActive in [false, true] {
                    let sample = ScreenCaptureSample(
                        sceneStatus: sceneStatus, screenIsCaptured: screenIsCaptured,
                        isAttached: false, isSceneActive: isSceneActive
                    )
                    XCTAssertEqual(sample.status, .unknown,
                                   "未附着所属窗口的采样不能代表真实页面，亦不能清除现有保护")
                }
            }
        }
    }

    func testForegroundActivationDoesNotRemoveUnknownCaptureShield() {
        var presentation = ScreenProtectionPresentationState()
        var window = WindowLifecycleShieldState()
        presentation.updateScene(isActive: true)
        window.sceneDidActivate()
        XCTAssertFalse(presentation.isPrivacyCoverVisible)
        XCTAssertTrue(presentation.shouldShowProtectionCover)
        XCTAssertTrue(window.captureNeedsCover)
        XCTAssertTrue(window.isVisible)

        presentation.updateScene(isActive: false)
        window.sceneWillDeactivate()
        window.sceneDidEnterBackground()
        XCTAssertFalse(presentation.updateCapture(.unknown))
        window.updateCapture(.unknown)
        presentation.updateScene(isActive: true)
        window.sceneDidActivate()
        XCTAssertTrue(presentation.shouldShowProtectionCover,
                      "生命周期回到前台不等于已经获得明确非捕获信号")
        XCTAssertTrue(window.isVisible)

        XCTAssertFalse(presentation.updateCapture(.inactive))
        window.updateCapture(.inactive)
        XCTAssertFalse(presentation.shouldShowProtectionCover)
        XCTAssertFalse(window.isVisible)
        window.reset()
        XCTAssertTrue(window.captureNeedsCover, "新窗口不得继承旧窗口的非捕获确认")
        XCTAssertTrue(window.isVisible)
    }

    func testWarningExpiryDuringUnknownSampleDoesNotClearActiveCaptureCover() {
        var presentation = ScreenProtectionPresentationState()
        var window = WindowLifecycleShieldState()
        XCTAssertTrue(presentation.updateCapture(.active))
        window.updateCapture(.active)
        let generation = presentation.beginScreenshotWarning()
        XCTAssertFalse(presentation.updateCapture(.unknown))
        window.updateCapture(.unknown)

        presentation.expireScreenshotWarning(generation: generation)
        XCTAssertFalse(presentation.isScreenshotWarningVisible)
        XCTAssertTrue(presentation.isCaptureActive)
        XCTAssertTrue(presentation.shouldShowProtectionCover)
        XCTAssertTrue(window.captureNeedsCover)
        XCTAssertTrue(window.isVisible)
    }

    func testActiveSceneCaptureOverridesUncapturedScreenSample() {
        for isSceneActive in [false, true] {
            let sample = ScreenCaptureSample(
                sceneStatus: .active, screenIsCaptured: false,
                isAttached: true, isSceneActive: isSceneActive
            )
            XCTAssertEqual(sample.status, .active,
                           "所属场景明确正在捕获时，屏幕级false不得覆盖active")
        }
    }

    func testCapturedScreenOverridesInactiveSceneSample() {
        for isSceneActive in [false, true] {
            let sample = ScreenCaptureSample(
                sceneStatus: .inactive, screenIsCaptured: true,
                isAttached: true, isSceneActive: isSceneActive
            )
            XCTAssertEqual(sample.status, .active,
                           "任一已附着观察来源报告捕获时均保留保护")
        }
    }

    func testUncapturedScreenCannotTurnUnknownOrBackgroundSceneIntoInactive() {
        for isSceneActive in [false, true] {
            let unknown = ScreenCaptureSample(
                sceneStatus: .unknown, screenIsCaptured: false,
                isAttached: true, isSceneActive: isSceneActive
            )
            XCTAssertEqual(unknown.status, .unknown,
                           "屏幕级false本身不能证明场景未被捕获")
        }
        XCTAssertEqual(ScreenCaptureSample(
            sceneStatus: .inactive, screenIsCaptured: false,
            isAttached: true, isSceneActive: false
        ).status, .unknown, "后台场景的inactive不是前台内容的有效解除信号")
        XCTAssertEqual(ScreenCaptureSample(
            sceneStatus: .inactive, screenIsCaptured: false,
            isAttached: true, isSceneActive: true
        ).status, .inactive)
    }

    @MainActor
    func testCaptureObserverRebindsChangedWindowSceneAndIgnoresDetachedEvents() throws {
#if targetEnvironment(simulator)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hadOverride = scene.traitOverrides.contains(UITraitSceneCaptureState.self)
        let original = scene.traitCollection.sceneCaptureState
        defer {
            if hadOverride { scene.traitOverrides.sceneCaptureState = original }
            else { scene.traitOverrides.remove(UITraitSceneCaptureState.self) }
        }
        var samples: [ScreenCaptureSample] = []
        let observer = WindowCaptureObservation { samples.append($0) }
        let window = UIWindow(windowScene: scene)
        defer { observer.attach(to: nil) }

        scene.traitOverrides.sceneCaptureState = .active
        observer.attach(to: window)
        XCTAssertEqual(samples.last?.status, .active)
        window.windowScene = nil
        observer.resample()
        XCTAssertEqual(samples.last, .detached)
        let detachedCount = samples.count
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        NotificationCenter.default.post(name: UIScreen.capturedDidChangeNotification, object: scene.screen)
        XCTAssertEqual(samples.count, detachedCount, "已解挂场景和屏幕的通知不能再写入状态")

        window.windowScene = scene
        observer.resample()
        XCTAssertEqual(samples.last?.status, .active, "同一窗口重新获得场景时必须重绑")
        XCTAssertTrue(samples.last?.isAttached == true)
        observer.attach(to: nil)
        XCTAssertEqual(samples.last, .detached)
#else
        throw XCTSkip("场景 trait 注入仅允许隔离模拟器")
#endif
    }

    @MainActor
    func testCaptureWindowDoesNotTakeKeyFocusAndCoversPresentedController() async throws {
#if targetEnvironment(simulator)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hadOverride = scene.traitOverrides.contains(UITraitSceneCaptureState.self)
        let original = scene.traitCollection.sceneCaptureState
        let priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 380, height: 700)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let attachment = WindowLifecycleProtectionAttachmentView()
        root.view.addSubview(attachment)
        defer {
            attachment.detachFromProtectedWindow()
            attachment.removeFromSuperview()
            window.isHidden = true
            if hadOverride { scene.traitOverrides.sceneCaptureState = original }
            else { scene.traitOverrides.remove(UITraitSceneCaptureState.self) }
        }
        let modal = UIViewController()
        modal.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            root.present(modal, animated: false) { continuation.resume() }
        }
        XCTAssertTrue(root.presentedViewController === modal)
        scene.traitOverrides.sceneCaptureState = .active
        attachment.refreshForcedState()
        let shield = try XCTUnwrap(scene.windows.first {
            !$0.isHidden && $0.frame == window.frame &&
            $0.rootViewController?.view.accessibilityIdentifier == "window-lifecycle-protection-shield"
        })
        XCTAssertFalse(shield.isKeyWindow)
        XCTAssertTrue(scene.windows.first(where: \.isKeyWindow) === priorKeyWindow)
        XCTAssertGreaterThan(shield.windowLevel.rawValue, window.windowLevel.rawValue)
        XCTAssertTrue(shield.rootViewController?.view.accessibilityViewIsModal == true)
        let shieldRoot = try XCTUnwrap(shield.rootViewController)
        let cover = try XCTUnwrap(shieldRoot.children.first)
        XCTAssertTrue(cover.view.isDescendant(of: shieldRoot.view), "保护页控制器及视图必须具有一致的容纳层级")

        window.frame = CGRect(x: 0, y: 0, width: 700, height: 380)
        attachment.refreshForcedState()
        XCTAssertEqual(shield.frame, window.frame)
        await withCheckedContinuation { continuation in
            root.dismiss(animated: false) { continuation.resume() }
        }
        let secondModal = UIViewController()
        secondModal.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            root.present(secondModal, animated: false) { continuation.resume() }
        }
        XCTAssertTrue(root.presentedViewController === secondModal)
        XCTAssertNil(attachment.window, "确认全屏呈现确实暂时移除了底层安装视图")
        XCTAssertFalse(shield.isHidden, "捕获中呈现模态不能移除高层级保护窗口")

        // Rebind while the full-screen presentation still owns the hierarchy.
        window.windowScene = nil
        attachment.refreshForcedState()
        XCTAssertTrue(shield.isHidden, "原场景解挂后不能遗留旧保护窗口")
        XCTAssertNil(shield.rootViewController, "重绑前必须解除旧窗口对保护控制器的持有")
        window.windowScene = scene
        attachment.refreshForcedState()
        let reboundShield = try XCTUnwrap(scene.windows.first {
            !$0.isHidden && $0.frame == window.frame &&
            $0.rootViewController?.view.accessibilityIdentifier == "window-lifecycle-protection-shield"
        })
        XCTAssertFalse(reboundShield === shield)
        XCTAssertTrue(reboundShield.windowScene === window.windowScene)
        scene.traitOverrides.sceneCaptureState = .inactive
        attachment.refreshForcedState()
        XCTAssertEqual(scene.traitCollection.sceneCaptureState, .inactive)
        // Do not report the release assertion as tested when the host scene
        // cannot legally uncover content. Never override real lifecycle safety.
        guard scene.activationState == .foregroundActive && !scene.screen.isCaptured else {
            XCTAssertFalse(reboundShield.isHidden, "非活跃场景或屏幕仍在捕获时必须保留遮挡")
            await withCheckedContinuation { continuation in
                root.dismiss(animated: false) { continuation.resume() }
            }
            throw XCTSkip("释放遮挡的集成验证需要活跃且未捕获的场景；本次仅验证了保留遮挡")
        }
        XCTAssertTrue(reboundShield.isHidden, "前台明确结束捕获后必须释放遮挡")
        XCTAssertTrue(scene.windows.first(where: \.isKeyWindow) === priorKeyWindow)
        await withCheckedContinuation { continuation in
            root.dismiss(animated: false) { continuation.resume() }
        }
#else
        throw XCTSkip("场景 trait 注入及窗口夹具仅允许隔离模拟器")
#endif
    }

    func testSecureCanvasFallbackPolicyRetriesThenFailsClosed() {
        XCTAssertEqual(
            SecureCanvasFallbackPolicy.nextStep(
                attempt: 1,
                maximumAttempts: 3,
                failure: .canvasMissing
            ),
            .retry
        )
        XCTAssertEqual(
            SecureCanvasFallbackPolicy.nextStep(
                attempt: 3,
                maximumAttempts: 3,
                failure: .canvasMissing
            ),
            .showPrivacyFallback(.canvasMissing)
        )
        XCTAssertEqual(
            SecureCanvasFallbackPolicy.nextStep(
                attempt: 1,
                maximumAttempts: 3,
                failure: nil
            ),
            .attachSecureCanvas
        )
    }

    @MainActor
    func testSecureContainerHostsProtectedContentOnlyInsideAttachedCanvas() {
        var observedStates: [SecureCanvasInstallationState] = []
        let container = SecureHostingContainerView(
            rootView: AnyView(Text("protected-content")),
            fallbackView: AnyView(Text("privacy-fallback")),
            maximumProbeAttempts: 1,
            secureCanvasResolver: { textField in
                let canvas = UIView(frame: textField.bounds)
                textField.addSubview(canvas)
                return canvas
            },
            stateObserver: { observedStates.append($0) }
        )

        XCTAssertEqual(container.installationState, .secured)
        XCTAssertTrue(container.hostsProtectedContent)
        XCTAssertFalse(container.hostsVisiblePrivacyFallback)
        XCTAssertEqual(observedStates.last, .secured)
        XCTAssertFalse(container.isOpaque)
        XCTAssertEqual(container.backgroundColor, .clear)
    }

    @MainActor
    func testSecureContainerShowsVisiblePrivacyFallbackWhenCanvasIsMissing() {
        var observedStates: [SecureCanvasInstallationState] = []
        let container = SecureHostingContainerView(
            rootView: AnyView(Text("protected-content")),
            fallbackView: AnyView(Text("privacy-fallback")),
            maximumProbeAttempts: 1,
            secureCanvasResolver: { _ in nil },
            stateObserver: { observedStates.append($0) }
        )

        XCTAssertEqual(container.installationState, .privacyFallback(.canvasMissing))
        XCTAssertFalse(container.hostsProtectedContent)
        XCTAssertTrue(container.hostsVisiblePrivacyFallback)
        XCTAssertEqual(observedStates.last, .privacyFallback(.canvasMissing))

        container.update(rootView: AnyView(Text("updated-protected-content")))
        XCTAssertFalse(container.hostsProtectedContent)
        XCTAssertTrue(container.hostsVisiblePrivacyFallback)
    }

    @MainActor
    func testSecureContainerRejectsDetachedCanvas() {
        let container = SecureHostingContainerView(
            rootView: AnyView(Text("protected-content")),
            fallbackView: AnyView(Text("privacy-fallback")),
            maximumProbeAttempts: 1,
            secureCanvasResolver: { _ in UIView() }
        )

        XCTAssertEqual(container.installationState, .privacyFallback(.canvasNotAttached))
        XCTAssertFalse(container.hostsProtectedContent)
        XCTAssertTrue(container.hostsVisiblePrivacyFallback)
    }

    func testAboutSocialBrandIconsAreBundledAtDisplayResolution() throws {
        let requiredPixelEdge = Int(ceil(24 * UIScreen.main.scale))
        for assetName in [
            "XiaohongshuBrandIcon",
            "DouyinBrandIcon",
            "HongguoBrandIcon",
        ] {
            let image = try XCTUnwrap(
                UIImage(named: assetName),
                "关于页缺少官方社交平台图标资产 \(assetName)"
            )
            let cgImage = try XCTUnwrap(image.cgImage)
            XCTAssertGreaterThanOrEqual(
                min(cgImage.width, cgImage.height),
                requiredPixelEdge,
                "\(assetName) 不足以在当前屏幕的 24pt 展示中保持清晰"
            )
        }
    }

    func testSafeIdentifiedBindingFallsBackAfterRowRemoval() {
        let fallback = ContentCatalog.launchPosters[0]
        var posters = [fallback]
        let collection = Binding(
            get: { posters },
            set: { posters = $0 }
        )
        let row = SafeIdentifiedBinding.element(for: fallback, in: collection)

        posters.removeAll()

        XCTAssertEqual(row.wrappedValue, fallback)
        var staleUpdate = fallback
        staleUpdate.isEnabled.toggle()
        row.wrappedValue = staleUpdate
        XCTAssertTrue(posters.isEmpty)
    }

    func testSafeIdentifiedBindingResolvesTheCurrentRowByID() {
        let fallback = ContentCatalog.launchPosters[0]
        var current = fallback
        current.title = "服务器新标题"
        var posters = [current]
        let collection = Binding(
            get: { posters },
            set: { posters = $0 }
        )
        let row = SafeIdentifiedBinding.element(for: fallback, in: collection)

        XCTAssertEqual(row.wrappedValue.title, "服务器新标题")
        var edited = row.wrappedValue
        edited.subtitle = "安全写回"
        row.wrappedValue = edited
        XCTAssertEqual(posters.first?.subtitle, "安全写回")
    }

    func testWeatherLocationDiscardsPrecisionAndMotionMetadata() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let precise = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 22.543099, longitude: 114.057868),
            altitude: 102, horizontalAccuracy: 5, verticalAccuracy: 3,
            course: 91, speed: 8, timestamp: timestamp
        )
        let coarse = try XCTUnwrap(WeatherLocationPrivacy.approximate(precise))
        XCTAssertEqual(coarse.coordinate.latitude, 22.55, accuracy: 0.000001)
        XCTAssertEqual(coarse.coordinate.longitude, 114.05, accuracy: 0.000001)
        XCTAssertEqual(coarse.altitude, 0)
        XCTAssertLessThan(coarse.verticalAccuracy, 0)
        XCTAssertLessThan(coarse.course, 0)
        XCTAssertLessThan(coarse.speed, 0)
        XCTAssertEqual(coarse.timestamp, timestamp)
        XCTAssertGreaterThanOrEqual(coarse.horizontalAccuracy, 6_000)
        let repeated = try XCTUnwrap(WeatherLocationPrivacy.approximate(coarse))
        XCTAssertEqual(repeated.coordinate.latitude, coarse.coordinate.latitude)
        XCTAssertEqual(repeated.coordinate.longitude, coarse.coordinate.longitude)
    }

    func testWeatherNearbyPointsShareOneCoarseCoordinate() throws {
        let first = try XCTUnwrap(WeatherLocationPrivacy.approximate(
            CLLocation(latitude: 22.543099, longitude: 114.057868)
        ))
        let next = try XCTUnwrap(WeatherLocationPrivacy.approximate(
            CLLocation(latitude: 22.543101, longitude: 114.057872)
        ))
        XCTAssertEqual(first.coordinate.latitude, next.coordinate.latitude)
        XCTAssertEqual(first.coordinate.longitude, next.coordinate.longitude)
    }

    func testWeatherCoarseCoordinatesRejectInvalidInputAndSupportWorldEdges() throws {
        for coordinate in [
            CLLocationCoordinate2D(latitude: 90, longitude: 180),
            CLLocationCoordinate2D(latitude: -90, longitude: -180),
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
        ] {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let result = try XCTUnwrap(WeatherLocationPrivacy.approximate(location))
            XCTAssertTrue(CLLocationCoordinate2DIsValid(result.coordinate))
        }
        XCTAssertNil(WeatherLocationPrivacy.approximate(CLLocation(latitude: 91, longitude: 0)))
        XCTAssertNil(WeatherLocationPrivacy.approximate(CLLocation(latitude: .nan, longitude: 0)))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSLocationDefaultAccuracyReduced") as? Bool, true)
    }

    func testWeatherLocationAlwaysKeepsAConcisePlaceName() {
        XCTAssertEqual(WeatherPresentation.conciseLocationText("杭州市"), "杭州")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("香港特别行政区"), "香港")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("浙江·杭州"), "浙江·杭州")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("  "), "当前位置")
    }

    func testCompactWeatherSummaryOnlyContainsLocationAndCurrentWeather() {
        XCTAssertEqual(
            WeatherPresentation.compactSummary(location: "杭州市", weather: "晴 24°"),
            "杭州 · 晴 24°"
        )
        XCTAssertFalse(
            WeatherPresentation.compactSummary(location: "杭州市", weather: "晴 24°")
                .localizedCaseInsensitiveContains("Apple Weather")
        )
    }

    func testWeatherAttributionAlwaysHasAnOfficialLegalFallback() {
        XCTAssertEqual(
            WeatherAttributionPresentation.officialLegalURL.absoluteString,
            "https://developer.apple.com/weatherkit/data-source-attribution/"
        )
        XCTAssertEqual(
            WeatherAttributionPresentation.legalURL(from: nil),
            WeatherAttributionPresentation.officialLegalURL
        )
        XCTAssertEqual(
            WeatherAttributionPresentation.legalURL(
                from: URL(string: "http://weatherkit.apple.com/legal-attribution.html")
            ),
            WeatherAttributionPresentation.officialLegalURL
        )
        XCTAssertEqual(
            WeatherAttributionPresentation.legalURL(
                from: URL(string: "https://weatherkit.apple.com/legal-attribution.html")
            ).host,
            "weatherkit.apple.com"
        )
    }

    func testWeatherAttributionProviderNameNeverDisappears() {
        XCTAssertEqual(WeatherAttributionPresentation.providerName(nil), "Apple Weather")
        XCTAssertEqual(WeatherAttributionPresentation.providerName("  \n"), "Apple Weather")
        XCTAssertEqual(
            WeatherAttributionPresentation.providerName("Apple Weather"),
            "Apple Weather"
        )
    }

    func testPrivacyManifestCoversAdminMediaAndSecurityDiagnostics() throws {
        let manifestURL = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        let declarations = try XCTUnwrap(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        )
        var declarationsByType: [String: [String: Any]] = [:]
        for declaration in declarations {
            guard let type = declaration["NSPrivacyCollectedDataType"] as? String else {
                XCTFail("PrivacyInfo.xcprivacy 包含缺少类型的数据声明")
                continue
            }
            XCTAssertNil(declarationsByType[type], "PrivacyInfo.xcprivacy 重复声明 \(type)")
            declarationsByType[type] = declaration
        }

        let expectedLinkedFunctionalTypes = [
            "NSPrivacyCollectedDataTypeEmailAddress",
            "NSPrivacyCollectedDataTypePhoneNumber",
            "NSPrivacyCollectedDataTypeOtherUserContactInfo",
            "NSPrivacyCollectedDataTypeOtherUserContent",
            "NSPrivacyCollectedDataTypePhotosorVideos",
            "NSPrivacyCollectedDataTypeOtherDiagnosticData",
            "NSPrivacyCollectedDataTypeOtherDataTypes",
        ]
        for type in expectedLinkedFunctionalTypes {
            let declaration = try XCTUnwrap(
                declarationsByType[type],
                "PrivacyInfo.xcprivacy 缺少 \(type)"
            )
            XCTAssertEqual(declaration["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(declaration["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(
                declaration["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
            )
        }
    }

    func testLoadedPortfolioExposesEveryImage() {
        let portfolio = makePortfolio(imageCount: 6)

        XCTAssertEqual(portfolio.images.map(\.id), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(portfolio.displayImageCount, 6)
    }

    func testServerCountNeverHidesLoadedImages() {
        let portfolio = makePortfolio(imageCount: 6)

        XCTAssertEqual(portfolio.images.count, 6)
        XCTAssertGreaterThanOrEqual(portfolio.displayImageCount, portfolio.images.count)
    }

    func testEveryHomeHeroUsesOnlyTrustedRemoteMedia() {
        XCTAssertEqual(ContentCatalog.heroImages.count, 5)
        for url in ContentCatalog.heroImages {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(ContentSecurityPolicy.isTrustedMediaURL(url))
        }
    }

    func testProtectedPortraitPhotosAreNotBundledInTheApp() {
        let forbiddenAssetNames = [
            "HeroOne", "HeroTwo", "HeroThree", "HeroFour", "HeroFive",
            "AboutPortrait", "ShowreelPoster", "LaunchPosterFallback",
            "LaunchPosterLanternOne", "LaunchPosterLanternTwo", "LaunchPosterLanternThree",
        ]

        for assetName in forbiddenAssetNames {
            XCTAssertNil(UIImage(named: assetName), "受保护人物照片不得打包进 App：\(assetName)")
        }
    }

    func testHomeHeroRestoresPortraitFillAndRetainsLandscapeFit() {
        XCTAssertEqual(
            HomeHeroRenderPolicy.presentation(
                for: CGSize(width: 1_366, height: 1_024),
                idiom: .pad
            ),
            .fit
        )
        XCTAssertEqual(
            HomeHeroRenderPolicy.presentation(
                for: CGSize(width: 1_024, height: 1_366),
                idiom: .pad
            ),
            .fill
        )
        XCTAssertEqual(
            HomeHeroRenderPolicy.presentation(
                for: CGSize(width: 932, height: 430),
                idiom: .phone
            ),
            .fit
        )
        XCTAssertEqual(
            HomeHeroRenderPolicy.presentation(
                for: CGSize(width: 430, height: 932),
                idiom: .phone
            ),
            .fill
        )
    }

    func testLandscapeIPadHeroFitPreservesThePortraitAspectRatio() {
        let source = CGSize(width: 959, height: 1_440)
        let viewport = CGSize(width: 1_376, height: 1_032)
        let fitted = HomeHeroRenderPolicy.fittedSize(
            sourceSize: source,
            in: viewport
        )

        XCTAssertEqual(fitted.height, viewport.height, accuracy: 0.001)
        XCTAssertLessThanOrEqual(fitted.width, viewport.width)
        XCTAssertEqual(
            fitted.width / fitted.height,
            source.width / source.height,
            accuracy: 0.0001
        )
    }

    func testHomeHeroTreatsTheFirstAndLastSlidesAsCircularNeighbours() {
        XCTAssertEqual(
            HomeHeroRenderPolicy.prefetchIndices(selection: 0, count: 5),
            [0, 1, 2, 3, 4]
        )
        XCTAssertTrue(
            HomeHeroRenderPolicy.shouldLoadRemoteImage(
                at: 4,
                selection: 0,
                count: 5
            )
        )
        XCTAssertTrue(
            HomeHeroRenderPolicy.shouldLoadRemoteImage(
                at: 0,
                selection: 4,
                count: 5
            )
        )
        XCTAssertTrue(
            HomeHeroRenderPolicy.shouldLoadRemoteImage(
                at: 3,
                selection: 0,
                count: 5
            )
        )
        XCTAssertFalse(
            HomeHeroRenderPolicy.shouldAnimateTransition(from: 4, to: 0, count: 5),
            "末张回到首张时不能让非循环 TabView 跨页动画"
        )
        XCTAssertFalse(
            HomeHeroRenderPolicy.shouldAnimateTransition(from: 0, to: 4, count: 5),
            "首张回到末张时不能让非循环 TabView 跨页动画"
        )
        XCTAssertTrue(
            HomeHeroRenderPolicy.shouldAnimateTransition(from: 3, to: 4, count: 5)
        )
    }

    func testHeroAutoAdvanceDefersToTouchAccessibilityAndImageReadiness() {
        func allowed(touching: Bool = false, ready: Bool = true, next: Bool = true,
                     active: Bool = true, visible: Bool = true, reduced: Bool = false,
                     voiceOver: Bool = false, count: Int = 5) -> Bool {
            HomeHeroAdvanceRequest.permitsAdvance(isVisible: visible, isActive: active,
                reducesMotion: reduced, voiceOverEnabled: voiceOver, isTouching: touching,
                count: count, currentReady: ready, nextReady: next)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(touching: true))
        XCTAssertFalse(allowed(ready: false))
        XCTAssertFalse(allowed(next: false))
        XCTAssertFalse(allowed(active: false))
        XCTAssertFalse(allowed(visible: false))
        XCTAssertFalse(allowed(reduced: true))
        XCTAssertFalse(allowed(voiceOver: true))
        XCTAssertFalse(allowed(count: 1))
        let original = HomeHeroAdvanceRequest(enabled: true, selection: 0, interactionGeneration: 0)
        XCTAssertNotEqual(original, HomeHeroAdvanceRequest(enabled: true, selection: 1, interactionGeneration: 0))
        XCTAssertNotEqual(original, HomeHeroAdvanceRequest(enabled: true, selection: 0, interactionGeneration: 1),
                          "即使拖动取消、停在原图，自动翻页也必须重新计时")
    }

    @MainActor
    func testHomeContactInvalidatesAutoAdvanceBeforeAnotherViewUpdate() {
        let state = HomeHeroPlaybackState(selection: 0)
        let armed = HomeHeroAdvanceRequest(enabled: true, selection: state.selection,
                                           interactionGeneration: state.interactionGeneration)
        state.isTouching = true
        XCTAssertNotEqual(state.interactionGeneration, armed.interactionGeneration,
                          "按下时立即使旧计时失效，不能等待下一次界面更新")
        let pressedGeneration = state.interactionGeneration
        state.isTouching = true
        XCTAssertEqual(state.interactionGeneration, pressedGeneration,
                       "重复按下通知不能不断重置计时")
        state.isTouching = false
        XCTAssertNotEqual(state.interactionGeneration, pressedGeneration,
                          "松手或取消滑动后开始新的完整等待周期")
        let released = HomeHeroAdvanceRequest(enabled: true, selection: state.selection,
                                              interactionGeneration: state.interactionGeneration)
        XCTAssertNotEqual(armed, released,
                          "即使按下和松手发生在同一轮更新中、图片没变，旧计时也必须失效")
        state.isTouching = false
        XCTAssertEqual(state.interactionGeneration, released.interactionGeneration,
                       "重复取消或松手通知不会推迟新的计时")
    }

    func testHeroPreheatIdentityDoesNotDependOnSwipeDirection() {
        for selection in 0..<5 {
            for presentation in [HomeHeroPresentation.fill, .fit] {
                XCTAssertEqual(HomeHeroRenderPolicy.prefetchIndices(selection: selection, count: 5,
                    presentation: presentation), [0, 1, 2, 3, 4])
                for index in 0..<5 {
                    XCTAssertTrue(HomeHeroRenderPolicy.shouldLoadRemoteImage(at: index,
                        selection: selection, count: 5, presentation: presentation))
                }
            }
        }
        XCTAssertEqual(HomeHeroRenderPolicy.prefetchIndices(selection: 0, count: 0), [])
        XCTAssertFalse(HomeHeroRenderPolicy.shouldLoadRemoteImage(at: 5, selection: 0, count: 5))
    }

    func testWeeklyHeroReorderingKeepsTheCurrentPhotoAndHandlesReplacement() {
        let originals = ContentCatalog.heroImages
        let reordered = Array(originals.reversed())
        XCTAssertEqual(HomeHeroRenderPolicy.selectionAfterUpdate(previous: originals,
            updated: reordered, selection: 1), originals.count - 2)
        XCTAssertEqual(HomeHeroRenderPolicy.selectionAfterUpdate(previous: originals,
            updated: [originals[0]], selection: 4), 0)
        XCTAssertEqual(HomeHeroRenderPolicy.selectionAfterUpdate(previous: [],
            updated: originals, selection: -1), 0)
        XCTAssertEqual(HomeHeroRenderPolicy.selectionAfterUpdate(previous: originals,
            updated: [], selection: 4), 0)
    }

    func testClassicHeroFillsViewportAndKeepsOverlayControlsInsideIt() {
        let sources = [CGSize(width: 959, height: 1440), CGSize(width: 1440, height: 959),
                       CGSize(width: 1200, height: 1200), CGSize(width: 2400, height: 600)]
        for viewport in [CGSize(width: 320, height: 480), CGSize(width: 375, height: 547),
                         CGSize(width: 440, height: 762), CGSize(width: 740, height: 310),
                         CGSize(width: 834, height: 1100), CGSize(width: 1376, height: 910)] {
            for largeText in [false, true] {
                let layout = HomeHeroOverlayLayout(viewport: viewport, accessibilityText: largeText)
                for frame in [layout.image, layout.caption, layout.weather] {
                    XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(frame))
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                }
                XCTAssertEqual(layout.image, CGRect(origin: .zero, size: viewport),
                               "经典首页图片必须铺满内容区，不能退回独立画廊照片框")
                XCTAssertTrue(layout.image.contains(layout.caption))
                XCTAssertTrue(layout.image.contains(layout.weather))
                XCTAssertFalse(layout.caption.intersects(layout.weather))
                for source in sources {
                    let fitted = HomeHeroRenderPolicy.fittedSize(sourceSize: source, in: layout.image.size)
                    XCTAssertEqual(fitted.width / fitted.height, source.width / source.height, accuracy: 0.0001)
                    XCTAssertLessThanOrEqual(fitted.width, layout.image.width + 0.001)
                    XCTAssertLessThanOrEqual(fitted.height, layout.image.height + 0.001)
                }
            }
        }
        XCTAssertEqual(HomeHeroOverlayLayout(viewport: .zero, accessibilityText: false).image, .zero)
    }

    func testEdgeToEdgeHeroKeepsControlsInsideDeviceAndTabSafeAreas() {
        for viewport in [CGSize(width: 375, height: 667), CGSize(width: 440, height: 956),
                         CGSize(width: 956, height: 440), CGSize(width: 1032, height: 1376),
                         CGSize(width: 1376, height: 1032)] {
            for insets in [EdgeInsets(top: 20, leading: 0, bottom: 49, trailing: 0),
                           EdgeInsets(top: 62, leading: 0, bottom: 96, trailing: 0),
                           EdgeInsets(top: 24, leading: 62, bottom: 83, trailing: 62)] {
                let safe = CGRect(x: insets.leading, y: insets.top,
                    width: viewport.width - insets.leading - insets.trailing,
                    height: viewport.height - insets.top - insets.bottom)
                for large in [false, true] {
                    let layout = HomeHeroOverlayLayout(viewport: viewport,
                        accessibilityText: large, safeAreaInsets: insets)
                    XCTAssertEqual(layout.image, CGRect(origin: .zero, size: viewport))
                    XCTAssertTrue(safe.contains(layout.weather))
                    XCTAssertTrue(safe.contains(layout.caption))
                    XCTAssertFalse(layout.weather.intersects(layout.caption))
                }
            }
        }
    }

    @MainActor
    func testLateHomeImageCompletionCannotRestoreRetiredOrBackgroundPhotos() {
        let oldURL = ContentCatalog.heroImages[0]
        let newURL = ContentCatalog.heroImages[1]
        let image = UIImage()
        let state = HomeHeroPlaybackState(selection: 0)
        state.isVisible = true
        state.isActive = true
        state.activeURLs = [newURL]
        state.selectedURL = newURL
        state.recordPreparedImage(image, for: oldURL)
        XCTAssertTrue(state.preparedImages.isEmpty, "上一期延迟返回的照片不得写回新一期")
        XCTAssertNil(state.landscapeContinuityImage)
        state.recordPreparedImage(image, for: newURL)
        XCTAssertTrue(state.preparedImages[newURL] === image)
        XCTAssertTrue(state.landscapeContinuityImage === image)
        state.preparedImages = [:]
        state.landscapeContinuityImage = nil
        state.isActive = false
        state.recordPreparedImage(image, for: newURL)
        XCTAssertTrue(state.preparedImages.isEmpty, "退到后台后延迟完成不能恢复已清空的照片")
        XCTAssertNil(state.landscapeContinuityImage)
        state.isActive = true
        state.isVisible = false
        state.recordPreparedImage(image, for: newURL)
        XCTAssertTrue(state.preparedImages.isEmpty)
    }

    func testLandscapeIPadWarmsEveryHeroBeforePaging() {
        XCTAssertEqual(
            HomeHeroRenderPolicy.prefetchIndices(
                selection: 0,
                count: 5,
                presentation: .fit
            ),
            [0, 1, 2, 3, 4]
        )
        for index in 0..<5 {
            XCTAssertTrue(
                HomeHeroRenderPolicy.shouldLoadRemoteImage(
                    at: index,
                    selection: 0,
                    count: 5,
                    presentation: .fit
                ),
                "iPad 横屏第 \(index + 1) 张首页图片没有在切页前加载"
            )
        }
    }

    func testRemoteLaunchPostersDoNotReuseAHomeHero() {
        let homeHeroes = Set(ContentCatalog.heroImages)

        XCTAssertEqual(ContentCatalog.launchPosters.count, 3)
        for poster in ContentCatalog.launchPosters {
            XCTAssertFalse(homeHeroes.contains(poster.imageURL))
            XCTAssertTrue(ContentSecurityPolicy.isTrustedMediaURL(poster.imageURL))
        }
        XCTAssertEqual(Set(ContentCatalog.launchPosters.map(\.id)).count, 3)
    }

    func testColdLaunchPosterSelectionIsClearedBetweenAccounts() {
        let firstAccountPoster = ContentCatalog.launchPosters[0]
        let secondAccountPoster = ContentCatalog.launchPosters[1]
        var state = ColdLaunchPosterSelectionState()

        state.record(firstAccountPoster)
        XCTAssertTrue(state.hasSelected)
        XCTAssertEqual(state.snapshot, firstAccountPoster)

        state.reset()
        XCTAssertFalse(state.hasSelected)
        XCTAssertNil(state.snapshot)

        state.record(secondAccountPoster)
        XCTAssertEqual(state.snapshot, secondAccountPoster)
        XCTAssertNotEqual(state.snapshot, firstAccountPoster)
    }

    func testLaunchPosterSelectionRotatesDeterministicallyWithoutRepeating() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let posters = [
            makeLaunchPoster(id: "third", startsAt: now.addingTimeInterval(-100)),
            makeLaunchPoster(id: "first", startsAt: now.addingTimeInterval(-300)),
            makeLaunchPoster(id: "second", startsAt: now.addingTimeInterval(-200)),
            makeLaunchPoster(
                id: "future",
                startsAt: now.addingTimeInterval(100),
                endsAt: now.addingTimeInterval(500)
            ),
        ]

        XCTAssertEqual(
            LaunchPosterSelectionPolicy.activeCandidates(in: posters, at: now).map(\.id),
            ["first", "second", "third"]
        )
        XCTAssertEqual(
            LaunchPosterSelectionPolicy.select(
                from: posters,
                at: now,
                previousID: nil
            )?.id,
            "first"
        )
        XCTAssertEqual(
            LaunchPosterSelectionPolicy.select(
                from: posters,
                at: now,
                previousID: "first"
            )?.id,
            "second"
        )
        XCTAssertEqual(
            LaunchPosterSelectionPolicy.select(
                from: posters,
                at: now,
                previousID: "third"
            )?.id,
            "first",
            "轮换回首张时也必须避免连续重复末张"
        )
    }

    func testLaunchPosterIgnoresLegacyFallbackMetadata() throws {
        let poster = makeLaunchPoster(
            id: "bundled-original",
            startsAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoded = try JSONEncoder().encode(poster)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject["fallbackAssetName"] = "LaunchPosterOriginalOne"
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(LaunchPosterContent.self, from: legacyData)
        XCTAssertEqual(decoded, poster)
    }

    func testAboutPortraitAcceptsOnlyTrustedHTTPSMedia() {
        let trusted = makeManifest(
            aboutPortraitURL: URL(string: "https://www.shuzijun.com.cn/wp-content/uploads/about.jpg")
        )
        let untrusted = makeManifest(
            aboutPortraitURL: URL(string: "https://example.com/about.jpg")
        )

        XCTAssertTrue(ContentSecurityPolicy.isTrusted(trusted))
        XCTAssertFalse(ContentSecurityPolicy.isTrusted(untrusted))
    }

    func testContentManifestsAndMediaResponsesAreEnvironmentScoped() throws {
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            let manifest = try environmentManifest(environment)
            XCTAssertTrue(ContentSecurityPolicy.isTrusted(manifest, environment: environment))
            XCTAssertFalse(ContentSecurityPolicy.isTrusted(manifest, environment: other))
            let url = try XCTUnwrap(manifest.heroImages.first)
            XCTAssertTrue(ContentSecurityPolicy.matchesRequestedMediaURL(url, requestedURL: url, environment: environment))
            XCTAssertFalse(ContentSecurityPolicy.matchesRequestedMediaURL(url, requestedURL: url, environment: other))
            XCTAssertFalse(ContentSecurityPolicy.matchesRequestedMediaURL(
                other.mediaUploadRoot.appending(path: "image.jpg"), requestedURL: url, environment: environment))
        }
        let review = try environmentManifest(.review)
        XCTAssertFalse(ContentSecurityPolicy.isTrusted(review), "Default policy must remain production-only")
        // Change each media URL independently, including nested cover/full-resolution,
        // video and poster fields. A single cross-environment asset must reject the whole graph.
        let data = try JSONEncoder().encode(review)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func variants(_ value: Any) -> [Any] {
            if let string = value as? String, string.hasPrefix("https://review.shuzijun.com.cn/") {
                return [string.replacingOccurrences(of: "review.shuzijun.com.cn", with: "www.shuzijun.com.cn")]
            }
            if let array = value as? [Any] {
                return array.indices.flatMap { index in variants(array[index]).map { replacement in
                    var changed = array; changed[index] = replacement; return changed as Any
                } }
            }
            if let object = value as? [String: Any] {
                return object.keys.flatMap { key in variants(object[key] as Any).map { replacement in
                    var changed = object; changed[key] = replacement; return changed as Any
                } }
            }
            return []
        }
        let mixedVariants = variants(json)
        XCTAssertGreaterThan(mixedVariants.count, 10)
        for variant in mixedVariants {
            let mixed = try JSONDecoder().decode(AppContentManifest.self, from: JSONSerialization.data(withJSONObject: variant))
            XCTAssertFalse(ContentSecurityPolicy.isTrusted(mixed, environment: .review))
        }
    }

    @MainActor
    func testReviewCatalogNeverFallsBackToProductionAndRejectsForeignRefresh() throws {
        let store = PortfolioStore(environment: .review)
        defer { store.discardProtectedContent() }
        XCTAssertTrue(store.portfolios.isEmpty)
        XCTAssertTrue(store.heroImages.isEmpty)
        XCTAssertNil(store.aboutPortraitURL)
        XCTAssertNil(store.showreel)
        XCTAssertTrue(store.dramas.isEmpty)
        XCTAssertTrue(store.launchPosters.isEmpty)
        let refresh = store.beginContentRefresh()
        XCTAssertFalse(store.completeContentRefresh(refresh, with: try environmentManifest(.production)))
        XCTAssertTrue(store.heroImages.isEmpty)
        let valid = store.beginContentRefresh()
        XCTAssertTrue(store.completeContentRefresh(valid, with: try environmentManifest(.review)))
        XCTAssertEqual(store.heroImages.first?.host, "review.shuzijun.com.cn")
        store.discardProtectedContent()
        XCTAssertTrue(store.heroImages.isEmpty)
        XCTAssertTrue(store.portfolios.isEmpty)
        XCTAssertNil(store.aboutPortraitURL)
        XCTAssertNil(store.showreel)
    }

    @MainActor
    func testCatalogCacheAndCleanupNeverCrossEnvironments() async throws {
        let production = PortfolioStore()
        let review = PortfolioStore(environment: .review)
        defer { production.discardProtectedContent(); review.discardProtectedContent() }
        production.discardProtectedContent()
        review.discardProtectedContent()
        production.applyPublishedManifest(try environmentManifest(.production))
        review.applyPublishedManifest(try environmentManifest(.review))
        for environment in AppServiceEnvironment.allCases {
            let reader = PortfolioStore(environment: environment)
            await reader.restoreCachedContent(allowVideo: false)
            XCTAssertEqual(reader.contentOrigin, .cached)
            XCTAssertTrue(reader.heroImages.allSatisfy { ContentSecurityPolicy.isTrustedMediaURL($0, environment: environment) })
            XCTAssertEqual(reader.portfolios.first?.images.count, 3)
            XCTAssertNil(reader.showreel)
        }
        review.discardProtectedContent()
        let productionReader = PortfolioStore()
        await productionReader.restoreCachedContent(allowVideo: true)
        XCTAssertEqual(productionReader.contentOrigin, .cached)
        let emptyReview = PortfolioStore(environment: .review)
        await emptyReview.restoreCachedContent(allowVideo: true)
        XCTAssertTrue(emptyReview.portfolios.isEmpty)
        review.applyPublishedManifest(try environmentManifest(.review))
        production.discardProtectedContent()
        let reviewReader = PortfolioStore(environment: .review)
        await reviewReader.restoreCachedContent(allowVideo: true)
        XCTAssertEqual(reviewReader.contentOrigin, .cached)
        XCTAssertEqual(reviewReader.heroImages.first?.host, "review.shuzijun.com.cn")
    }

    @MainActor
    func testFavoritesAndRecentsAreIsolatedEvenForIdenticalAccountIDs() throws {
        let defaults = try makePushStartupDefaults()
        let userID = UUID().uuidString
        let image = try XCTUnwrap(makePortfolio(imageCount: 3).images.first)
        let portfolio = makePortfolio(imageCount: 3)
        defaults.set([42], forKey: "favoritePortfolioImageIDs")
        defaults.set([42], forKey: "recentlyViewedPortfolioIDs")
        let reviewFavorites = FavoritesStore(defaults: defaults, environment: .review)
        let reviewRecents = RecentlyViewedStore(defaults: defaults, environment: .review)
        XCTAssertEqual(defaults.array(forKey: "favoritePortfolioImageIDs") as? [Int], [42])
        XCTAssertEqual(defaults.array(forKey: "recentlyViewedPortfolioIDs") as? [Int], [42])
        let productionFavorites = FavoritesStore(defaults: defaults)
        let productionRecents = RecentlyViewedStore(defaults: defaults)
        productionFavorites.activate(accountID: userID)
        productionRecents.activate(accountID: userID)
        productionFavorites.toggle(image)
        productionRecents.record(portfolio)
        reviewFavorites.activate(accountID: userID)
        reviewRecents.activate(accountID: userID)
        XCTAssertTrue(reviewFavorites.imageIDs.isEmpty)
        XCTAssertTrue(reviewRecents.portfolioIDs.isEmpty)
        reviewFavorites.toggle(image)
        reviewRecents.record(portfolio)
        reviewFavorites.removeData(for: userID)
        reviewRecents.removeData(for: userID)
        productionFavorites.deactivate(); productionFavorites.activate(accountID: userID)
        productionRecents.deactivate(); productionRecents.activate(accountID: userID)
        XCTAssertTrue(productionFavorites.contains(image))
        XCTAssertEqual(productionRecents.portfolioIDs, [portfolio.id])
        reviewFavorites.toggle(image)
        reviewRecents.record(portfolio)
        productionFavorites.removeData(for: userID)
        productionRecents.removeData(for: userID)
        reviewFavorites.deactivate(); reviewFavorites.activate(accountID: userID)
        reviewRecents.deactivate(); reviewRecents.activate(accountID: userID)
        XCTAssertTrue(reviewFavorites.contains(image))
        XCTAssertEqual(reviewRecents.portfolioIDs, [portfolio.id])
    }

    @MainActor
    func testLaunchPosterRotationDoesNotReadOrWriteOtherEnvironmentHistory() throws {
        let defaults = try makePushStartupDefaults()
        let production = PortfolioStore()
        let review = PortfolioStore(environment: .review)
        defer { production.discardProtectedContent(); review.discardProtectedContent() }
        production.applyPublishedManifest(try environmentManifest(.production))
        review.applyPublishedManifest(try environmentManifest(.review))
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(production.selectLaunchPosterForColdLaunch(at: date, defaults: defaults)?.id, "first")
        XCTAssertEqual(review.selectLaunchPosterForColdLaunch(at: date, defaults: defaults)?.id, "first")
        XCTAssertEqual(review.selectLaunchPosterForColdLaunch(at: date, defaults: defaults)?.id, "second")
        XCTAssertEqual(production.selectLaunchPosterForColdLaunch(at: date, defaults: defaults)?.id, "second")
    }

    @MainActor
    func testAdministratorContentCannotPublishOrAcceptOtherEnvironmentMedia() async throws {
        for environment in AppServiceEnvironment.allCases {
            let other: AppServiceEnvironment = environment == .production ? .review : .production
            let account = BoundAdministratorTestAccount()
            account.administratorContext = .init(userID: "test-user", sessionGeneration: 1, environment: environment)
            let manifest = try environmentManifest(environment)
            let foreign = try environmentManifest(other)
            var sendsForeignContent = false
            var requests = [URLRequest]()
            let admin = AdminSessionStore(environment: environment) { request in
                requests.append(request)
                let url = try XCTUnwrap(request.url)
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                if url.path.hasSuffix("/session") {
                    return (Data(#"{"authenticated":true,"role":"yishu_content_manager","displayName":"测试管理员"}"#.utf8), response)
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return (try encoder.encode(sendsForeignContent ? foreign : manifest), response)
            }
            defer { admin.lock() }
            await admin.signIn(using: account)
            XCTAssertTrue(admin.isAuthenticated)
            let content = try await admin.fetchContent()
            XCTAssertEqual(content.heroImages, manifest.heroImages)
            let before = requests.count
            do {
                _ = try await admin.publishAboutPortrait(try XCTUnwrap(foreign.aboutPortraitURL))
                XCTFail("Foreign portrait was published")
            } catch { XCTAssertEqual(requests.count, before) }
            do {
                _ = try await admin.publish(heroImages: foreign.heroImages, aboutPortraitURL: nil,
                    launchPosters: manifest.launchPosters ?? [], showreel: try XCTUnwrap(manifest.showreel), dramas: manifest.dramas)
                XCTFail("Foreign hero was published")
            } catch { XCTAssertEqual(requests.count, before) }
            let published = try await admin.publishAboutPortrait(try XCTUnwrap(manifest.aboutPortraitURL))
            XCTAssertEqual(published.aboutPortraitURL, manifest.aboutPortraitURL)
            XCTAssertEqual(requests.last?.httpMethod, "POST")
            XCTAssertTrue(requests.allSatisfy { $0.url?.host == environment.apiHost })
            sendsForeignContent = true
            do { _ = try await admin.fetchContent(); XCTFail("Foreign manifest was accepted") }
            catch { XCTAssertTrue(admin.isAuthenticated) }
        }
    }

    private func environmentManifest(_ environment: AppServiceEnvironment) throws -> AppContentManifest {
        let base = makeManifest(
            aboutPortraitURL: AppURL.make("https://www.shuzijun.com.cn/test/about.jpg"), imageCount: 6,
            launchPosters: [makeLaunchPoster(id: "first", startsAt: .distantPast),
                            makeLaunchPoster(id: "second", startsAt: .distantPast)])
        guard environment == .review else { return base }
        let data = try JSONEncoder().encode(base)
        var text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for host in ["www.shuzijun.com.cn", "img.shuzijun.com.cn", "shuzijun.com.cn"] {
            // Match the serialized HTTPS prefix, not suffixes inside another host.
            text = text.replacingOccurrences(of: "https:\\/\\/\(host)\\/", with: "https:\\/\\/review.shuzijun.com.cn\\/")
        }
        return try JSONDecoder().decode(AppContentManifest.self, from: Data(text.utf8))
    }

    func testAboutPortraitSelectionUsesConfiguredURLBeforeEveryFallback() {
        let configured = URL(
            string: "https://www.shuzijun.com.cn/wp-content/uploads/about-configured.jpg"
        )!
        let hero = URL(string: "https://img.shuzijun.com.cn/test/about-hero.jpg")!
        let portfolio = makePortfolio(imageCount: 1)

        XCTAssertEqual(
            AboutPortraitSelectionPolicy.select(
                configuredURL: configured,
                heroImages: [hero],
                portfolios: [portfolio]
            ),
            configured
        )
    }

    func testAboutPortraitSelectionFallsBackToHeroThenPortfolioCover() {
        let hero = URL(string: "https://img.shuzijun.com.cn/test/about-hero.jpg")!
        let portfolio = makePortfolio(imageCount: 1)
        let portfolioWithoutCover = Portfolio(
            id: 2,
            title: "无封面相册",
            subtitle: "回归测试",
            eyebrow: "TEST",
            slug: "no-cover",
            websiteURL: URL(
                string: "https://www.shuzijun.com.cn/portfolio/no-cover/"
            )!,
            coverURL: nil,
            images: []
        )

        XCTAssertEqual(
            AboutPortraitSelectionPolicy.select(
                configuredURL: nil,
                heroImages: [hero],
                portfolios: [portfolio]
            ),
            hero
        )
        XCTAssertEqual(
            AboutPortraitSelectionPolicy.select(
                configuredURL: nil,
                heroImages: [],
                portfolios: [portfolioWithoutCover, portfolio]
            ),
            portfolio.coverURL
        )
        XCTAssertNil(
            AboutPortraitSelectionPolicy.select(
                configuredURL: nil,
                heroImages: [],
                portfolios: []
            )
        )
    }

    @MainActor
    func testAboutPortraitFallbackNeverBecomesAnImplicitAdministratorDraft() throws {
        let manifest = makeManifest(aboutPortraitURL: nil)
        let store = PortfolioStore()

        store.applyPublishedManifest(manifest)

        XCTAssertNil(store.configuredAboutPortraitURL)
        XCTAssertEqual(store.aboutPortraitURL, manifest.heroImages.first)

        let update = AppContentUpdate(
            heroImages: manifest.heroImages,
            aboutPortraitURL: store.configuredAboutPortraitURL,
            launchPosters: try XCTUnwrap(manifest.launchPosters),
            showreel: try XCTUnwrap(manifest.showreel),
            dramas: manifest.dramas
        )
        let data = try JSONEncoder().encode(update)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(
            object["aboutPortraitURL"],
            "保存其他字段时必须省略未配置的关于页照片，不得写入展示用备用图"
        )
    }

    func testAboutPortraitPartialUpdateEncodesNoUnrelatedContent() throws {
        let portraitURL = URL(
            string: "https://www.shuzijun.com.cn/wp-content/uploads/about-published.jpg"
        )!
        let data = try JSONEncoder().encode(
            AboutPortraitUpdate(aboutPortraitURL: portraitURL)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["aboutPortraitURL"])
        XCTAssertEqual(object["aboutPortraitURL"] as? String, portraitURL.absoluteString)
    }

    func testMissingAboutPortraitKeepsOlderManifestsCompatible() throws {
        let original = makeManifest(aboutPortraitURL: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppContentManifest.self, from: data)

        XCTAssertNil(decoded.aboutPortraitURL)
        XCTAssertTrue(ContentSecurityPolicy.isTrusted(decoded))
    }

    func testManifestPolicyRejectsOversizedAndDuplicateCollections() {
        let base = makeManifest(aboutPortraitURL: nil)
        XCTAssertTrue(ContentManifestPolicy.isValid(base))

        let tooManyHeroes = (0..<6).map { index in
            URL(string: "https://img.shuzijun.com.cn/test/hero-\(index).jpg")!
        }
        let oversized = AppContentManifest(
            schemaVersion: base.schemaVersion,
            updatedAt: base.updatedAt,
            heroImages: tooManyHeroes,
            aboutPortraitURL: base.aboutPortraitURL,
            launchPosters: base.launchPosters,
            showreel: base.showreel,
            dramas: base.dramas,
            portfolios: base.portfolios
        )
        XCTAssertFalse(ContentManifestPolicy.isValid(oversized))
        XCTAssertFalse(ContentSecurityPolicy.isTrusted(oversized))

        let duplicatePortfolios = AppContentManifest(
            schemaVersion: base.schemaVersion,
            updatedAt: base.updatedAt,
            heroImages: base.heroImages,
            aboutPortraitURL: base.aboutPortraitURL,
            launchPosters: base.launchPosters,
            showreel: base.showreel,
            dramas: base.dramas,
            portfolios: [base.portfolios[0], base.portfolios[0]]
        )
        XCTAssertFalse(ContentManifestPolicy.isValid(duplicatePortfolios))
    }

    func testManifestPolicyRejectsUnsafeTimingAndUnknownCacheVersions() {
        let base = makeManifest(aboutPortraitURL: nil)
        var invalidPoster = ContentCatalog.launchPosters[0]
        invalidPoster.displaySeconds = .infinity
        let invalidTiming = AppContentManifest(
            schemaVersion: base.schemaVersion,
            updatedAt: base.updatedAt,
            heroImages: base.heroImages,
            aboutPortraitURL: base.aboutPortraitURL,
            launchPosters: [invalidPoster],
            showreel: base.showreel,
            dramas: base.dramas,
            portfolios: base.portfolios
        )

        XCTAssertFalse(ContentManifestPolicy.isValid(invalidTiming))
        XCTAssertFalse(ContentManifestPolicy.isSupportedCacheSchemaVersion(nil))
        XCTAssertFalse(ContentManifestPolicy.isSupportedCacheSchemaVersion(1))
        XCTAssertFalse(ContentManifestPolicy.isSupportedCacheSchemaVersion(2))
        XCTAssertFalse(
            ContentManifestPolicy.isSupportedCacheSchemaVersion(3),
            "Build 41 必须拒绝可能保留旧开屏 URL 的缓存"
        )
        XCTAssertTrue(ContentManifestPolicy.isSupportedCacheSchemaVersion(4))
        XCTAssertFalse(ContentManifestPolicy.isSupportedCacheSchemaVersion(5))
    }

    func testInsecureOrUnknownMediaHostsAreRejected() {
        XCTAssertFalse(
            ContentSecurityPolicy.isTrustedMediaURL(
                URL(string: "http://www.shuzijun.com.cn/photo.jpg")!
            )
        )
        XCTAssertFalse(
            ContentSecurityPolicy.isTrustedMediaURL(
                URL(string: "https://example.com/photo.jpg")!
            )
        )
        XCTAssertFalse(
            ContentSecurityPolicy.isTrustedMediaURL(
                URL(
                    string: "https://img.shuzijun.com.cn/\(String(repeating: "a", count: 2_100)).jpg"
                )!
            )
        )
    }

    func testAppURLPreservesValidValuesAndFailsClosedForInvalidValues() {
        let rawValue = "https://www.shuzijun.com.cn/path/image.jpg?size=large"

        XCTAssertEqual(AppURL.make(rawValue).absoluteString, rawValue)

        let invalidURL = AppURL.make("")
        XCTAssertTrue(invalidURL.isFileURL)
        XCTAssertFalse(AppNetworkSecurityPolicy.isTrustedHTTPSOrigin(invalidURL))
        XCTAssertFalse(AppNetworkSecurityPolicy.isTrustedAdminRequestURL(invalidURL))
    }

    func testPublishedManifestUsesAStableTrustedHTTPSEndpoint() {
        let endpoint = ContentCatalog.publishedManifestURL

        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.host, "shuzijun.com.cn")
        XCTAssertNil(endpoint.user)
        XCTAssertNil(endpoint.password)
    }

    func testDramaFallbacksUseTheRenewedActorShareLink() {
        XCTAssertEqual(ContentCatalog.hongguoURL.absoluteString,
                       "https://novelquickapp.com/s/qcN1w-iokyY/")
        XCTAssertEqual(ContentCatalog.dramas.count, 5)
        for drama in ContentCatalog.dramas {
            XCTAssertEqual(drama.destinationURL, ContentCatalog.hongguoURL)
        }
    }

    func testPrivacyPolicyUsesTheOfficialHTTPSOrigin() {
        XCTAssertTrue(AppNetworkSecurityPolicy.isTrustedHTTPSOrigin(ContentCatalog.privacyPolicyURL))
        XCTAssertEqual(ContentCatalog.privacyPolicyURL.path, "/app-privacy")
    }

    func testBusinessAndPrivacyMailboxesAreExplicitlySeparated() {
        XCTAssertEqual(ContentCatalog.collaborationEmailAddress, "369476120@qq.com")
        XCTAssertEqual(ContentCatalog.emailURL.absoluteString, "mailto:369476120@qq.com")
        XCTAssertEqual(ContentCatalog.privacyContactEmailAddress, "support@shuzijun.com.cn")
        XCTAssertEqual(ContentCatalog.privacyEmailURL.absoluteString, "mailto:support@shuzijun.com.cn")
        XCTAssertNotEqual(
            ContentCatalog.collaborationEmailAddress,
            ContentCatalog.privacyContactEmailAddress
        )
    }

    func testPublishedManifestResponseMustMatchTheExactConfiguredEndpoint() {
        let expected = ContentCatalog.publishedManifestURL

        XCTAssertTrue(AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(expected, expected: expected))
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "http://shuzijun.com.cn\(expected.path)"),
                expected: expected
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "https://shuzijun.com.cn.evil.example\(expected.path)"),
                expected: expected
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "https://shuzijun.com.cn:444\(expected.path)"),
                expected: expected
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.matchesPublishedContentEndpoint(
                URL(string: "https://user:password@shuzijun.com.cn\(expected.path)"),
                expected: expected
            )
        )
    }

    func testAdministratorRequestsStayInsideTheWordPressAPINamespace() {
        XCTAssertTrue(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://shuzijun.com.cn/wp-json/shuzijun/v1/app-admin/session")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://shuzijun.com.cn/wp-json-evil/session")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://img.shuzijun.com.cn/wp-json/shuzijun/v1/app-admin/session")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminAPIURL(
                URL(string: "https://www.shuzijun.com.cn/wp-json/shuzijun/v1/app-admin/session")
            )
        )

        XCTAssertTrue(
            AppNetworkSecurityPolicy.isTrustedAdminMediaUploadURL(
                URL(string: "https://www.shuzijun.com.cn/wp-json/wp/v2/media")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminMediaUploadURL(
                URL(string: "https://www.shuzijun.com.cn/wp-json/wp/v2/users")
            )
        )
        XCTAssertFalse(
            AppNetworkSecurityPolicy.isTrustedAdminMediaUploadURL(
                URL(string: "https://shuzijun.com.cn/wp-json/wp/v2/media")
            )
        )
    }

    func testAdministratorUnlockAlwaysExpiresAndMissingExpiryIsLocked() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(AdminSessionSecurityPolicy.isFresh(expiresAt: nil, now: now))
        XCTAssertFalse(
            AdminSessionSecurityPolicy.isFresh(
                expiresAt: Date(timeIntervalSince1970: 999),
                now: now
            )
        )
        XCTAssertTrue(
            AdminSessionSecurityPolicy.isFresh(
                expiresAt: Date(timeIntervalSince1970: 1_001),
                now: now
            )
        )
        XCTAssertFalse(
            AdminSessionSecurityPolicy.canAcceptResponse(
                requestGeneration: 7,
                currentGeneration: 8,
                expiresAt: Date(timeIntervalSince1970: 1_001),
                now: now
            )
        )
        XCTAssertTrue(
            AdminSessionSecurityPolicy.canAcceptResponse(
                requestGeneration: 8,
                currentGeneration: 8,
                expiresAt: Date(timeIntervalSince1970: 1_001),
                now: now
            )
        )
    }

    func testPermissionScopedManifestCanOmitAllVideoMetadata() {
        let full = makeManifest(aboutPortraitURL: nil)
        let scoped = AppContentManifest(
            schemaVersion: full.schemaVersion,
            updatedAt: full.updatedAt,
            heroImages: full.heroImages,
            aboutPortraitURL: full.aboutPortraitURL,
            launchPosters: full.launchPosters,
            showreel: nil,
            dramas: [],
            portfolios: full.portfolios
        )

        XCTAssertTrue(ContentManifestPolicy.isValid(scoped))
        XCTAssertTrue(ContentSecurityPolicy.isTrusted(scoped))
    }

    @MainActor
    func testPermissionDowngradeFailsClosedInMemoryAndCannotExpandLocally() {
        let store = PortfolioStore()
        let full = makeManifest(aboutPortraitURL: nil, imageCount: 6)
        defer { store.discardProtectedContent() }

        store.applyPublishedManifest(full)
        XCTAssertEqual(store.portfolios.first?.images.count, 6)
        XCTAssertNotNil(store.showreel)
        XCTAssertFalse(store.dramas.isEmpty)

        store.enforcePermissionScope(canViewFullGallery: false, canViewVideo: false)
        XCTAssertEqual(store.portfolios.first?.images.count, 3)
        XCTAssertEqual(store.portfolios.first?.displayImageCount, 6)
        XCTAssertNil(store.showreel)
        XCTAssertTrue(store.dramas.isEmpty)

        // A local permission flag change must not resurrect removed URLs. Only a
        // new server-authorized manifest can expand the in-memory catalog again.
        store.enforcePermissionScope(canViewFullGallery: true, canViewVideo: true)
        XCTAssertEqual(store.portfolios.first?.images.count, 3)
        XCTAssertNil(store.showreel)
        XCTAssertTrue(store.dramas.isEmpty)

        store.applyPublishedManifest(full)
        XCTAssertEqual(store.portfolios.first?.images.count, 6)
        XCTAssertNotNil(store.showreel)
        XCTAssertFalse(store.dramas.isEmpty)
    }

    func testAdministratorEditorRequiresAuthenticationAndFullManifest() {
        XCTAssertFalse(
            AdminContentEditingPolicy.canEdit(
                isAuthenticated: false,
                hasLoadedFullManifest: false
            )
        )
        XCTAssertFalse(
            AdminContentEditingPolicy.canEdit(
                isAuthenticated: true,
                hasLoadedFullManifest: false
            )
        )
        XCTAssertFalse(
            AdminContentEditingPolicy.canEdit(
                isAuthenticated: false,
                hasLoadedFullManifest: true
            )
        )
        XCTAssertTrue(
            AdminContentEditingPolicy.canEdit(
                isAuthenticated: true,
                hasLoadedFullManifest: true
            )
        )

        let full = makeManifest(aboutPortraitURL: nil, imageCount: 6)
        let fanScoped = AppContentManifest(
            schemaVersion: full.schemaVersion,
            updatedAt: full.updatedAt,
            heroImages: full.heroImages,
            aboutPortraitURL: full.aboutPortraitURL,
            launchPosters: full.launchPosters,
            showreel: nil,
            dramas: [],
            portfolios: full.portfolios
        )
        let fullPortfolio = full.portfolios[0]
        let galleryPreview = Portfolio(
            id: fullPortfolio.id,
            title: fullPortfolio.title,
            subtitle: fullPortfolio.subtitle,
            eyebrow: fullPortfolio.eyebrow,
            slug: fullPortfolio.slug,
            websiteURL: fullPortfolio.websiteURL,
            coverURL: fullPortfolio.coverURL,
            images: Array(fullPortfolio.images.prefix(3)),
            totalImageCount: fullPortfolio.images.count
        )
        let videoEnabledFanScope = AppContentManifest(
            schemaVersion: full.schemaVersion,
            updatedAt: full.updatedAt,
            heroImages: full.heroImages,
            aboutPortraitURL: full.aboutPortraitURL,
            launchPosters: full.launchPosters,
            showreel: full.showreel,
            dramas: full.dramas,
            portfolios: [galleryPreview]
        )
        XCTAssertTrue(AdminContentEditingPolicy.isFullAdministratorManifest(full))
        XCTAssertFalse(AdminContentEditingPolicy.isFullAdministratorManifest(fanScoped))
        XCTAssertFalse(
            AdminContentEditingPolicy.isFullAdministratorManifest(videoEnabledFanScope)
        )
    }

    func testExplicitAdministratorAudienceAllowsPhotoOnlyContentButNeverViewerOrPartialAlbums() throws {
        let full = makeManifest(aboutPortraitURL: nil, imageCount: 6)
        func manifest(_ audience: AppContentAudience?, video: ShowreelContent? = nil,
                      portfolios: [Portfolio]? = nil) -> AppContentManifest {
            AppContentManifest(schemaVersion: full.schemaVersion, updatedAt: full.updatedAt,
                heroImages: full.heroImages, aboutPortraitURL: full.aboutPortraitURL,
                launchPosters: full.launchPosters, showreel: video, dramas: [],
                portfolios: portfolios ?? full.portfolios, contentAudience: audience)
        }
        let photoOnly = manifest(.administrator)
        XCTAssertTrue(ContentManifestPolicy.isValid(photoOnly))
        XCTAssertTrue(AdminContentEditingPolicy.isFullAdministratorManifest(photoOnly))
        XCTAssertFalse(AdminContentEditingPolicy.canEdit(isAuthenticated: false, hasLoadedFullManifest: true))
        for video in [nil, full.showreel] {
            XCTAssertFalse(AdminContentEditingPolicy.isFullAdministratorManifest(manifest(.viewer, video: video)),
                "An explicit viewer response cannot fall back to legacy video-based acceptance")
        }
        XCTAssertFalse(AdminContentEditingPolicy.isFullAdministratorManifest(manifest(nil)))
        XCTAssertTrue(AdminContentEditingPolicy.isFullAdministratorManifest(manifest(nil, video: full.showreel)),
            "Legacy production servers keep their previous contract until deployment")
        let p = full.portfolios[0]
        let partial = Portfolio(id: p.id, title: p.title, subtitle: p.subtitle, eyebrow: p.eyebrow,
            slug: p.slug, websiteURL: p.websiteURL, coverURL: p.coverURL,
            images: Array(p.images.prefix(3)), totalImageCount: p.images.count)
        XCTAssertFalse(AdminContentEditingPolicy.isFullAdministratorManifest(manifest(.administrator, portfolios: [partial])))
        let data = try JSONEncoder().encode(photoOnly)
        let decoded = try JSONDecoder().decode(AppContentManifest.self, from: data)
        XCTAssertEqual(decoded.contentAudience, .administrator)
        XCTAssertNil(decoded.showreel)
        XCTAssertTrue(AdminContentEditingPolicy.isFullAdministratorManifest(decoded))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for invalid: Any in ["admin", "unknown", "", true, 1, ["administrator"]] {
            object["contentAudience"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(AppContentManifest.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testAdministratorMediaPreviewsAlwaysPreserveTheCompleteAsset() {
        switch AdminMediaPreviewPolicy.contentMode {
        case .fit:
            break
        case .fill:
            XCTFail("Administrator previews must not crop the source asset")
        @unknown default:
            XCTFail("Administrator previews use an unsupported content mode")
        }
    }

    @MainActor
    func testAppearanceDefaultsToBlackGoldAndPersistsEverySupportedTheme() throws {
        let defaults = try makePushStartupDefaults()
        XCTAssertNil(defaults.object(forKey: AppearanceStore.preferenceKey))
        let store = AppearanceStore(defaults: defaults)
        XCTAssertEqual(store.theme, .blackGold)
        defaults.set("untouched", forKey: "account-fixture-sentinel")
        for theme in AppColorTheme.allCases {
            store.select(theme)
            XCTAssertEqual(AppearanceStore(defaults: defaults).theme, theme)
            XCTAssertEqual(defaults.string(forKey: "account-fixture-sentinel"), "untouched")
        }
        store.select(.blackGold)
        XCTAssertEqual(AppearanceStore(defaults: defaults).theme, .blackGold)
    }

    @MainActor
    func testInvalidAppearancePreferenceFallsBackWithoutChangingAccounts() throws {
        let defaults = try makePushStartupDefaults()
        for value in ["", "future-theme", "../../account", "IVORY"] {
            defaults.set(value, forKey: AppearanceStore.preferenceKey)
            XCTAssertEqual(AppearanceStore(defaults: defaults).theme, .blackGold)
        }
    }

    @MainActor
    func testAppearanceChangesAreObservableWithoutReplacingNavigation() throws {
        let defaults = try makePushStartupDefaults()
        let store = AppearanceStore(defaults: defaults)
        let changed = expectation(description: "Theme observation notified")
        withObservationTracking { _ = store.theme.palette } onChange: { changed.fulfill() }
        store.select(.pine)
        wait(for: [changed], timeout: 1)
    }

    func testAllThemeTextAndControlsMeetNormalTextContrast() {
        for theme in AppColorTheme.allCases {
            let palette = theme.palette
            for background in [palette.background, palette.surface] {
                for foreground in [palette.text, palette.secondary, palette.accent] {
                    XCTAssertGreaterThanOrEqual(foreground.contrast(with: background), 4.5,
                                               "\(theme.name) 的正文/次级文字/强调色对比度不足")
                }
            }
            XCTAssertGreaterThanOrEqual(palette.text.contrast(with: palette.background), 7)
            XCTAssertGreaterThanOrEqual(palette.accent.contrast(with: palette.background), 4.5)
        }
        XCTAssertEqual(AppColorTheme.ivory.colorScheme, .light)
        XCTAssertEqual(AppColorTheme.blush.colorScheme, .light)
        XCTAssertEqual(AppColorTheme.bamboo.colorScheme, .light)
        XCTAssertTrue([AppColorTheme.blackGold, .pine, .indigo, .plum, .rouge].allSatisfy { $0.colorScheme == .dark })
    }

    func testMediaCanvasesKeepOriginalBlackGoldColors() {
        let original = AppColorTheme.blackGold.palette
        XCTAssertEqual(original.background, ThemeRGB(red: 0.025, green: 0.023, blue: 0.022))
        XCTAssertEqual(MediaTheme.ink, original.background.color)
        XCTAssertEqual(MediaTheme.gold, original.accent.color)
        XCTAssertEqual(MediaTheme.warmWhite, original.text.color)
    }

    func testClassicHeroLayoutDoesNotDependOnTheSelectedPhotoOrTheme() {
        for largeText in [false, true] {
            let portrait = HomeHeroOverlayLayout(viewport: CGSize(width: 834, height: 1100),
                                             accessibilityText: largeText)
            let landscape = HomeHeroOverlayLayout(viewport: CGSize(width: 1194, height: 740),
                                              accessibilityText: largeText)
            XCTAssertFalse(portrait.isCompact)
            XCTAssertGreaterThan(portrait.caption.minY, portrait.image.midY)
            XCTAssertTrue(landscape.isCompact)
            XCTAssertGreaterThan(landscape.caption.minY, landscape.image.midY)
            XCTAssertEqual(landscape.image.width, 1194)
            // Recreating a slot has no image- or theme-dependent measurement
            // that could trigger the old first-frame resizing effect.
            XCTAssertEqual(portrait, HomeHeroOverlayLayout(viewport: CGSize(width: 834, height: 1100),
                                                       accessibilityText: largeText))
        }
    }

    @MainActor
    func testMediaSystemAppearanceIsTransientAndDoesNotOverwriteUserTheme() throws {
        let defaults = try makePushStartupDefaults()
        let store = AppearanceStore(defaults: defaults)
        for theme in AppColorTheme.allCases where theme.colorScheme == .light {
            store.select(theme)
            store.setDarkMediaCanvasVisible(true)
            XCTAssertEqual(store.systemColorScheme, .dark)
            XCTAssertEqual(store.theme, theme)
            XCTAssertEqual(AppearanceStore(defaults: defaults).systemColorScheme, .light)
            store.setDarkMediaCanvasVisible(false)
            XCTAssertEqual(store.systemColorScheme, .light)
        }
    }

    func testNewLaunchPosterDraftUsesCurrentWelcomeCopyWithoutChangingManagedPosters() {
        let original = ContentCatalog.launchPosters[0]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let draft = LaunchPosterContent.newDraft(imageURL: original.imageURL, now: now, calendar: calendar)
        XCTAssertNotEqual(draft.id, original.id)
        XCTAssertEqual(draft.imageURL, original.imageURL)
        XCTAssertEqual(draft.eyebrow, "东方美学")
        XCTAssertEqual(draft.title, "易姝")
        XCTAssertEqual(draft.subtitle, "很高兴，在这里遇见你。")
        XCTAssertEqual(draft.startsAt, calendar.startOfDay(for: now))
        XCTAssertEqual(calendar.dateComponents([.day], from: draft.startsAt, to: draft.endsAt).day, 30)
        XCTAssertTrue(draft.isActive(at: now))
        XCTAssertEqual(draft.displaySeconds, 2.5)
        for fallback in ContentCatalog.launchPosters {
            XCTAssertEqual(fallback.eyebrow, draft.eyebrow)
            XCTAssertEqual(fallback.title, draft.title)
            XCTAssertEqual(fallback.subtitle, draft.subtitle)
        }
        XCTAssertEqual(ContentCatalog.launchPosters[0], original)
    }

    @MainActor
    func testColdLaunchUsesFreshPublishedCopyInsteadOfBundledOrCachedCopy() async throws {
        let store = PortfolioStore()
        let defaults = try makePushStartupDefaults()
        defer { store.discardProtectedContent() }
        XCTAssertNil(store.selectLaunchPosterForColdLaunch(defaults: defaults))
        let old = makeManifest(aboutPortraitURL: nil)
        store.applyPublishedManifest(old)
        // Simulate a cold start with a previously published metadata cache.
        let restarted = PortfolioStore()
        await restarted.restoreCachedContent(allowVideo: true)
        XCTAssertEqual(restarted.contentOrigin, .cached)
        XCTAssertNil(restarted.selectLaunchPosterForColdLaunch(defaults: defaults))

        var edited = try XCTUnwrap(old.launchPosters?.first)
        edited.eyebrow = "后台眉题"
        edited.title = "后台标题"
        edited.subtitle = "管理员已发布的新文案，保留原样。"
        let published = makeManifest(aboutPortraitURL: nil, launchPosters: [edited])
        let refreshID = restarted.beginContentRefresh()
        let fresh = try await LaunchPosterFreshContentLoader.load {
            try await Task.sleep(for: .milliseconds(20))
            return published
        }
        XCTAssertTrue(restarted.completeContentRefresh(refreshID, with: fresh))
        let selected = restarted.selectLaunchPosterForColdLaunch(defaults: defaults)
        XCTAssertEqual(selected, edited, "第一次开屏即使用发布回执中的完整文案，不再慢一次启动")
        XCTAssertEqual(selected, restarted.launchPosters.first, "后台预览和开屏使用同一份发布内容")
    }

    @MainActor
    func testMissingEmptyDisabledAndExpiredPublishedPostersNeverReviveDefaults() throws {
        let store = PortfolioStore()
        defer { store.discardProtectedContent() }
        let defaults = try makePushStartupDefaults()
        var disabled = try XCTUnwrap(ContentCatalog.launchPosters.first)
        disabled.isEnabled = false
        var expired = disabled
        expired.isEnabled = true
        expired.endsAt = Date().addingTimeInterval(-60)
        for posters: [LaunchPosterContent]? in [nil, [], [disabled], [expired]] {
            store.applyPublishedManifest(makeManifest(aboutPortraitURL: nil))
            store.applyPublishedManifest(makeManifest(aboutPortraitURL: nil, launchPosters: posters))
            XCTAssertNil(store.selectLaunchPosterForColdLaunch(defaults: defaults))
        }
    }

    @MainActor
    func testColdLaunchTimeoutCancelsRequestWithoutSelectingStaleCopy() async throws {
        let store = PortfolioStore()
        defer { store.discardProtectedContent() }
        let cancelled = expectation(description: "慢请求已取消")
        let started = ContinuousClock.now
        do {
            _ = try await LaunchPosterFreshContentLoader.load(timeout: .milliseconds(30)) {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { cancelled.fulfill(); throw error }
                return self.makeManifest(aboutPortraitURL: nil)
            }
            XCTFail("超时不应返回旧内容")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertNil(store.selectLaunchPosterForColdLaunch())
    }

    @MainActor
    func testColdLaunchFailureAndCancellationNeverProduceContent() async {
        do {
            _ = try await LaunchPosterFreshContentLoader.load {
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("断网不应恢复旧海报")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let task = Task {
            try await LaunchPosterFreshContentLoader.load {
                try await Task.sleep(for: .seconds(10))
                return self.makeManifest(aboutPortraitURL: nil)
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("退出或换号后不能继续选片") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testSupersededOrDiscardedContentRefreshCannotPublishOldPoster() {
        let store = PortfolioStore()
        defer { store.discardProtectedContent() }
        let oldID = store.beginContentRefresh()
        let newID = store.beginContentRefresh()
        let empty = makeManifest(aboutPortraitURL: nil, launchPosters: [])
        XCTAssertTrue(store.completeContentRefresh(newID, with: empty))
        XCTAssertFalse(store.completeContentRefresh(oldID, with: makeManifest(aboutPortraitURL: nil)))
        XCTAssertTrue(store.launchPosters.isEmpty)
        let discardedID = store.beginContentRefresh()
        store.discardProtectedContent()
        XCTAssertFalse(store.completeContentRefresh(discardedID, with: makeManifest(aboutPortraitURL: nil)))
        XCTAssertNil(store.selectLaunchPosterForColdLaunch())
    }

    @MainActor
    func testMetadataCacheWritesAndDeletionKeepPublicationOrder() async throws {
        let store = PortfolioStore()
        defer { store.discardProtectedContent() }
        var poster = try XCTUnwrap(ContentCatalog.launchPosters.first)
        for index in 0..<20 {
            poster.subtitle = "发布文案 \(index)"
            store.applyPublishedManifest(makeManifest(aboutPortraitURL: nil, launchPosters: [poster]))
        }
        let reader = PortfolioStore()
        await reader.restoreCachedContent(allowVideo: true)
        XCTAssertEqual(reader.launchPosters.first?.subtitle, "发布文案 19")
        store.discardProtectedContent()
        let cleared = PortfolioStore()
        await cleared.restoreCachedContent(allowVideo: true)
        XCTAssertEqual(cleared.contentOrigin, .bundled)
        XCTAssertNil(cleared.selectLaunchPosterForColdLaunch())
        // A newer publication after cleanup must not be deleted by an old task.
        store.applyPublishedManifest(makeManifest(aboutPortraitURL: nil, launchPosters: [poster]))
        let afterRepublish = PortfolioStore()
        await afterRepublish.restoreCachedContent(allowVideo: true)
        XCTAssertEqual(afterRepublish.launchPosters.first?.subtitle, "发布文案 19")
    }

    func testLaunchPosterPreviewUsesActualWindowAspectWithoutStretching() {
        for viewport in [CGSize(width: 440, height: 956), CGSize(width: 956, height: 440),
                         CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032)] {
            let available = CGSize(width: 370, height: 420)
            let layout = LaunchPosterPreviewLayout(viewport: viewport, available: available)
            XCTAssertGreaterThan(layout.scale, 0)
            XCTAssertLessThanOrEqual(layout.scale, 1)
            XCTAssertLessThanOrEqual(layout.size.width, available.width)
            XCTAssertLessThanOrEqual(layout.size.height, available.height)
            XCTAssertEqual(layout.size.width / layout.size.height, viewport.width / viewport.height, accuracy: 0.000001)
        }
        let empty = LaunchPosterPreviewLayout(viewport: .zero, available: CGSize(width: 370, height: 420))
        XCTAssertEqual(empty.size, .zero)
        XCTAssertEqual(empty.scale, 0)
        let invalid = LaunchPosterPreviewLayout(viewport: CGSize(width: CGFloat.infinity, height: 420), available: .zero)
        XCTAssertEqual(invalid.size, .zero)
    }

    func testFanIdentityCodesAreNormalizedWithoutAmbiguousCharacters() {
        XCTAssertEqual(
            FanAccountValidation.normalizedIdentityCode("hs-abcd-2345"),
            "HS-ABCD-2345"
        )
        XCTAssertEqual(
            FanAccountValidation.normalizedIdentityCode(" ABCD 2345 "),
            "HS-ABCD-2345"
        )
        XCTAssertNil(FanAccountValidation.normalizedIdentityCode("HS-ABCI-2345"))
        XCTAssertNil(FanAccountValidation.normalizedIdentityCode("HS-ABCD-1234"))
        XCTAssertNil(FanAccountValidation.normalizedIdentityCode("HS-ABCD-234"))
    }

    func testNewFanAcknowledgementsUseTheCurrentPrivacyPolicyVersion() {
        XCTAssertEqual(
            FanAccountConsentPolicy.currentVersion,
            "2026-09-04-approval-v4"
        )
    }

    func testFanRegistrationRequiresAndNormalizesASafeDouyinID() {
        XCTAssertEqual(FanAccountValidation.normalizedDouyinID(" @YiShu_2026 "), "yishu_2026")
        XCTAssertEqual(FanAccountValidation.normalizedDouyinID("一只梳子君"), "一只梳子君")
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("https://v.douyin.com/example"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("a b"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("@"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("   "))
        XCTAssertTrue(FanAccountValidation.isCompleteDouyinID("yishu_2026"))
        XCTAssertFalse(FanAccountValidation.isCompleteDouyinID(""))
        XCTAssertFalse(FanAccountValidation.isCompleteDouyinID(
            "invite_0123456789abcdef01234567"
        ))
    }

    func testFanPasswordPolicyRequiresLengthAndTwoCharacterCategories() {
        XCTAssertTrue(FanAccountValidation.isValidPassword("fansafety2026"))
        XCTAssertTrue(FanAccountValidation.isValidPassword("乖乖影像安全2026"))
        XCTAssertTrue(FanAccountValidation.isValidPassword("long-password"))
        XCTAssertFalse(FanAccountValidation.isValidPassword("onlyletters"))
        XCTAssertFalse(FanAccountValidation.isValidPassword("short1"))
        XCTAssertFalse(FanAccountValidation.isValidPassword(" fansafety2026"))
    }

    func testPasswordRecoveryProfileFailsClosedUntilPasswordRotation() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = FanProfile(
            userID: "00000000-0000-4000-8000-000000000001",
            identityCode: "HS-ABCD-2345",
            displayName: "恢复中粉丝",
            douyinID: "recovery_fan",
            installationCode: "IN-ABC-234",
            permissions: FanPermission.allCases.map(\.rawValue),
            status: FanAccountStatus.active.rawValue,
            sessionExpiresAt: now.addingTimeInterval(600),
            requiresPasswordChange: true,
            passwordRecoveryExpiresAt: now.addingTimeInterval(900)
        )

        XCTAssertTrue(profile.hasConsistentAccountSetupState)
        XCTAssertTrue(FanAccountValidation.isValidProfile(profile, now: now))
        XCTAssertFalse(profile.isApproved(at: now))
        XCTAssertFalse(profile.hasPermission(.galleryFull, at: now))

        let missingExpiry = FanProfile(
            userID: profile.userID,
            identityCode: profile.identityCode,
            displayName: profile.displayName,
            douyinID: profile.douyinID,
            installationCode: profile.installationCode,
            permissions: profile.permissions,
            status: profile.status,
            sessionExpiresAt: profile.sessionExpiresAt,
            requiresPasswordChange: true,
            passwordRecoveryExpiresAt: nil
        )
        XCTAssertFalse(missingExpiry.hasConsistentAccountSetupState)
        XCTAssertFalse(FanAccountValidation.isValidProfile(missingExpiry, now: now))
    }

    func testPasswordChangeValidationRequiresCurrentDifferentStrongPassword() throws {
        XCTAssertEqual(
            try FanAccountValidation.validatedPasswordChange(
                currentPassword: TestCredentialFixture.currentValue,
                newPassword: TestCredentialFixture.replacementValue,
                newPasswordConfirmation: TestCredentialFixture.replacementValue
            ),
            FanPasswordChangeInput(
                currentPassword: TestCredentialFixture.currentValue,
                newPassword: TestCredentialFixture.replacementValue
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedPasswordChange(
                currentPassword: TestCredentialFixture.unchangedValue,
                newPassword: TestCredentialFixture.unchangedValue,
                newPasswordConfirmation: TestCredentialFixture.unchangedValue
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedPasswordChange(
                currentPassword: TestCredentialFixture.currentValue,
                newPassword: TestCredentialFixture.weakValue,
                newPasswordConfirmation: TestCredentialFixture.weakValue
            )
        )
    }

    func testFanAccountOperationGuardRejectsStaleOrTokenChangedResponses() {
        XCTAssertTrue(
            FanAccountOperationGuard.canAccept(
                requestGeneration: 7,
                currentGeneration: 7,
                expectedToken: "token-a",
                currentToken: "token-a"
            )
        )
        XCTAssertTrue(
            FanAccountOperationGuard.canAccept(
                requestGeneration: 1,
                currentGeneration: 1,
                expectedToken: nil,
                currentToken: nil
            )
        )
        XCTAssertFalse(
            FanAccountOperationGuard.canAccept(
                requestGeneration: 7,
                currentGeneration: 8,
                expectedToken: "token-a",
                currentToken: "token-a"
            )
        )
        XCTAssertFalse(
            FanAccountOperationGuard.canAccept(
                requestGeneration: 7,
                currentGeneration: 7,
                expectedToken: "token-a",
                currentToken: "token-b"
            )
        )
    }

    func testAppleDouyinMigrationAcceptsEveryPreservedAccountStatus() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for status in FanAccountStatus.allCases {
            let profile = FanProfile(
                userID: UUID().uuidString.lowercased(),
                identityCode: "HS-ABCD-2345",
                displayName: "旧 Apple 粉丝",
                douyinID: "apple_migrated_fan",
                installationCode: "IN-ABC-234",
                permissions: FanPermission.allCases.map(\.rawValue),
                status: status.rawValue,
                sessionExpiresAt: now.addingTimeInterval(600),
                accountSource: FanAccountSource.apple.rawValue
            )

            XCTAssertTrue(
                FanAppleRegistrationCompletionPolicy.accepts(profile),
                "Apple 旧账号补全抖音 ID 时必须保留并接受 \(status.rawValue) 状态"
            )
            XCTAssertFalse(FanAppleRegistrationCompletionPolicy.notice(for: status).isEmpty)
        }

        let incomplete = FanProfile(
            userID: UUID().uuidString.lowercased(),
            identityCode: "HS-ABCD-2345",
            displayName: "未完成账号",
            douyinID: "invite_0123456789abcdef01234567",
            installationCode: "IN-ABC-234",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            sessionExpiresAt: now.addingTimeInterval(600),
            requiresAccountSetup: true,
            invitationExpiresAt: now.addingTimeInterval(600),
            accountSource: FanAccountSource.apple.rawValue
        )
        XCTAssertFalse(FanAppleRegistrationCompletionPolicy.accepts(incomplete))
    }

    func testUncertainDeletionResultsFailClosedButExplicitClientErrorsDoNot() {
        XCTAssertTrue(FanDeletionFailurePolicy.shouldFailClosed(after: .unavailable))
        XCTAssertTrue(FanDeletionFailurePolicy.shouldFailClosed(after: .invalidResponse))
        XCTAssertFalse(FanDeletionFailurePolicy.shouldFailClosed(after: .invalidCredentials))
        XCTAssertFalse(FanDeletionFailurePolicy.shouldFailClosed(after: .rateLimited))
        XCTAssertFalse(FanDeletionFailurePolicy.shouldFailClosed(after: .server("当前密码不正确。")))
    }

    func testAppleNonceHashAndConstantTimeStateValidation() {
        XCTAssertEqual(
            AppleSignInSecurity.sha256Hex("test-nonce"),
            "ed04c4e9ea6c49cf9ceb39098787c5b9842524f96b07ef45305476a11caec9b4"
        )
        XCTAssertTrue(AppleSignInSecurity.statesMatch("same-state", "same-state"))
        XCTAssertFalse(AppleSignInSecurity.statesMatch("same-state-x", "same-state"))
        XCTAssertFalse(AppleSignInSecurity.statesMatch(nil, "same-state"))
    }

    @MainActor
    func testAppleAuthorizationSurvivesInactiveButCancelsInBackground() throws {
        var controllers: [ASAuthorizationController] = []
        let coordinator = AppleSignInCoordinator { controllers.append($0) }
        let window = UIWindow()
        let challenge = FanAppleChallenge(
            challengeID: String(repeating: "a", count: 32),
            nonce: String(repeating: "b", count: 64),
            state: String(repeating: "c", count: 64),
            expiresAt: Date().addingTimeInterval(300)
        )
        var completions = 0
        coordinator.start(challenge: challenge, presentationAnchor: window) { _ in completions += 1 }
        XCTAssertTrue(coordinator.isWorking)
        coordinator.scenePhaseDidChange(to: .inactive)
        coordinator.scenePhaseDidChange(to: .active)
        XCTAssertTrue(coordinator.isWorking)
        XCTAssertEqual(completions, 0)
        coordinator.scenePhaseDidChange(to: .background)
        XCTAssertFalse(coordinator.isWorking)
        coordinator.completeAuthorization(controller: try XCTUnwrap(controllers.first), credential: nil)
        XCTAssertEqual(completions, 0, "A callback after background cancellation is no longer current")
    }

    @MainActor
    func testAppleSupersededSuccessCallbackCannotClearNewAuthorization() throws {
        var controllers: [ASAuthorizationController] = []
        let coordinator = AppleSignInCoordinator { controllers.append($0) }
        let window = UIWindow()
        let challenge = FanAppleChallenge(
            challengeID: String(repeating: "a", count: 32),
            nonce: String(repeating: "b", count: 64),
            state: String(repeating: "c", count: 64),
            expiresAt: Date().addingTimeInterval(300)
        )
        var oldCompletions = 0
        var newCompletions = 0
        coordinator.start(challenge: challenge, presentationAnchor: window) { _ in oldCompletions += 1 }
        let oldController = try XCTUnwrap(controllers.first)
        coordinator.start(challenge: challenge, presentationAnchor: window) { result in
            newCompletions += 1
            if case .success = result { XCTFail("An invalid current credential must still fail closed") }
        }
        coordinator.completeAuthorization(controller: oldController, credential: nil)
        XCTAssertTrue(coordinator.isWorking)
        XCTAssertEqual(oldCompletions, 0)
        XCTAssertEqual(newCompletions, 0)
        coordinator.completeAuthorization(controller: try XCTUnwrap(controllers.last), credential: nil)
        XCTAssertFalse(coordinator.isWorking)
        XCTAssertEqual(newCompletions, 1)
        coordinator.completeAuthorization(controller: try XCTUnwrap(controllers.last), credential: nil)
        XCTAssertEqual(newCompletions, 1, "Duplicate callbacks must not complete twice")
    }

    func testAppleChallengeRejectsExpiredAndOverlongTTL() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let valid = FanAppleChallenge(
            challengeID: String(repeating: "c", count: 24),
            nonce: String(repeating: "n", count: 43),
            state: String(repeating: "s", count: 43),
            expiresAt: now.addingTimeInterval(300)
        )
        XCTAssertTrue(valid.isValid(now: now))
        XCTAssertFalse(FanAppleChallenge(
            challengeID: valid.challengeID,
            nonce: valid.nonce,
            state: valid.state,
            expiresAt: now
        ).isValid(now: now))
        XCTAssertFalse(FanAppleChallenge(
            challengeID: valid.challengeID,
            nonce: valid.nonce,
            state: valid.state,
            expiresAt: now.addingTimeInterval(601)
        ).isValid(now: now))
    }

    func testAppleAuthRequestSendsOnlyServerChallengeProof() throws {
        let request = FanAppleAuthRequest(
            identityToken: "header.payload.signature",
            authorizationCode: "authorization-code",
            challengeID: String(repeating: "c", count: 24),
            state: String(repeating: "s", count: 43),
            installID: "00000000-0000-4000-8000-000000000001"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["identityToken", "authorizationCode", "challengeID", "state", "installID"]
        )
        XCTAssertNil(object["user"])
        XCTAssertNil(object["nonce"])
    }

    func testAppleRegistrationRequiresNameDouyinIDAndConsent() throws {
        XCTAssertEqual(
            try FanAccountValidation.validatedAppleRegistration(
                displayName: " 梳子粉丝 ",
                douyinID: " @fan_2026 ",
                acceptedDataUse: true
            ),
            FanAppleRegistrationInput(displayName: "梳子粉丝", douyinID: "fan_2026")
        )
        XCTAssertThrowsError(try FanAccountValidation.validatedAppleRegistration(
            displayName: "梳子粉丝",
            douyinID: "fan_2026",
            acceptedDataUse: false
        ))
        XCTAssertThrowsError(try FanAccountValidation.validatedAppleRegistration(
            displayName: "",
            douyinID: "fan_2026",
            acceptedDataUse: true
        ))
        XCTAssertThrowsError(
            try FanAccountValidation.validatedAppleRegistration(
                displayName: "梳子粉丝",
                douyinID: "  ",
                acceptedDataUse: true
            )
        )
        XCTAssertThrowsError(try FanAccountValidation.validatedAppleRegistration(
            displayName: "梳子粉丝",
            douyinID: "https://v.douyin.com/example",
            acceptedDataUse: true
        ))
    }

    func testAppleOnboardingResponseDistinguishesNewApplicationAndMigration() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = Data(#"{"expiresAt":"2026-09-04T12:20:00Z"}"#.utf8)
        let legacyState = try decoder.decode(FanAppleRegistrationState.self, from: legacy)
        XCTAssertFalse(legacyState.isDouyinMigration)
        XCTAssertEqual(legacyState.displayName, "")
        XCTAssertNil(legacyState.preservedStatus)

        let migration = Data(
            #"{"expiresAt":"2026-09-04T12:20:00Z","isDouyinMigration":true,"displayName":"旧 Apple 粉丝","preservedStatus":"suspended"}"#.utf8
        )
        let migrationState = try decoder.decode(FanAppleRegistrationState.self, from: migration)
        XCTAssertTrue(migrationState.isDouyinMigration)
        XCTAssertEqual(migrationState.displayName, "旧 Apple 粉丝")
        XCTAssertEqual(migrationState.preservedStatus, .suspended)
    }

    func testAppleCredentialRevocationPolicyFailsClosed() {
        XCTAssertEqual(FanAppleCredentialStatePolicy.decision(for: .authorized), .authorize)
        XCTAssertEqual(FanAppleCredentialStatePolicy.decision(for: .revoked), .revoke)
        XCTAssertEqual(FanAppleCredentialStatePolicy.decision(for: .notFound), .revoke)
        XCTAssertEqual(FanAppleCredentialStatePolicy.decision(for: .transferred), .transfer)
        XCTAssertEqual(
            FanAppleCredentialStatePolicy.queryDisposition(hasError: true),
            .retryKeepingSession
        )
        XCTAssertEqual(
            FanAppleCredentialStatePolicy.queryDisposition(hasError: false),
            .evaluateCredential
        )
        XCTAssertFalse(FanAppleCredentialAccessPolicy.canUseValidServerSession(
            usesAppleSignIn: true,
            state: .checking
        ))
        XCTAssertTrue(FanAppleCredentialAccessPolicy.canUseValidServerSession(
            usesAppleSignIn: true,
            state: .retryRequired
        ))
        XCTAssertTrue(FanAppleCredentialAccessPolicy.canUseValidServerSession(
            usesAppleSignIn: true,
            state: .verified
        ))
    }

    func testAppleRegistrationDraftClearsAcrossAccountTransition() {
        var draft = FanAppleRegistrationDraft(
            displayName: "上一位用户",
            douyinID: "previous_fan",
            acceptedDataUse: true
        )

        draft.clear()

        XCTAssertEqual(draft, FanAppleRegistrationDraft())
    }

    func testAppleOnlyAccountDoesNotOfferPasswordChange() {
        XCTAssertFalse(
            FanAccountSecurityCapabilities.supportsPasswordChange(usesAppleSignIn: true)
        )
        XCTAssertTrue(
            FanAccountSecurityCapabilities.supportsPasswordChange(usesAppleSignIn: false)
        )
    }

    func testAppleOnboardingSessionCanSelfDeleteBeforeApproval() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let onboarding = FanAppleRegistrationState(expiresAt: now.addingTimeInterval(600))

        XCTAssertTrue(FanAppleDeletionEligibility.canBegin(
            hasToken: true,
            usesAppleSignIn: true,
            hasProfile: false,
            registration: onboarding,
            now: now
        ))
        XCTAssertFalse(FanAppleDeletionEligibility.canBegin(
            hasToken: true,
            usesAppleSignIn: true,
            hasProfile: false,
            registration: onboarding,
            now: now.addingTimeInterval(601)
        ))
        XCTAssertFalse(FanAppleDeletionEligibility.canBegin(
            hasToken: false,
            usesAppleSignIn: true,
            hasProfile: false,
            registration: onboarding,
            now: now
        ))
    }

    func testFanSessionDirectoryRejectsForeignCurrentOrDuplicateSession() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let current = FanSessionRecord(
            sessionID: "0123456789abcdef0123456789abcdef",
            installationCode: "IN-ABC-234",
            createdAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            isCurrent: true
        )
        let other = FanSessionRecord(
            sessionID: "abcdef0123456789abcdef0123456789",
            installationCode: "IN-BCD-345",
            createdAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            isCurrent: false
        )
        XCTAssertTrue(
            FanAccountValidation.isValidSessionDirectory(
                [current, other],
                currentInstallationCode: "IN-ABC-234",
                now: now
            )
        )
        XCTAssertFalse(
            FanAccountValidation.isValidSessionDirectory(
                [current, current],
                currentInstallationCode: "IN-ABC-234",
                now: now
            )
        )
        XCTAssertFalse(
            FanAccountValidation.isValidSessionDirectory(
                [current, other],
                currentInstallationCode: "IN-XYZ-999",
                now: now
            )
        )
    }

    func testActiveInvitationAccountStillFailsClosed() {
        let profile = FanProfile(
            userID: UUID().uuidString.lowercased(),
            identityCode: "HS-ABCD-2345",
            displayName: "待完成设置",
            douyinID: "invite_0123456789abcdef01234567",
            installationCode: "IN-ABC-234",
            permissions: FanPermission.allCases.map(\.rawValue),
            status: FanAccountStatus.active.rawValue,
            sessionExpiresAt: Date().addingTimeInterval(600),
            requiresAccountSetup: true,
            invitationExpiresAt: Date().addingTimeInterval(3_600)
        )

        XCTAssertTrue(profile.hasConsistentAccountSetupState)
        XCTAssertFalse(profile.isApproved)
        XCTAssertFalse(profile.hasPermission(.galleryFull))
        XCTAssertFalse(profile.hasPermission(.videoView))
        XCTAssertFalse(profile.hasPermission(.earlyAccess))

        let contradictoryProfile = FanProfile(
            userID: profile.userID,
            identityCode: profile.identityCode,
            displayName: profile.displayName,
            douyinID: profile.douyinID,
            installationCode: profile.installationCode,
            permissions: profile.permissions,
            status: profile.status,
            sessionExpiresAt: profile.sessionExpiresAt,
            requiresAccountSetup: false,
            invitationExpiresAt: nil
        )
        XCTAssertFalse(contradictoryProfile.hasConsistentAccountSetupState)
        XCTAssertFalse(contradictoryProfile.isApproved)
    }

    func testSessionExpiryFailsClosedAfterTimeAdvanceEvenWhenRefreshIsUnavailable() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = FanProfile(
            userID: UUID().uuidString.lowercased(),
            identityCode: "HS-ABCD-2345",
            displayName: "已批准粉丝",
            douyinID: "approved_fan",
            installationCode: "IN-ABC-234",
            permissions: FanPermission.allCases.map(\.rawValue),
            status: FanAccountStatus.active.rawValue,
            sessionExpiresAt: now.addingTimeInterval(60)
        )

        XCTAssertTrue(profile.isApproved(at: now))
        XCTAssertTrue(profile.hasPermission(.galleryFull, at: now))

        // A failed refresh leaves the last decoded value in memory. Access is
        // still decided from the local expiry, not from the stale active flag.
        let retainedAfterNetworkFailure = profile
        let afterExpiry = now.addingTimeInterval(61)
        XCTAssertFalse(retainedAfterNetworkFailure.isApproved(at: afterExpiry))
        XCTAssertFalse(retainedAfterNetworkFailure.hasPermission(.galleryFull, at: afterExpiry))
        XCTAssertFalse(retainedAfterNetworkFailure.hasPermission(.videoView, at: afterExpiry))
    }

    func testAdminAccessPatchEncodesOnlyTheFieldBeingChanged() throws {
        let statusData = try JSONEncoder().encode(
            AdminFanAccessUpdate(permissions: nil, status: FanAccountStatus.suspended.rawValue)
        )
        let statusObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        )
        XCTAssertEqual(Set(statusObject.keys), ["status"])
        XCTAssertEqual(statusObject["status"] as? String, FanAccountStatus.suspended.rawValue)

        let permissionData = try JSONEncoder().encode(
            AdminFanAccessUpdate(permissions: [FanPermission.galleryFull.rawValue], status: nil)
        )
        let permissionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: permissionData) as? [String: Any]
        )
        XCTAssertEqual(Set(permissionObject.keys), ["permissions"])
        XCTAssertEqual(
            permissionObject["permissions"] as? [String],
            [FanPermission.galleryFull.rawValue]
        )
    }

    func testLegacyFanModelsDecodeAsConfiguredAccounts() throws {
        let profileJSON = Data(
            """
            {
              "userID":"00000000-0000-4000-8000-000000000001",
              "identityCode":"HS-ABCD-2345",
              "displayName":"旧版粉丝",
              "douyinID":"legacy_fan",
              "installationCode":"IN-ABC-234",
              "permissions":["gallery_full"],
              "status":"active",
              "sessionExpiresAt":"2099-01-01T00:00:00Z"
            }
            """.utf8
        )
        let adminJSON = Data(
            """
            {
              "userID":"00000000-0000-4000-8000-000000000001",
              "identityCode":"HS-ABCD-2345",
              "displayName":"旧版粉丝",
              "douyinID":"legacy_fan",
              "permissions":["gallery_full"],
              "status":"active",
              "registeredAt":"2026-08-31T00:00:00Z",
              "reviewedAt":null
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let profile = try decoder.decode(FanProfile.self, from: profileJSON)
        let admin = try decoder.decode(AdminFanUser.self, from: adminJSON)

        XCTAssertFalse(profile.requiresAccountSetup)
        XCTAssertNil(profile.invitationExpiresAt)
        XCTAssertFalse(profile.requiresPasswordChange)
        XCTAssertNil(profile.passwordRecoveryExpiresAt)
        XCTAssertEqual(profile.accountSource, FanAccountSource.password.rawValue)
        XCTAssertFalse(profile.requiresAppleRegistration)
        XCTAssertFalse(profile.administratorBound)
        XCTAssertTrue(profile.isApproved)
        XCTAssertFalse(admin.requiresAccountSetup)
        XCTAssertNil(admin.invitationExpiresAt)
        XCTAssertFalse(admin.requiresPasswordChange)
        XCTAssertNil(admin.passwordRecoveryExpiresAt)
        XCTAssertEqual(admin.accountSource, FanAccountSource.password.rawValue)
        XCTAssertFalse(admin.requiresAppleRegistration)
        XCTAssertTrue(FanAccountValidation.isValidAdminFanUser(admin))

        let invitedAdmin = AdminFanUser(
            userID: "00000000-0000-4000-8000-000000000002",
            identityCode: "HS-BCDE-3456",
            displayName: "待完成设置",
            douyinID: "invite_0123456789abcdef01234567",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            registeredAt: Date(),
            reviewedAt: nil,
            requiresAccountSetup: true,
            invitationExpiresAt: Date().addingTimeInterval(3_600)
        )
        XCTAssertTrue(FanAccountValidation.isValidAdminFanUser(invitedAdmin))

        let unmarkedPlaceholder = AdminFanUser(
            userID: invitedAdmin.userID,
            identityCode: invitedAdmin.identityCode,
            displayName: invitedAdmin.displayName,
            douyinID: invitedAdmin.douyinID,
            permissions: invitedAdmin.permissions,
            status: invitedAdmin.status,
            registeredAt: invitedAdmin.registeredAt,
            reviewedAt: nil
        )
        XCTAssertFalse(FanAccountValidation.isValidAdminFanUser(unmarkedPlaceholder))
    }

    func testAdminDirectoryMarksIncompleteAndLegacyBlankDouyinProfiles() throws {
        let data = Data(
            """
            {
              "userID":"00000000-0000-4000-8000-000000000003",
              "identityCode":"HS-CDEF-4567",
              "displayName":"Apple 新用户",
              "douyinID":"",
              "permissions":[],
              "status":"pending",
              "registeredAt":"2026-08-31T00:00:00Z",
              "reviewedAt":null,
              "accountSource":"apple",
              "requiresAppleRegistration":true
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let user = try decoder.decode(AdminFanUser.self, from: data)

        XCTAssertTrue(user.requiresIdentityCompletion)
        XCTAssertTrue(FanAccountValidation.isValidAdminFanUser(user))

        let completedWithoutDouyin = AdminFanUser(
            userID: user.userID,
            identityCode: user.identityCode,
            displayName: user.displayName,
            douyinID: "",
            permissions: [],
            status: user.status,
            registeredAt: user.registeredAt,
            reviewedAt: nil,
            accountSource: FanAccountSource.apple.rawValue,
            requiresAppleRegistration: false
        )
        XCTAssertTrue(completedWithoutDouyin.requiresIdentityCompletion)
        XCTAssertTrue(FanAccountValidation.isValidAdminFanUser(completedWithoutDouyin))

        let wrongSource = AdminFanUser(
            userID: user.userID,
            identityCode: user.identityCode,
            displayName: user.displayName,
            douyinID: "",
            permissions: [],
            status: user.status,
            registeredAt: user.registeredAt,
            reviewedAt: nil,
            accountSource: FanAccountSource.password.rawValue,
            requiresAppleRegistration: true
        )
        XCTAssertFalse(FanAccountValidation.isValidAdminFanUser(wrongSource))
    }

    func testLegacyApprovedProfileWithoutDouyinRemainsManageableButCannotAccessContent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let profile = FanProfile(
            userID: "00000000-0000-4000-8000-000000000005",
            identityCode: "HS-EFGH-6789",
            displayName: "未填抖音的粉丝",
            douyinID: "",
            installationCode: "IN-ABC-234",
            permissions: [FanPermission.galleryFull.rawValue],
            status: FanAccountStatus.active.rawValue,
            sessionExpiresAt: now.addingTimeInterval(3_600)
        )

        XCTAssertTrue(profile.hasConsistentAccountSetupState)
        XCTAssertTrue(FanAccountValidation.isValidProfile(profile, now: now))
        XCTAssertFalse(profile.hasRequiredDouyinID)
        XCTAssertFalse(profile.isApproved(at: now))
        XCTAssertFalse(profile.hasPermission(.galleryFull, at: now))
    }

    func testNormalProfileRejectsIncompleteAppleRegistrationMarker() {
        let profile = FanProfile(
            userID: "00000000-0000-4000-8000-000000000004",
            identityCode: "HS-DEFG-5678",
            displayName: "Apple 粉丝",
            douyinID: "apple_fan",
            installationCode: "IN-ABC-234",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            sessionExpiresAt: Date().addingTimeInterval(3_600),
            accountSource: FanAccountSource.apple.rawValue,
            requiresAppleRegistration: true
        )

        XCTAssertFalse(FanAccountValidation.isValidProfile(profile))
    }

    func testInvitationResponseValidationRejectsMalformedOrReplayedBatchShapes() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = Data(
            """
            {
              "invitations":[{
                "userID":"00000000-0000-4000-8000-000000000001",
                "identityCode":"HS-ABCD-2345",
                "temporaryPassword":"\(TestCredentialFixture.temporaryValue)",
                "expiresAt":"2099-01-01T00:00:00Z",
                "requiresAccountSetup":true
              }]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(AdminFanInvitationResponse.self, from: data)
        let invitation = try XCTUnwrap(response.invitations.first)

        XCTAssertTrue(
            AdminFanInvitationValidation.isValid(
                response,
                requestedCount: 1,
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanInvitationValidation.isValid(
                response,
                requestedCount: 2,
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanInvitationValidation.isValid(
                AdminFanInvitationResponse(
                    invitations: [invitation, invitation]
                ),
                requestedCount: 2,
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanInvitationValidation.isValid(
                AdminFanInvitationResponse(
                    invitations: [
                        AdminFanInvitation(
                            userID: invitation.userID,
                            identityCode: invitation.identityCode,
                            temporaryPassword: invitation.temporaryPassword,
                            expiresAt: now,
                            requiresAccountSetup: true
                        ),
                    ]
                ),
                requestedCount: 1,
                now: now
            )
        )
    }

    func testAdminPasswordRecoveryCredentialIsShortLivedAndOneTimeShaped() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recovery = AdminFanPasswordRecovery(
            userID: "00000000-0000-4000-8000-000000000001",
            identityCode: "HS-ABCD-2345",
            temporaryPassword: TestCredentialFixture.temporaryValue,
            expiresAt: now.addingTimeInterval(900),
            requiresPasswordChange: true
        )
        XCTAssertTrue(
            AdminFanPasswordRecoveryValidation.isValid(
                recovery,
                expectedUserID: recovery.userID,
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanPasswordRecoveryValidation.isValid(
                recovery,
                expectedUserID: "00000000-0000-4000-8000-000000000002",
                now: now
            )
        )
        XCTAssertFalse(
            AdminFanPasswordRecoveryValidation.isValid(
                AdminFanPasswordRecovery(
                    userID: recovery.userID,
                    identityCode: recovery.identityCode,
                    temporaryPassword: recovery.temporaryPassword,
                    expiresAt: now.addingTimeInterval(3_600),
                    requiresPasswordChange: true
                ),
                expectedUserID: recovery.userID,
                now: now
            )
        )
    }

    func testRequiredSetupValidationRequiresDouyinAndPasswordRotation() throws {
        let temporaryPassword = TestCredentialFixture.temporaryValue
        let valid = try FanAccountValidation.validatedRequiredSetup(
            displayName: "  测试粉丝  ",
            douyinID: " @Real_Fan ",
            currentPassword: temporaryPassword,
            newPassword: TestCredentialFixture.replacementValue,
            newPasswordConfirmation: TestCredentialFixture.replacementValue,
            acceptedDataUse: true
        )
        XCTAssertEqual(valid.displayName, "测试粉丝")
        XCTAssertEqual(valid.douyinID, "real_fan")

        XCTAssertThrowsError(try FanAccountValidation.validatedRequiredSetup(
            displayName: "测试粉丝",
            douyinID: "   ",
            currentPassword: temporaryPassword,
            newPassword: TestCredentialFixture.replacementValue,
            newPasswordConfirmation: TestCredentialFixture.replacementValue,
            acceptedDataUse: true
        ))

        XCTAssertThrowsError(
            try FanAccountValidation.validatedRequiredSetup(
                displayName: "测试粉丝",
                douyinID: "invite_0123456789abcdef01234567",
                currentPassword: temporaryPassword,
                newPassword: TestCredentialFixture.replacementValue,
                newPasswordConfirmation: TestCredentialFixture.replacementValue,
                acceptedDataUse: true
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedRequiredSetup(
                displayName: "测试粉丝",
                douyinID: "real_fan",
                currentPassword: temporaryPassword,
                newPassword: temporaryPassword,
                newPasswordConfirmation: temporaryPassword,
                acceptedDataUse: true
            )
        )
        XCTAssertThrowsError(
            try FanAccountValidation.validatedRequiredSetup(
                displayName: "测试粉丝",
                douyinID: "real_fan",
                currentPassword: temporaryPassword,
                newPassword: TestCredentialFixture.replacementValue,
                newPasswordConfirmation: TestCredentialFixture.replacementValue,
                acceptedDataUse: false
            )
        )
    }

    func testFanPermissionsAreExplicitAndUnknownValuesStayInactive() {
        let profile = FanProfile(
            userID: UUID().uuidString.lowercased(),
            identityCode: "HS-ABCD-2345",
            displayName: "测试粉丝",
            douyinID: "test_fan",
            installationCode: "IN-ABC-234",
            permissions: [FanPermission.galleryFull.rawValue, "future_permission"],
            status: "active",
            sessionExpiresAt: Date().addingTimeInterval(3_600)
        )

        XCTAssertTrue(profile.hasPermission(.galleryFull))
        XCTAssertFalse(profile.hasPermission(.videoView))
        XCTAssertFalse(profile.hasPermission(.earlyAccess))

        let suspendedProfile = FanProfile(
            userID: profile.userID,
            identityCode: profile.identityCode,
            displayName: profile.displayName,
            douyinID: profile.douyinID,
            installationCode: profile.installationCode,
            permissions: FanPermission.allCases.map(\.rawValue),
            status: "suspended",
            sessionExpiresAt: profile.sessionExpiresAt
        )
        XCTAssertFalse(suspendedProfile.hasPermission(.galleryFull))
        XCTAssertFalse(suspendedProfile.hasPermission(.videoView))
        XCTAssertFalse(suspendedProfile.hasPermission(.earlyAccess))

        let pendingProfile = FanProfile(
            userID: profile.userID,
            identityCode: profile.identityCode,
            displayName: profile.displayName,
            douyinID: profile.douyinID,
            installationCode: profile.installationCode,
            permissions: FanPermission.allCases.map(\.rawValue),
            status: FanAccountStatus.pending.rawValue,
            sessionExpiresAt: profile.sessionExpiresAt
        )
        XCTAssertFalse(pendingProfile.isApproved)
        XCTAssertFalse(pendingProfile.hasPermission(.galleryFull))
        XCTAssertTrue(profile.isApproved)
    }

    func testOnlyJSONResponseTypesAreAccepted() {
        XCTAssertTrue(AppNetworkSecurityPolicy.isJSONMIMEType("application/json; charset=UTF-8"))
        XCTAssertTrue(AppNetworkSecurityPolicy.isJSONMIMEType("application/problem+json"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isJSONMIMEType("text/html"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isJSONMIMEType(nil))
    }

    func testImageResponsesRequireSafeMIMEAndBoundedLength() {
        XCTAssertTrue(AppNetworkSecurityPolicy.isImageMIMEType("image/jpeg; charset=binary"))
        XCTAssertTrue(AppNetworkSecurityPolicy.isImageMIMEType("IMAGE/WEBP"))
        XCTAssertTrue(AppNetworkSecurityPolicy.isImageMIMEType("image/heic"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isImageMIMEType("image/svg+xml"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isImageMIMEType("text/html"))
        XCTAssertFalse(AppNetworkSecurityPolicy.isImageMIMEType(nil))

        let limit: Int64 = 20 * 1024 * 1024
        XCTAssertTrue(AppNetworkSecurityPolicy.permitsResponseLength(limit, maximumBytes: limit))
        XCTAssertTrue(
            AppNetworkSecurityPolicy.permitsResponseLength(
                NSURLSessionTransferSizeUnknown,
                maximumBytes: limit
            )
        )
        XCTAssertFalse(AppNetworkSecurityPolicy.permitsResponseLength(0, maximumBytes: limit))
        XCTAssertFalse(AppNetworkSecurityPolicy.permitsResponseLength(limit + 1, maximumBytes: limit))
    }

    func testMediaResponseCannotChangeURLOrAddFragment() {
        let requested = URL(string: "https://img.shuzijun.com.cn/images/portrait.webp?v=2")!

        XCTAssertTrue(
            ContentSecurityPolicy.matchesRequestedMediaURL(requested, requestedURL: requested)
        )
        XCTAssertFalse(
            ContentSecurityPolicy.matchesRequestedMediaURL(
                URL(string: "https://www.shuzijun.com.cn/images/portrait.webp?v=2"),
                requestedURL: requested
            )
        )
        XCTAssertFalse(
            ContentSecurityPolicy.matchesRequestedMediaURL(
                URL(string: "https://img.shuzijun.com.cn/images/portrait.webp?v=3"),
                requestedURL: requested
            )
        )
        XCTAssertFalse(
            ContentSecurityPolicy.isTrustedMediaURL(
                URL(string: "https://img.shuzijun.com.cn/images/portrait.webp#hidden")!
            )
        )
    }

    func testDiagnosticsReduceErrorsToNonSensitiveNumericCategories() {
        let sensitiveURL = URL(string: "https://user:password@example.com/private.jpg")!
        let networkError = URLError(
            .timedOut,
            userInfo: [NSURLErrorFailingURLErrorKey: sensitiveURL]
        )
        let applicationError = NSError(
            domain: "private.account.name",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "secret content"]
        )

        XCTAssertEqual(
            DiagnosticsSanitizer.networkErrorCode(networkError),
            URLError.Code.timedOut.rawValue
        )
        XCTAssertEqual(DiagnosticsSanitizer.networkErrorCode(applicationError), 0)
    }

    func testArtworkImageRetryPolicyOnlyRetriesTransientFailures() {
        XCTAssertTrue(ArtworkImageRetryPolicy.shouldRetry(URLError(.timedOut)))
        XCTAssertTrue(ArtworkImageRetryPolicy.shouldRetry(URLError(.secureConnectionFailed)))
        XCTAssertTrue(ArtworkImageRetryPolicy.shouldRetry(ArtworkImageLoadError.httpStatus(503)))
        XCTAssertFalse(ArtworkImageRetryPolicy.shouldRetry(ArtworkImageLoadError.httpStatus(404)))
        XCTAssertFalse(ArtworkImageRetryPolicy.shouldRetry(ArtworkImageLoadError.invalidResponse))
        XCTAssertFalse(ArtworkImageRetryPolicy.shouldRetry(ArtworkImageLoadError.decodeFailed))
    }

    func testAPNsDeviceTokenEncodingIsCanonicalAndStrict() {
        let bytes = Data((0..<32).map(UInt8.init))
        let encoded = PushDeviceTokenPolicy.encodedToken(from: bytes)

        XCTAssertEqual(encoded, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        XCTAssertTrue(PushDeviceTokenPolicy.isValid(encoded ?? ""))
        XCTAssertNotNil(PushDeviceTokenPolicy.encodedToken(from: Data(repeating: 1, count: 1)))
        XCTAssertNotNil(PushDeviceTokenPolicy.encodedToken(from: Data(repeating: 1, count: 256)))
        XCTAssertNil(PushDeviceTokenPolicy.encodedToken(from: Data()))
        XCTAssertNil(PushDeviceTokenPolicy.encodedToken(from: Data(repeating: 1, count: 257)))
        XCTAssertFalse(PushDeviceTokenPolicy.isValid(String(repeating: "A", count: 64)))
        XCTAssertFalse(PushDeviceTokenPolicy.isValid(String(repeating: "a", count: 33)))
    }

    func testPushRegistrationRequiresCompletedDouyinProfileAndLiveSession() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let pendingProfile = FanProfile(
            userID: "11111111-2222-4333-8444-555555555555",
            identityCode: "HS-ABCD-2345",
            displayName: "测试用户",
            douyinID: "douyin-user",
            installationCode: "HSI-1234-5678-ABCD",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            sessionExpiresAt: now.addingTimeInterval(600)
        )

        XCTAssertEqual(
            PushSessionEligibility.userID(
                profile: pendingProfile,
                hasSessionToken: true,
                now: now
            ),
            pendingProfile.userID
        )
        XCTAssertNil(
            PushSessionEligibility.userID(
                profile: pendingProfile,
                hasSessionToken: false,
                now: now
            )
        )
        XCTAssertNil(
            PushSessionEligibility.userID(
                profile: pendingProfile,
                hasSessionToken: true,
                credentialAccessAllowed: false,
                now: now
            ),
            "Apple 凭据尚未验证时不得继续绑定推送"
        )

        let incompleteProfile = FanProfile(
            userID: pendingProfile.userID,
            identityCode: pendingProfile.identityCode,
            displayName: pendingProfile.displayName,
            douyinID: "invite_0123456789abcdef01234567",
            installationCode: pendingProfile.installationCode,
            permissions: [],
            status: pendingProfile.status,
            sessionExpiresAt: pendingProfile.sessionExpiresAt,
            requiresAccountSetup: true,
            invitationExpiresAt: now.addingTimeInterval(300),
            accountSource: FanAccountSource.invitation.rawValue
        )
        XCTAssertNil(
            PushSessionEligibility.userID(
                profile: incompleteProfile,
                hasSessionToken: true,
                now: now
            )
        )

        for status in [FanAccountStatus.rejected, .suspended] {
            let blockedProfile = FanProfile(
                userID: pendingProfile.userID,
                identityCode: pendingProfile.identityCode,
                displayName: pendingProfile.displayName,
                douyinID: pendingProfile.douyinID,
                installationCode: pendingProfile.installationCode,
                permissions: [],
                status: status.rawValue,
                sessionExpiresAt: pendingProfile.sessionExpiresAt
            )
            XCTAssertNil(
                PushSessionEligibility.userID(
                    profile: blockedProfile,
                    hasSessionToken: true,
                    now: now
                )
            )
        }
    }

    func testPushSynchronizationRebindsAfterSameUserSessionRotation() {
        let before = PushSynchronizationTaskID(
            userID: "11111111-2222-4333-8444-555555555555",
            fanSessionGeneration: 7,
            deviceRegistrationGeneration: 3
        )
        let afterPasswordChange = PushSynchronizationTaskID(
            userID: before.userID,
            fanSessionGeneration: 8,
            deviceRegistrationGeneration: 3
        )

        XCTAssertNotEqual(before, afterPasswordChange)
        XCTAssertEqual(before, before)

        let appleCredentialChecking = PushSynchronizationTaskID(
            userID: nil,
            fanSessionGeneration: 8,
            deviceRegistrationGeneration: 3,
            canUnbindPushDevice: true,
            appleCredentialAccessState: .checking
        )
        let appleCredentialVerified = PushSynchronizationTaskID(
            userID: before.userID,
            fanSessionGeneration: 8,
            deviceRegistrationGeneration: 3,
            canUnbindPushDevice: true,
            appleCredentialAccessState: .verified
        )
        XCTAssertNotEqual(appleCredentialChecking, appleCredentialVerified)
    }

    func testPushBindingGenerationIsStrictlyMonotonicAndBounded() {
        XCTAssertEqual(PushBindingGenerationPolicy.next(after: 0), 1)
        XCTAssertEqual(
            PushBindingGenerationPolicy.next(after: PushBindingGenerationPolicy.maximum - 1),
            PushBindingGenerationPolicy.maximum
        )
        XCTAssertNil(
            PushBindingGenerationPolicy.next(after: PushBindingGenerationPolicy.maximum)
        )

        let state = FanInstallationState(
            installID: UUID(),
            bindingGeneration: PushBindingGenerationPolicy.maximum
        )
        let encoded = try? JSONEncoder().encode(state)
        let decoded = encoded.flatMap {
            try? JSONDecoder().decode(FanInstallationState.self, from: $0)
        }
        XCTAssertEqual(decoded, state)
    }

    func testPushBindingRefreshesAtFixedTwentyFourHourAge() {
        let boundAt = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertFalse(
            PushBindingRefreshPolicy.needsRefresh(
                boundAt: boundAt,
                now: boundAt.addingTimeInterval(24 * 60 * 60 - 1)
            )
        )
        XCTAssertTrue(
            PushBindingRefreshPolicy.needsRefresh(
                boundAt: boundAt,
                now: boundAt.addingTimeInterval(24 * 60 * 60)
            )
        )
        XCTAssertEqual(
            PushBindingRefreshPolicy.delayUntilRefresh(
                boundAt: boundAt,
                now: boundAt.addingTimeInterval(23 * 60 * 60)
            ),
            60 * 60
        )
    }

    func testPushAccountTransitionsResetDeviceRegistration() {
        let first = "11111111-2222-4333-8444-555555555555"
        let second = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

        XCTAssertTrue(
            PushAccountTransitionPolicy.requiresRegistrationReset(
                previousUserID: first,
                currentUserID: nil
            )
        )
        XCTAssertTrue(
            PushAccountTransitionPolicy.requiresRegistrationReset(
                previousUserID: first,
                currentUserID: second
            )
        )
        XCTAssertFalse(
            PushAccountTransitionPolicy.requiresRegistrationReset(
                previousUserID: first,
                currentUserID: first
            )
        )
    }

    func testPushPreferencesAreAccountScopedAndInactiveBeforeSystemConsent() {
        let suiteName = "PushNotificationPreferenceTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建隔离的 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferenceKey = "push-opt-in"
        let associationKey = "push-opt-in-user"
        let firstUserID = "11111111-2222-4333-8444-555555555555"
        let secondUserID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

        XCTAssertFalse(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: firstUserID
            ),
            "首次安装不能在用户操作前隐式开启通知"
        )
        PushNotificationPreferencePolicy.setEnabled(
            true,
            for: firstUserID,
            in: defaults,
            preferenceKey: preferenceKey,
            associationKey: associationKey
        )
        XCTAssertTrue(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: firstUserID
            )
        )
        XCTAssertFalse(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: secondUserID
            ),
            "B 账号不能继承 A 账号主动开启的通知偏好"
        )
        XCTAssertFalse(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: nil
            ),
            "退出登录后必须立即关闭本地通知绑定状态"
        )
        PushNotificationPreferencePolicy.setEnabled(
            true,
            for: secondUserID,
            in: defaults,
            preferenceKey: preferenceKey,
            associationKey: associationKey
        )
        XCTAssertTrue(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: firstUserID
            ),
            "保留 A 的独立偏好，但实际绑定仍只属于当前登录账号"
        )
        XCTAssertTrue(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: secondUserID
            )
        )
        PushNotificationPreferencePolicy.setEnabled(
            false,
            for: secondUserID,
            in: defaults,
            preferenceKey: preferenceKey,
            associationKey: associationKey
        )
        XCTAssertFalse(
            PushNotificationPreferencePolicy.isEnabled(
                in: defaults,
                preferenceKey: preferenceKey,
                associationKey: associationKey,
                userID: secondUserID
            )
        )
    }

    @MainActor
    func testStartupPushPermissionRequestsOnceAndKeepsDeliveryOffBeforeLogin() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.granted])
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )

        await coordinator.requestStartupAuthorizationIfNeeded()
        await coordinator.requestStartupAuthorizationIfNeeded()

        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(coordinator.authorizationStatus, .authorized)
        XCTAssertFalse(coordinator.notificationsEnabled, "系统授权不能在未登录时开启账号推送")
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))
        let generationBeforeToken = coordinator.registrationGeneration
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        XCTAssertEqual(coordinator.registrationGeneration, generationBeforeToken,
                       "未登录时必须忽略设备令牌，不能触发绑定")
    }

    @MainActor
    func testStartupPushPermissionDoesNotRepeatAfterDenialOrEnableAnAccount() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.denied])
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )

        await coordinator.requestStartupAuthorizationIfNeeded()
        await coordinator.requestStartupAuthorizationIfNeeded()
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )

        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(coordinator.authorizationStatus, .denied)
        XCTAssertFalse(coordinator.notificationsEnabled)
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))
    }

    @MainActor
    func testExistingSystemPushPermissionDoesNotRegisterBeforeEligibleLogin() async throws {
        for status in [UNAuthorizationStatus.authorized, .provisional, .ephemeral] {
            let defaults = try makePushStartupDefaults()
            let client = TestPushAuthorizationClient(status: status)
            let coordinator = PushNotificationCoordinator(
                authorizationClient: client, defaults: defaults,
                registrationClient: TestPushDeviceRegistrationClient()
            )

            await coordinator.requestStartupAuthorizationIfNeeded()
            PushStartupConsentPolicy.consume(
                for: "new-account", in: defaults,
                preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
            )

            XCTAssertEqual(client.requestCount, 0)
            XCTAssertEqual(coordinator.authorizationStatus, status)
            XCTAssertFalse(coordinator.notificationsEnabled)
            XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"),
                         "没有合格登录会话时不能启用或绑定任何账号")
        }
    }

    @MainActor
    func testSystemAuthorizedPushAutomaticallyBindsWithoutAnAppToggleOrStartupMarker() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let registrar = TestPushDeviceRegistrationClient()
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults,
            registrationClient: registrar)
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        await coordinator.requestStartupAuthorizationIfNeeded()
        await coordinator.synchronize(with: account)
        XCTAssertEqual(client.requestCount, 0, "已在系统允许，不需要第二次确认")
        XCTAssertTrue(coordinator.notificationsEnabled)
        XCTAssertFalse(coordinator.shouldPresentAuthorizationRationale)
        XCTAssertEqual(registrar.registrationCount, 1)
        XCTAssertTrue(account.bindingAttempts.isEmpty)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts.count, 1)
        XCTAssertEqual(account.bindingAttempts.first?.userID, "first-account")
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
    }

    @MainActor
    func testPushAutoEnableRequiresFullSystemAuthorization() async throws {
        for status in [UNAuthorizationStatus.notDetermined, .denied, .provisional, .ephemeral] {
            let defaults = try makePushStartupDefaults()
            let client = TestPushAuthorizationClient(status: status)
            let registrar = TestPushDeviceRegistrationClient()
            let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults,
                registrationClient: registrar)
            defer { coordinator.accountContextDidChange(to: nil) }
            let account = TestPushNotificationAccount(userID: "first-account")
            await coordinator.synchronize(with: account)
            coordinator.receive(deviceToken: Data([0x12, 0x34]))
            await coordinator.synchronize(with: account)
            XCTAssertFalse(coordinator.notificationsEnabled, "不能把 \(status.rawValue) 当成点过允许")
            XCTAssertEqual(registrar.registrationCount, 0)
            XCTAssertTrue(account.bindingAttempts.isEmpty)
            XCTAssertEqual(client.requestCount, 0)
        }
    }

    @MainActor
    func testSystemSettingsAllowAfterDenialConnectsAutomaticallyAndRevocationStopsDelivery() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .denied)
        let registrar = TestPushDeviceRegistrationClient()
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults,
            registrationClient: registrar)
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        await coordinator.synchronize(with: account)
        XCTAssertFalse(coordinator.notificationsEnabled)
        client.status = .authorized
        await coordinator.synchronize(with: account)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        client.status = .denied
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .inactive)
        let registrations = registrar.registrationCount
        coordinator.receive(deviceToken: Data([0x56, 0x78]))
        await coordinator.synchronize(with: account)
        XCTAssertEqual(registrar.registrationCount, registrations)
        XCTAssertEqual(account.bindingAttempts.count, 1)
        client.status = .authorized
        await coordinator.synchronize(with: account)
        coordinator.receive(deviceToken: Data([0x56, 0x78]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertEqual(account.bindingAttempts.count, 2)
        XCTAssertEqual(client.requestCount, 0)
    }

    @MainActor
    func testPushOptOutSurvivesAutomaticAccountSwitchAndCoordinatorRelaunch() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient())
        let account = TestPushNotificationAccount(userID: "first-account")
        await coordinator.setNotificationsEnabled(false, for: account)
        account.pushEligibleUserID = "second-account"
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.notificationsEnabled)
        coordinator.retire()
        let restored = PushNotificationCoordinator(authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient())
        defer { restored.accountContextDidChange(to: nil) }
        account.pushEligibleUserID = "first-account"
        account.pushSessionGeneration += 1
        await restored.synchronize(with: account)
        XCTAssertFalse(restored.notificationsEnabled, "A 的主动关闭不能被 B 自动开启覆盖")
        XCTAssertTrue(restored.deviceRegistrationState == .inactive)
        XCTAssertTrue(account.bindingAttempts.isEmpty)
    }

    func testAutomaticPushPreferencesMigrateLegacyAccountOptOutAndPreserveUnscopedOptOut() throws {
        for associated in [true, false] {
            let defaults = try makePushStartupDefaults()
            let key = "push-notifications-enabled"
            let userKey = "push-notifications-enabled-user"
            defaults.set(false, forKey: key)
            if associated {
                defaults.set(PushNotificationPreferencePolicy.association(for: "first-account"),
                             forKey: userKey)
            }
            PushNotificationPreferencePolicy.setEnabled(true, for: "second-account", in: defaults,
                preferenceKey: key, associationKey: userKey)
            PushNotificationPreferencePolicy.enableAfterSystemAuthorization(.authorized,
                for: "first-account", in: defaults, preferenceKey: key, associationKey: userKey)
            XCTAssertFalse(PushNotificationPreferencePolicy.isEnabled(in: defaults,
                preferenceKey: key, associationKey: userKey, userID: "first-account"))
            XCTAssertTrue(PushNotificationPreferencePolicy.hasExplicitChoice(in: defaults,
                preferenceKey: key, associationKey: userKey, userID: "first-account"))
            XCTAssertTrue(PushNotificationPreferencePolicy.isEnabled(in: defaults,
                preferenceKey: key, associationKey: userKey, userID: "second-account"))
        }
    }

    @MainActor
    func testDeletingOldPushPreferencePreservesCurrentAccountBindingAndOtherWorkspace() async throws {
        let defaults = try makePushStartupDefaults()
        let coordinator = PushNotificationCoordinator(
            authorizationClient: TestPushAuthorizationClient(status: .authorized), defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient())
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        await coordinator.setNotificationsEnabled(false, for: account)
        PushNotificationPreferencePolicy.setEnabled(false, for: "first-account", in: defaults,
            preferenceKey: "review.push-notifications-enabled", associationKey: "review.push-notifications-enabled-user")
        account.pushEligibleUserID = "second-account"
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        coordinator.removePreferenceForDeletedAccount("first-account")
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertTrue(coordinator.notificationsEnabled)
        XCTAssertEqual(account.bindingAttempts.count, 1)
        XCTAssertFalse(PushNotificationPreferencePolicy.hasExplicitChoice(in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user",
            userID: "first-account"))
        XCTAssertTrue(PushNotificationPreferencePolicy.hasExplicitChoice(in: defaults,
            preferenceKey: "review.push-notifications-enabled", associationKey: "review.push-notifications-enabled-user",
            userID: "first-account"))
        let choices = try XCTUnwrap(defaults.dictionary(forKey: "push-notifications-enabled-account-choices"))
        XCTAssertEqual(choices.count, 1)
        XCTAssertTrue(choices.keys.allSatisfy { $0.count == 64 })
        coordinator.removePreferenceForDeletedAccount("second-account")
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled-account-choices"))
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled-user"))
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))
        XCTAssertFalse(coordinator.notificationsEnabled)
    }

    @MainActor
    func testStartupPushConsentSurvivesRelaunchAndIsConsumedByOnlyOneAccount() async throws {
        let defaults = try makePushStartupDefaults()
        let firstClient = TestPushAuthorizationClient(outcomes: [.granted])
        let firstCoordinator = PushNotificationCoordinator(
            authorizationClient: firstClient, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )
        await firstCoordinator.requestStartupAuthorizationIfNeeded()

        let relaunchClient = TestPushAuthorizationClient(status: .authorized)
        let relaunchedCoordinator = PushNotificationCoordinator(
            authorizationClient: relaunchClient, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )
        await relaunchedCoordinator.requestStartupAuthorizationIfNeeded()
        XCTAssertEqual(relaunchClient.requestCount, 0)
        XCTAssertFalse(relaunchedCoordinator.notificationsEnabled)

        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertTrue(PushNotificationPreferencePolicy.isEnabled(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "first-account"
        ))
        PushStartupConsentPolicy.consume(
            for: "second-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertFalse(PushNotificationPreferencePolicy.isEnabled(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "second-account"
        ), "B 账号不能继承 A 账号已经使用的启动授权")
        XCTAssertTrue(PushNotificationPreferencePolicy.isEnabled(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "first-account"
        ))
    }

    @MainActor
    func testStartupPushPermissionPreservesBuild45LegacyOptOut() async throws {
        let defaults = try makePushStartupDefaults()
        defaults.set(false, forKey: "push-notifications-enabled")
        let client = TestPushAuthorizationClient()
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )

        await coordinator.requestStartupAuthorizationIfNeeded()
        XCTAssertEqual(client.requestCount, 0)
        XCTAssertTrue(PushNotificationPreferencePolicy.hasExplicitChoice(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "legacy-account"
        ))
        PushStartupConsentPolicy.recordGranted(in: defaults)
        PushStartupConsentPolicy.consume(
            for: "legacy-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertFalse(defaults.bool(forKey: "push-notifications-enabled"))
        XCTAssertNil(defaults.string(forKey: "push-notifications-enabled-user"))
    }

    func testStartupPushConsentRespectsAccountOptOutAndCannotLeakToNextAccount() throws {
        let defaults = try makePushStartupDefaults()
        PushNotificationPreferencePolicy.setEnabled(
            false, for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        PushStartupConsentPolicy.recordGranted(in: defaults)
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        PushStartupConsentPolicy.consume(
            for: "second-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )

        for userID in ["first-account", "second-account"] {
            XCTAssertFalse(PushNotificationPreferencePolicy.isEnabled(
                in: defaults, preferenceKey: "push-notifications-enabled",
                associationKey: "push-notifications-enabled-user", userID: userID
            ))
        }
        XCTAssertTrue(PushNotificationPreferencePolicy.hasExplicitChoice(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "first-account"
        ))
        XCTAssertFalse(PushNotificationPreferencePolicy.hasExplicitChoice(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "second-account"
        ))
    }

    func testClearingStartupPushConsentPreventsLaterImplicitOptIn() throws {
        let defaults = try makePushStartupDefaults()
        PushStartupConsentPolicy.recordGranted(in: defaults)
        PushStartupConsentPolicy.clear(in: defaults)
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))
    }

    @MainActor
    func testInterruptedStartupPushPermissionCanRetryWithoutPrematureOptIn() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.interrupted, .granted])
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )

        await coordinator.requestStartupAuthorizationIfNeeded()
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertEqual(coordinator.authorizationStatus, .notDetermined)
        XCTAssertNil(defaults.object(forKey: "push-notifications-enabled"))

        await coordinator.requestStartupAuthorizationIfNeeded()
        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(coordinator.authorizationStatus, .authorized)
        XCTAssertFalse(coordinator.notificationsEnabled)
        PushStartupConsentPolicy.consume(
            for: "first-account", in: defaults,
            preferenceKey: "push-notifications-enabled", associationKey: "push-notifications-enabled-user"
        )
        XCTAssertTrue(PushNotificationPreferencePolicy.isEnabled(
            in: defaults, preferenceKey: "push-notifications-enabled",
            associationKey: "push-notifications-enabled-user", userID: "first-account"
        ))
    }

    @MainActor
    func testConcurrentStartupPushPermissionAttemptsShareOneSystemRequest() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.granted])
        let requestStarted = expectation(description: "第一条系统授权请求已经挂起")
        client.pauseRequest = true
        client.requestStarted = { requestStarted.fulfill() }
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )
        let firstRequest = Task { await coordinator.requestStartupAuthorizationIfNeeded() }

        await fulfillment(of: [requestStarted], timeout: 2)
        guard client.requestCount == 1 else {
            firstRequest.cancel()
            client.resumeRequest()
            return XCTFail("第一条授权请求应进入受控等待")
        }
        await coordinator.requestStartupAuthorizationIfNeeded()
        XCTAssertEqual(client.requestCount, 1, "多次前台生命周期事件只能产生一个系统授权弹窗")
        XCTAssertFalse(coordinator.notificationsEnabled)
        client.resumeRequest()
        await firstRequest.value

        XCTAssertEqual(coordinator.authorizationStatus, .authorized)
        XCTAssertEqual(client.requestCount, 1)
    }

    @MainActor
    func testPushCoordinatorBindsStartupConsentOnlyAfterEligibleLoginAndDeviceToken() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.granted])
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )
        let account = TestPushNotificationAccount()
        defer { coordinator.accountContextDidChange(to: nil) }

        await coordinator.requestStartupAuthorizationIfNeeded()
        await coordinator.synchronize(with: account)
        XCTAssertFalse(coordinator.notificationsEnabled)
        XCTAssertTrue(account.bindingAttempts.isEmpty, "未登录不得向服务器绑定设备")

        account.pushEligibleUserID = "first-account"
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.notificationsEnabled)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        XCTAssertTrue(account.bindingAttempts.isEmpty, "系统授权不等于已获得 APNs 设备令牌")

        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts, [
            TestPushNotificationAccount.BindingAttempt(
                userID: "first-account", generation: 2, deviceToken: "1234"
            ),
        ])
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)

        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts.count, 1, "正常的前台同步不能重复提交有效绑定")
        account.pushEligibleUserID = "second-account"
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.notificationsEnabled, "B 根据当前系统授权独立启用")
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        XCTAssertEqual(account.bindingAttempts.count, 1, "不能把旧账号绑定直接标成新账号已连接")
        coordinator.receive(deviceToken: Data([0x56, 0x78]))
        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts.count, 2)
        XCTAssertEqual(account.bindingAttempts.last?.userID, "second-account")
        XCTAssertEqual(account.bindingAttempts.last?.generation, 3)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
    }

    @MainActor
    func testDelayedIneligiblePushUnbindCannotEraseNewAccountReadyState() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)

        let unbindStarted = expectation(description: "旧的不合格会话解除绑定正在等待网络响应")
        account.pushEligibleUserID = nil
        account.pushSessionGeneration += 1
        account.pauseNextUnbind = true
        account.unbindStarted = { unbindStarted.fulfill() }
        let oldSynchronization = Task { await coordinator.synchronize(with: account) }
        await fulfillment(of: [unbindStarted], timeout: 2)
        defer {
            oldSynchronization.cancel()
            account.resumeUnbind()
        }
        XCTAssertTrue(coordinator.deviceRegistrationState == .inactive)

        account.pushEligibleUserID = "second-account"
        account.pushSessionGeneration += 1
        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.receive(deviceToken: Data([0x56, 0x78]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertEqual(account.bindingAttempts.last?.userID, "second-account")

        account.resumeUnbind()
        await oldSynchronization.value
        XCTAssertTrue(coordinator.notificationsEnabled, "旧解除绑定响应不能关闭新账号通知")
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready,
                      "旧解除绑定响应不能清除新账号已经完成的设备连接")
        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts.count, 2,
                       "旧响应不能清掉新绑定缓存并造成重复绑定")
    }

    @MainActor
    func testPushCoordinatorCanRetryBothAPNsRegistrationAndServerBindingFailures() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }

        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.registrationFailed()
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed)
        XCTAssertTrue(account.bindingAttempts.isEmpty)

        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        account.bindingFailuresRemaining = 1
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed,
                      "服务器绑定失败不能显示设备已经连接")
        XCTAssertEqual(account.bindingAttempts.count, 1)

        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertEqual(account.bindingAttempts.count, 2)
        XCTAssertEqual(account.bindingAttempts[0], account.bindingAttempts[1],
                       "手动重试应使用同一账号与设备令牌")
    }

    @MainActor
    func testExpiredPushBindingSessionRequiresSignInWithoutLoggingOutOrShowingNetworkFailure() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults, registrationTimeout: .milliseconds(20),
            registrationClient: TestPushDeviceRegistrationClient()
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        account.bindingRequiresSignIn = true
        defer { coordinator.accountContextDidChange(to: nil) }

        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .requiresSignIn,
                      "旧登录会话缺少推送绑定资料时必须提示重新登录")
        XCTAssertTrue(coordinator.notificationsEnabled, "需要重新登录不等于用户关闭了通知")
        XCTAssertTrue(account.hasPushEligibleSession, "推送绑定失败不得强制退出仍可浏览的账号")
        XCTAssertEqual(account.bindingAttempts.count, 1)
        XCTAssertEqual(account.unbindCount, 0)

        let noNetworkFailure = expectation(description: "重新登录提示不能被旧连接超时覆盖")
        noNetworkFailure.isInverted = true
        let observation = coordinator.$deviceRegistrationState
            .filter { $0 == .failed }
            .sink { _ in noNetworkFailure.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [noNetworkFailure], timeout: 0.08)
        XCTAssertTrue(coordinator.deviceRegistrationState == .requiresSignIn)

        account.bindingRequiresSignIn = false
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready,
                      "用户重新登录取得完整会话后应可以完成通知绑定")
        XCTAssertEqual(account.bindingAttempts.count, 2)
        XCTAssertEqual(account.bindingAttempts.last?.generation, 2)
    }

    @MainActor
    func testPushRegistrationWithoutCallbackTimesOutAndCanBeRetried() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults, registrationTimeout: .milliseconds(20),
            registrationClient: TestPushDeviceRegistrationClient()
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        let timedOut = expectation(description: "没有 APNs 回调时连接状态应结束等待")
        let observation = coordinator.$deviceRegistrationState
            .filter { $0 == .failed }
            .prefix(1)
            .sink { _ in timedOut.fulfill() }
        defer { observation.cancel() }

        await coordinator.setNotificationsEnabled(true, for: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        await fulfillment(of: [timedOut], timeout: 2)
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed)
        XCTAssertTrue(account.bindingAttempts.isEmpty)

        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting,
                      "超时后手动重试必须重新进入连接状态")
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertEqual(account.bindingAttempts.count, 1)
    }

    @MainActor
    func testPushRegistrationTimeoutSurvivesSameAccountSessionRotation() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(status: .authorized)
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults, registrationTimeout: .milliseconds(100),
            registrationClient: TestPushDeviceRegistrationClient()
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        let timedOut = expectation(description: "同账号会话更新后仍应有有效的连接超时检测")
        let observation = coordinator.$deviceRegistrationState
            .filter { $0 == .failed }
            .prefix(1)
            .sink { _ in timedOut.fulfill() }
        defer { observation.cancel() }

        await coordinator.setNotificationsEnabled(true, for: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        await fulfillment(of: [timedOut], timeout: 2)
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed,
                      "旧会话的超时任务不得阻止新会话离开无限等待状态")

        await coordinator.synchronize(with: account)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.deviceRegistrationState == .ready)
        XCTAssertEqual(account.bindingAttempts.last?.generation, 2)
    }

    func testPushRecoveryBackoffIsFiniteAndCapped() {
        XCTAssertEqual(PushRecoveryPolicy.delays, [.seconds(5), .seconds(15), .seconds(60), .seconds(300), .seconds(300)])
        XCTAssertNil(PushRecoveryPolicy.delay(attempt: -1))
        XCTAssertNil(PushRecoveryPolicy.delay(attempt: PushRecoveryPolicy.delays.count))
        XCTAssertNil(PushRecoveryPolicy.delay(attempt: Int.max))
    }

    @MainActor
    private func waitForPushSleep(_ duration: Duration, in sleeper: TestPushNotificationSleeper) async {
        guard !sleeper.isWaiting(for: duration) else { return }
        let scheduled = expectation(description: "推送调度等待 \(duration)")
        sleeper.onSleep = { if $0 == duration { scheduled.fulfill() } }
        defer { sleeper.onSleep = nil }
        await fulfillment(of: [scheduled], timeout: 2)
    }

    @MainActor
    func testAPNsRegistrationAutomaticallyRetriesWithBoundedBackoffAndNoNewPermissionPrompt() async throws {
        let defaults = try makePushStartupDefaults()
        let authorization = TestPushAuthorizationClient(status: .authorized)
        let registrar = TestPushDeviceRegistrationClient()
        let sleeper = TestPushNotificationSleeper()
        let coordinator = PushNotificationCoordinator(
            authorizationClient: authorization, defaults: defaults,
            registrationClient: registrar, sleeper: sleeper
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer {
            coordinator.accountContextDidChange(to: nil)
            sleeper.cancelAll()
        }
        await coordinator.setNotificationsEnabled(true, for: account)
        XCTAssertEqual(registrar.registrationCount, 1)
        for (index, delay) in PushRecoveryPolicy.delays.enumerated() {
            coordinator.registrationFailed()
            coordinator.registrationFailed()
            await waitForPushSleep(delay, in: sleeper)
            let retried = expectation(description: "自动 APNs 注册重试 \(index)")
            registrar.onRegister = { retried.fulfill() }
            sleeper.advance(delay)
            await fulfillment(of: [retried], timeout: 2)
            registrar.onRegister = nil
            XCTAssertEqual(registrar.registrationCount, index + 2, "重复失败回调不得建立平行重试链")
        }
        coordinator.registrationFailed()
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed)
        XCTAssertFalse(PushRecoveryPolicy.delays.contains { sleeper.isWaiting(for: $0) }, "达到预算后必须停止自动轮询")
        XCTAssertEqual(authorization.requestCount, 0, "重连不得重复请求系统通知授权")
        XCTAssertTrue(account.bindingAttempts.isEmpty)

        await coordinator.synchronize(with: account)
        coordinator.registrationFailed()
        await waitForPushSleep(.seconds(5), in: sleeper)
        XCTAssertEqual(registrar.registrationCount, 7, "稍后进入前台或手动重试应获得一轮新的恢复机会")
    }

    @MainActor
    func testPushRegistrationTimeoutAutomaticallyRetriesWithoutForegroundOrManualAction() async throws {
        let defaults = try makePushStartupDefaults()
        let authorization = TestPushAuthorizationClient(status: .authorized)
        let registrar = TestPushDeviceRegistrationClient()
        let sleeper = TestPushNotificationSleeper()
        let coordinator = PushNotificationCoordinator(
            authorizationClient: authorization, defaults: defaults,
            registrationClient: registrar, sleeper: sleeper
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer {
            coordinator.accountContextDidChange(to: nil)
            sleeper.cancelAll()
        }
        await coordinator.setNotificationsEnabled(true, for: account)
        await waitForPushSleep(.seconds(30), in: sleeper)
        sleeper.advance(.seconds(30))
        await waitForPushSleep(.seconds(5), in: sleeper)
        XCTAssertTrue(coordinator.deviceRegistrationState == .failed)
        let retried = expectation(description: "无 APNs 回调超时后自动重试")
        registrar.onRegister = { retried.fulfill() }
        sleeper.advance(.seconds(5))
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(registrar.registrationCount, 2)
        XCTAssertTrue(coordinator.deviceRegistrationState == .connecting)
        XCTAssertEqual(authorization.requestCount, 0)
    }

    @MainActor
    func testPushServerBindingAutomaticallyRecoversAndStopsRetryingAfterSuccess() async throws {
        let defaults = try makePushStartupDefaults()
        let authorization = TestPushAuthorizationClient(status: .authorized)
        let registrar = TestPushDeviceRegistrationClient()
        let sleeper = TestPushNotificationSleeper()
        let coordinator = PushNotificationCoordinator(
            authorizationClient: authorization, defaults: defaults,
            registrationClient: registrar, sleeper: sleeper
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        account.bindingFailuresRemaining = 1
        defer {
            coordinator.accountContextDidChange(to: nil)
            sleeper.cancelAll()
        }
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.notificationsEnabled, "系统已允许时无需手动开关即可开始连接")
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts.count, 1)
        await waitForPushSleep(.seconds(5), in: sleeper)
        let ready = expectation(description: "网络恢复后自动完成账号绑定")
        let observation = coordinator.$deviceRegistrationState
            .filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        defer { observation.cancel() }
        sleeper.advance(.seconds(5))
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(account.bindingAttempts.count, 2)
        XCTAssertEqual(account.bindingAttempts[0], account.bindingAttempts[1])
        XCTAssertFalse(PushRecoveryPolicy.delays.contains { sleeper.isWaiting(for: $0) })
        XCTAssertEqual(authorization.requestCount, 0)
    }

    @MainActor
    func testPushRecoveryCannotRevivePreviousAccountAfterSignOutDisableOrSwitch() async throws {
        for transition in ["signed-out", "disabled", "switched"] {
            let defaults = try makePushStartupDefaults()
            let registrar = TestPushDeviceRegistrationClient()
            let sleeper = TestPushNotificationSleeper()
            let coordinator = PushNotificationCoordinator(
                authorizationClient: TestPushAuthorizationClient(status: .authorized), defaults: defaults,
                registrationClient: registrar, sleeper: sleeper
            )
            let account = TestPushNotificationAccount(userID: "first-account")
            defer {
                coordinator.accountContextDidChange(to: nil)
                sleeper.cancelAll()
            }
            await coordinator.setNotificationsEnabled(true, for: account)
            coordinator.registrationFailed()
            await waitForPushSleep(.seconds(5), in: sleeper)
            if transition == "disabled" {
                await coordinator.setNotificationsEnabled(false, for: account)
            } else {
                account.pushEligibleUserID = transition == "switched" ? "second-account" : nil
                account.pushSessionGeneration += 1
                await coordinator.synchronize(with: account)
            }
            let oldRetry = expectation(description: "旧重试不能恢复 \(transition) 账号")
            oldRetry.isInverted = true
            registrar.onRegister = { oldRetry.fulfill() }
            sleeper.advance(.seconds(5))
            coordinator.receive(deviceToken: Data([0x12, 0x34]))
            coordinator.registrationFailed()
            await fulfillment(of: [oldRetry], timeout: 0.05)
            if transition == "switched" {
                XCTAssertTrue(coordinator.notificationsEnabled, "新账号独立按系统授权启用")
                XCTAssertTrue(coordinator.deviceRegistrationState == .failed)
            } else {
                XCTAssertFalse(coordinator.notificationsEnabled)
                XCTAssertTrue(coordinator.deviceRegistrationState == .inactive)
            }
            XCTAssertTrue(account.bindingAttempts.isEmpty)
        }
    }

    @MainActor
    func testPushRecoveryDiscardsOldSessionRetryAndRetainsNewSessionSingleFlight() async throws {
        let defaults = try makePushStartupDefaults()
        let registrar = TestPushDeviceRegistrationClient()
        let sleeper = TestPushNotificationSleeper()
        let coordinator = PushNotificationCoordinator(
            authorizationClient: TestPushAuthorizationClient(status: .authorized), defaults: defaults,
            registrationClient: registrar, sleeper: sleeper
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer {
            account.resumeBinding()
            coordinator.accountContextDidChange(to: nil)
            sleeper.cancelAll()
        }
        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.registrationFailed()
        await waitForPushSleep(.seconds(5), in: sleeper)
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        account.bindingFailuresRemaining = 1
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        await waitForPushSleep(.seconds(5), in: sleeper)
        let binding = expectation(description: "新会话自动重试开始绑定")
        account.pauseNextBinding = true
        account.bindingStarted = { binding.fulfill() }
        sleeper.advance(.seconds(5))
        await fulfillment(of: [binding], timeout: 2)
        account.bindingStarted = nil
        guard account.bindingAttempts.count == 2 else { return }
        await coordinator.synchronize(with: account)
        await coordinator.synchronize(with: account)
        XCTAssertEqual(account.bindingAttempts.count, 2, "旧重试与并发前台同步不能并行调用绑定")
        let ready = expectation(description: "新会话唯一绑定请求完成")
        let observation = coordinator.$deviceRegistrationState
            .filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        defer { observation.cancel() }
        account.resumeBinding()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(account.bindingAttempts.last?.generation, 2)
        XCTAssertEqual(account.bindingAttempts.count, 2)
    }

    @MainActor
    func testPushRecoveryDoesNotRetryWhenFreshSignInIsRequired() async throws {
        let defaults = try makePushStartupDefaults()
        let sleeper = TestPushNotificationSleeper()
        let coordinator = PushNotificationCoordinator(
            authorizationClient: TestPushAuthorizationClient(status: .authorized), defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient(), sleeper: sleeper
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        account.bindingRequiresSignIn = true
        defer {
            coordinator.accountContextDidChange(to: nil)
            sleeper.cancelAll()
        }
        await coordinator.setNotificationsEnabled(true, for: account)
        coordinator.receive(deviceToken: Data([0x12, 0x34]))
        await coordinator.synchronize(with: account)
        coordinator.registrationFailed()
        XCTAssertTrue(coordinator.deviceRegistrationState == .requiresSignIn)
        XCTAssertFalse(PushRecoveryPolicy.delays.contains { sleeper.isWaiting(for: $0) })
        XCTAssertEqual(account.bindingAttempts.count, 1)
        XCTAssertTrue(account.hasPushEligibleSession, "推送错误不能影响现有浏览会话")
    }

    @MainActor
    func testExplicitPushOptOutDuringStartupRequestCannotBeOverwrittenByItsReply() async throws {
        let defaults = try makePushStartupDefaults()
        let client = TestPushAuthorizationClient(outcomes: [.granted])
        let coordinator = PushNotificationCoordinator(
            authorizationClient: client, defaults: defaults,
            registrationClient: TestPushDeviceRegistrationClient()
        )
        let account = TestPushNotificationAccount(userID: "first-account")
        defer { coordinator.accountContextDidChange(to: nil) }
        let requestStarted = expectation(description: "系统授权等待期间可以记录账号关闭偏好")
        client.pauseRequest = true
        client.requestStarted = { requestStarted.fulfill() }
        let startupRequest = Task { await coordinator.requestStartupAuthorizationIfNeeded() }
        await fulfillment(of: [requestStarted], timeout: 2)
        defer {
            startupRequest.cancel()
            client.resumeRequest()
        }

        await coordinator.setNotificationsEnabled(false, for: account)
        client.resumeRequest()
        await startupRequest.value
        await coordinator.synchronize(with: account)
        XCTAssertFalse(coordinator.notificationsEnabled)
        XCTAssertTrue(account.bindingAttempts.isEmpty)

        account.pushEligibleUserID = "second-account"
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertTrue(coordinator.notificationsEnabled, "B 根据当前系统授权启用，不继承 A 的关闭选择")
        XCTAssertTrue(account.bindingAttempts.isEmpty)
        account.pushEligibleUserID = "first-account"
        account.pushSessionGeneration += 1
        await coordinator.synchronize(with: account)
        XCTAssertFalse(coordinator.notificationsEnabled, "迟到的系统授权仍不能撤销 A 的主动关闭")
    }

    func testAdminFanDirectoryQueryNormalizesRemoteSearchAndBoundsPagination() throws {
        let query = try AdminFanDirectoryQuery(
            search: "  易姝 HS-ABCD-1234  ",
            page: 101,
            perPage: 50
        )

        XCTAssertEqual(query.search, "易姝 HS-ABCD-1234")
        XCTAssertEqual(query.page, 101)
        XCTAssertEqual(query.perPage, 50)
        XCTAssertTrue(AdminQueryItemPolicy.areValid(query.queryItems))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: query.queryItems.compactMap { item in
                item.value.map { (item.name, $0) }
            })["search"],
            "易姝 HS-ABCD-1234"
        )

        XCTAssertNil(try AdminFanDirectoryQuery(search: "   ").search)
        XCTAssertThrowsError(
            try AdminFanDirectoryQuery(
                search: String(repeating: "字", count: 81)
            )
        )
        XCTAssertThrowsError(try AdminFanDirectoryQuery(search: "用户\n身份码"))
        XCTAssertThrowsError(try AdminFanDirectoryQuery(page: 10_001))
        XCTAssertThrowsError(try AdminFanDirectoryQuery(perPage: 101))
        XCTAssertFalse(
            AdminQueryItemPolicy.areValid([
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "page", value: "2"),
            ])
        )
    }

    func testAdminFanDirectoryPaginationAppendsWithoutDuplicateUsers() {
        let firstUser = AdminFanUser(
            userID: "11111111-2222-4333-8444-555555555555",
            identityCode: "HS-ABCD-2345",
            displayName: "第一页用户",
            douyinID: "douyin-first",
            permissions: [],
            status: FanAccountStatus.active.rawValue,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000),
            reviewedAt: nil
        )
        let secondUser = AdminFanUser(
            userID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            identityCode: "HS-BCDE-3456",
            displayName: "第 101 名用户",
            douyinID: "douyin-101",
            permissions: [],
            status: FanAccountStatus.pending.rawValue,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_100),
            reviewedAt: nil
        )
        let catalog = [
            AdminFanPermissionDefinition(
                code: "gallery_full",
                title: "全部相册",
                description: "允许查看全部作品"
            ),
        ]
        let firstPage = AdminFanDirectory(
            users: [firstUser],
            permissionCatalog: catalog,
            page: 1,
            perPage: 100,
            hasMore: true
        )
        let secondPage = AdminFanDirectory(
            users: [firstUser, secondUser],
            permissionCatalog: catalog,
            page: 2,
            perPage: 100,
            hasMore: false
        )

        XCTAssertTrue(
            AdminFanDirectoryValidation.isValid(
                secondPage,
                requestedPage: 2,
                requestedPerPage: 100
            )
        )
        let merged = AdminFanDirectoryValidation.appending(secondPage, to: firstPage)
        XCTAssertEqual(merged?.users.map(\.userID), [firstUser.userID, secondUser.userID])
        XCTAssertEqual(merged?.page, 2)
        XCTAssertEqual(merged?.hasMore, false)

        let stalePage = AdminFanDirectory(
            users: [secondUser],
            permissionCatalog: catalog,
            page: 3,
            perPage: 100,
            hasMore: false
        )
        XCTAssertNil(AdminFanDirectoryValidation.appending(stalePage, to: firstPage))
    }

    func testAdminFanDirectoryDecodesLegacyResponseAsSinglePage() throws {
        let directory = try JSONDecoder().decode(
            AdminFanDirectory.self,
            from: Data(#"{"users":[],"permissionCatalog":[]}"#.utf8)
        )

        XCTAssertEqual(directory.page, 1)
        XCTAssertEqual(directory.perPage, 100)
        XCTAssertFalse(directory.hasMore)
    }

    func testAdminPushContentIsBoundedNormalizedAndPrivateByDefault() {
        let content = AdminPushNotificationValidation.normalized(
            title: "受保护的消息标题",
            body: "仅收件人在登录后的消息箱查看的内容",
            sensitive: true
        )

        XCTAssertEqual(content?.title, "受保护的消息标题")
        XCTAssertEqual(content?.body, "仅收件人在登录后的消息箱查看的内容")
        XCTAssertEqual(content?.sensitive, true)
        XCTAssertNotNil(
            AdminPushNotificationValidation.normalized(
                title: String(repeating: "标", count: 60),
                body: String(repeating: "文", count: 240),
                sensitive: false
            )
        )
        XCTAssertNil(
            AdminPushNotificationValidation.normalized(
                title: String(repeating: "标", count: 61),
                body: "正文",
                sensitive: false
            )
        )
        XCTAssertNil(
            AdminPushNotificationValidation.normalized(
                title: "标题",
                body: "不可见\u{0000}内容",
                sensitive: false
            )
        )
    }

    func testCustomTargetedPushRequiresExplicitSecondConfirmation() throws {
        let privateContent = try XCTUnwrap(
            AdminPushNotificationValidation.normalized(
                title: "不会发送",
                body: "不会发送",
                sensitive: true
            )
        )
        let customContent = try XCTUnwrap(
            AdminPushNotificationValidation.normalized(
                title: "作品更新",
                body: "今晚八点发布新作品。",
                sensitive: false
            )
        )

        XCTAssertFalse(
            AdminPushConfirmationPolicy.requiresSecondConfirmation(for: privateContent)
        )
        XCTAssertTrue(
            AdminPushConfirmationPolicy.requiresSecondConfirmation(for: customContent)
        )
        XCTAssertEqual(
            AdminPushConfirmationPolicy.summary(
                recipient: "测试用户",
                content: customContent
            ),
            "收件人：测试用户\n标题：作品更新\n正文：今晚八点发布新作品。"
        )
    }

    func testTargetedPushRecipientMustRemainPendingOrActive() {
        XCTAssertTrue(
            AdminTargetedPushRecipientPolicy.isEligible(
                status: FanAccountStatus.pending.rawValue,
                requiresIdentityCompletion: false
            )
        )
        XCTAssertTrue(
            AdminTargetedPushRecipientPolicy.isEligible(
                status: FanAccountStatus.active.rawValue,
                requiresIdentityCompletion: false
            )
        )
        for status in [FanAccountStatus.rejected, .suspended] {
            XCTAssertFalse(
                AdminTargetedPushRecipientPolicy.isEligible(
                    status: status.rawValue,
                    requiresIdentityCompletion: false
                )
            )
        }
        XCTAssertFalse(
            AdminTargetedPushRecipientPolicy.isEligible(
                status: FanAccountStatus.pending.rawValue,
                requiresIdentityCompletion: true
            )
        )
        XCTAssertFalse(
            AdminTargetedPushRecipientPolicy.isEligible(
                status: "unknown",
                requiresIdentityCompletion: false
            )
        )
    }

    func testAdminPushResponseMustMatchQueuedSingleRecipientContract() {
        let response = AdminPushNotificationResponse(
            notificationID: "11111111-2222-4333-8444-555555555555",
            status: "queued",
            recipientCount: 1,
            deviceCount: 16
        )
        XCTAssertTrue(
            AdminPushNotificationValidation.isValidResponse(
                response,
                expectedRecipientCount: 1
            )
        )
        XCTAssertFalse(
            AdminPushNotificationValidation.isValidResponse(
                AdminPushNotificationResponse(
                    notificationID: response.notificationID,
                    status: "sent",
                    recipientCount: 1,
                    deviceCount: 1
                ),
                expectedRecipientCount: 1
            )
        )
        XCTAssertFalse(
            AdminPushNotificationValidation.isValidResponse(
                AdminPushNotificationResponse(
                    notificationID: response.notificationID.uppercased(),
                    status: "queued",
                    recipientCount: 1,
                    deviceCount: 1_601
                ),
                expectedRecipientCount: 1
            )
        )
    }

    func testPushCapabilityDenialDoesNotLockAdministratorSession() {
        XCTAssertFalse(
            AdminAuthorizationFailurePolicy.shouldLock(
                statusCode: 403,
                serverErrorCode: "push_capability_required"
            )
        )
        XCTAssertTrue(
            AdminAuthorizationFailurePolicy.shouldLock(
                statusCode: 403,
                serverErrorCode: "rest_forbidden"
            )
        )
        XCTAssertTrue(
            AdminAuthorizationFailurePolicy.shouldLock(
                statusCode: 401,
                serverErrorCode: nil
            )
        )
    }

    func testPurgedImageReloadsWhenTheAppBecomesActive() {
        let url = URL(string: "https://img.shuzijun.com.cn/images/test.jpg")

        XCTAssertTrue(
            ArtworkImageLifecyclePolicy.shouldReloadWhenActive(url: url, hasImage: false),
            "后台安全清理取消下载后，回到前台必须重新请求空白图片"
        )
        XCTAssertFalse(
            ArtworkImageLifecyclePolicy.shouldReloadWhenActive(url: url, hasImage: true)
        )
        XCTAssertFalse(
            ArtworkImageLifecyclePolicy.shouldReloadWhenActive(url: nil, hasImage: false)
        )
    }

    func testArtworkImageDiagnosticsUseStableNonSensitiveCategories() {
        XCTAssertEqual(
            ArtworkImageRetryPolicy.diagnosticCode(for: URLError(.timedOut)),
            10_000 + abs(URLError.Code.timedOut.rawValue)
        )
        XCTAssertEqual(
            ArtworkImageRetryPolicy.diagnosticCode(for: ArtworkImageLoadError.httpStatus(503)),
            20_503
        )
        XCTAssertEqual(
            ArtworkImageRetryPolicy.diagnosticCode(for: ArtworkImageLoadError.decodeFailed),
            30_002
        )
    }

    func testUploadFilenameMustMatchItsMIMEType() throws {
        XCTAssertTrue(AdminUploadPolicy.isAllowed(filename: "portrait.JPG", mimeType: "image/jpeg"))
        XCTAssertTrue(AdminUploadPolicy.isAllowed(filename: "showreel.mov", mimeType: "video/quicktime"))
        XCTAssertFalse(AdminUploadPolicy.isAllowed(filename: "portrait.php", mimeType: "image/jpeg"))
        XCTAssertFalse(AdminUploadPolicy.isAllowed(filename: "portrait.jpg", mimeType: "video/mp4"))

        let sanitized = try AdminUploadPolicy.sanitizedFilename(
            "../portrait\r\nInjected.php.jpg",
            mimeType: "image/jpeg"
        )
        XCTAssertEqual(sanitized, "portrait__Injected_php.jpg")
        XCTAssertFalse(sanitized.contains("\r"))
        XCTAssertFalse(sanitized.contains("\n"))
    }

    func testCollaborationSubmissionNormalizesFieldsAndUsesStableIdempotencyID() throws {
        let submissionID = UUID(uuidString: "7d8cb55b-7358-4d25-8e4c-af657a122d44")!
        let date = Date(timeIntervalSince1970: 1_788_192_000)
        let draft = try CollaborationSubmissionDraft(
            submissionID: submissionID,
            contactName: "  林女士  ",
            contactMethod: "  13800000000  ",
            organization: "  梧桐影业  ",
            projectType: "drama",
            city: "  杭州  ",
            preferredDate: date,
            budget: "  5 万元  ",
            details: "  短剧女主角\r\n拍摄 7 天  "
        )

        XCTAssertEqual(draft.submissionID, submissionID.uuidString.lowercased())
        XCTAssertEqual(draft.contactName, "林女士")
        XCTAssertEqual(draft.contactMethod, "13800000000")
        XCTAssertEqual(draft.organization, "梧桐影业")
        XCTAssertEqual(draft.city, "杭州")
        XCTAssertEqual(draft.budget, "5 万元")
        XCTAssertEqual(draft.details, "短剧女主角\n拍摄 7 天")

        let payload = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(draft)
        ) as? [String: Any]
        XCTAssertEqual(payload?["submissionID"] as? String, draft.submissionID)
        XCTAssertEqual(payload?["projectType"] as? String, "drama")
        XCTAssertNotNil(payload?["preferredDate"] as? String)
    }

    func testCollaborationSubmissionRejectsMissingOrMultilineRequiredFields() {
        let submissionID = UUID(uuidString: "e4af5d2e-b6b2-42fa-a2ee-3b8777379d27")!
        XCTAssertThrowsError(
            try CollaborationSubmissionDraft(
                submissionID: submissionID,
                contactName: "   ",
                contactMethod: "13800000000",
                organization: "",
                projectType: "drama",
                city: "",
                preferredDate: .now,
                budget: "",
                details: ""
            )
        )
        XCTAssertThrowsError(
            try CollaborationSubmissionDraft(
                submissionID: submissionID,
                contactName: "林女士\n伪造字段",
                contactMethod: "13800000000",
                organization: "",
                projectType: "drama",
                city: "",
                preferredDate: .now,
                budget: "",
                details: ""
            )
        )
    }

    func testCollaborationReceiptRequiresCanonicalV4Identifier() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let valid = Data(
            #"{"requestID":"7d8cb55b-7358-4d25-8e4c-af657a122d44","status":"received","receivedAt":"2026-09-04T12:00:00Z","duplicate":false}"#.utf8
        )
        let receipt = try decoder.decode(CollaborationSubmissionReceipt.self, from: valid)
        XCTAssertEqual(receipt.status, .received)
        XCTAssertFalse(receipt.duplicate)

        let invalidVersion = Data(
            #"{"requestID":"7d8cb55b-7358-1d25-8e4c-af657a122d44","status":"received","receivedAt":"2026-09-04T12:00:00Z","duplicate":false}"#.utf8
        )
        XCTAssertThrowsError(
            try decoder.decode(CollaborationSubmissionReceipt.self, from: invalidVersion)
        )
    }

    func testCollaborationRetryAcceptsReceiptAfterAdminAdvancedStatus() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let advanced = Data(
            #"{"requestID":"7d8cb55b-7358-4d25-8e4c-af657a122d44","status":"reviewing","receivedAt":"2026-09-04T12:00:00Z","duplicate":true}"#.utf8
        )
        let receipt = try decoder.decode(CollaborationSubmissionReceipt.self, from: advanced)
        XCTAssertTrue(receipt.duplicate)
        XCTAssertEqual(receipt.status, .reviewing)
        XCTAssertTrue(
            CollaborationReceiptValidation.isAccepted(
                receipt,
                now: Date(timeIntervalSince1970: 1_788_544_100)
            )
        )
    }

    func testCollaborationCapabilitiesRequireExactPair() {
        XCTAssertTrue(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: true,
                collaborationInboxEnabled: true
            ).isConsistent
        )
        XCTAssertTrue(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: false,
                collaborationInboxEnabled: false
            ).isConsistent
        )
        XCTAssertFalse(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: true,
                collaborationInboxEnabled: false
            ).isConsistent
        )
        XCTAssertFalse(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: false,
                collaborationInboxEnabled: true
            ).isConsistent
        )
        XCTAssertTrue(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: true,
                collaborationInboxEnabled: true,
                pushNotificationsEnabled: true,
                canSendPushNotifications: true
            ).isConsistent
        )
        XCTAssertFalse(
            AppFeatureCapabilities(
                collaborationSubmissionEnabled: true,
                collaborationInboxEnabled: true,
                pushNotificationsEnabled: false,
                canSendPushNotifications: true
            ).isConsistent
        )
    }

    func testLegacyCapabilitiesDecodeWithPushDisabled() throws {
        let legacy = Data(
            #"{"collaborationSubmissionEnabled":true,"collaborationInboxEnabled":true}"#.utf8
        )
        let capabilities = try JSONDecoder().decode(
            AppFeatureCapabilities.self,
            from: legacy
        )

        XCTAssertFalse(capabilities.pushNotificationsEnabled)
        XCTAssertFalse(capabilities.canSendPushNotifications)
        XCTAssertTrue(capabilities.isConsistent)
    }

    func testAdminCollaborationDirectoryValidatesMailAndStatusContracts() {
        let now = Date(timeIntervalSince1970: 1_788_544_000)
        let request = AdminCollaborationRequest(
            requestID: "7d8cb55b-7358-4d25-8e4c-af657a122d44",
            fanUserID: "e4af5d2e-b6b2-42fa-a2ee-3b8777379d27",
            contactName: "林女士",
            contactMethod: "13800000000",
            organization: "梧桐影业",
            projectType: "drama",
            city: "杭州",
            preferredDate: "2026-10-01",
            budget: "5 万元",
            details: "短剧女主角",
            status: CollaborationRequestStatus.received.rawValue,
            version: 1,
            receivedAt: now.addingTimeInterval(-60),
            updatedAt: now,
            delivery: AdminCollaborationDelivery(
                status: "pending",
                attempts: 0,
                errorCode: ""
            )
        )
        let directory = AdminCollaborationDirectory(
            requests: [request],
            page: 1,
            perPage: 100,
            total: 1,
            statuses: CollaborationRequestStatus.allCases.map(\.rawValue)
        )
        XCTAssertTrue(
            AdminCollaborationValidation.isValid(
                directory,
                filteredBy: .received,
                now: now
            )
        )

        let invalidDelivery = AdminCollaborationRequest(
            requestID: request.requestID,
            fanUserID: request.fanUserID,
            contactName: request.contactName,
            contactMethod: request.contactMethod,
            organization: request.organization,
            projectType: request.projectType,
            city: request.city,
            preferredDate: request.preferredDate,
            budget: request.budget,
            details: request.details,
            status: request.status,
            version: request.version,
            receivedAt: request.receivedAt,
            updatedAt: request.updatedAt,
            delivery: AdminCollaborationDelivery(
                status: "retrying-forever",
                attempts: 99,
                errorCode: "raw error with spaces"
            )
        )
        XCTAssertFalse(AdminCollaborationValidation.isValid(invalidDelivery, now: now))
    }

    func testWeatherKitConditionsHaveChinesePresentation() {
        XCTAssertEqual(WeatherPresentation.conditionText(for: .clear), "晴")
        XCTAssertEqual(WeatherPresentation.conditionText(for: .heavyRain), "大雨")
        XCTAssertEqual(WeatherPresentation.conditionText(for: .wintryMix), "雨雪混合")

        for condition in WeatherCondition.allCases {
            XCTAssertFalse(WeatherPresentation.conditionText(for: condition).isEmpty)
        }
    }

    func testWeatherFailuresHaveStableNonSensitiveCategories() {
        XCTAssertEqual(
            WeatherFailurePresentation.diagnosticCode(for: WeatherError.permissionDenied),
            WeatherFailureCategory.permissionDenied.rawValue
        )
        XCTAssertEqual(
            WeatherFailurePresentation.diagnosticCode(for: WeatherError.unknown),
            WeatherFailureCategory.weatherUnknown.rawValue
        )
        XCTAssertEqual(
            WeatherFailurePresentation.diagnosticCode(for: URLError(.timedOut)),
            WeatherFailureCategory.urlLoadingBase.rawValue + abs(URLError.Code.timedOut.rawValue)
        )
        XCTAssertEqual(
            WeatherFailurePresentation.message(for: WeatherError.permissionDenied),
            "天气服务未授权"
        )
        XCTAssertEqual(
            WeatherFailurePresentation.message(for: URLError(.notConnectedToInternet)),
            "网络未连接"
        )
    }

    private func makePushStartupDefaults() throws -> UserDefaults {
        let suiteName = "PushStartupAuthorizationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makePortfolio(imageCount: Int) -> Portfolio {
        let images = (1...imageCount).map { id in
            PortfolioImage(
                id: id,
                url: URL(string: "https://img.shuzijun.com.cn/test/\(id)-display.jpg")!,
                fullSizeURL: URL(string: "https://img.shuzijun.com.cn/test/\(id)-full.jpg")!,
                altText: "第 \(id) 张"
            )
        }
        return Portfolio(
            id: 1,
            title: "测试相册",
            subtitle: "回归测试",
            eyebrow: "TEST",
            slug: "test",
            websiteURL: URL(string: "https://www.shuzijun.com.cn/portfolio/test/")!,
            coverURL: images.first?.url,
            images: images
        )
    }

    private func makeLaunchPoster(
        id: String,
        startsAt: Date,
        endsAt: Date? = nil
    ) -> LaunchPosterContent {
        LaunchPosterContent(
            id: id,
            isEnabled: true,
            imageURL: URL(string: "https://img.shuzijun.com.cn/launch/\(id).jpg")!,
            eyebrow: "YI SHU",
            title: "易姝",
            subtitle: "镜头之内，自有叙事。",
            startsAt: startsAt,
            endsAt: endsAt ?? Date(timeIntervalSince1970: 4_102_444_800),
            displaySeconds: 2.5
        )
    }

    func testPortfolioVisibilityDecodesLegacyAndHiddenAlbums() throws {
        var album = makePortfolio(imageCount: 3)
        let oldData = try JSONEncoder().encode(album)
        XCTAssertTrue(try JSONDecoder().decode(Portfolio.self, from: oldData).isVisibleToViewers)
        album.isVisible = false
        XCTAssertFalse(try JSONDecoder().decode(Portfolio.self,
            from: JSONEncoder().encode(album)).isVisibleToViewers)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        object["isVisible"] = "false"
        XCTAssertThrowsError(try JSONDecoder().decode(Portfolio.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    @MainActor
    func testHiddenAlbumsStayEditableButOutOfViewerCollections() throws {
        let base = makeManifest(aboutPortraitURL: nil)
        var album = base.portfolios[0]
        album.isVisible = false
        func manifest(_ audience: AppContentAudience) -> AppContentManifest {
            AppContentManifest(schemaVersion: 1, updatedAt: .now, heroImages: base.heroImages,
                aboutPortraitURL: nil, launchPosters: [], showreel: nil, dramas: [],
                portfolios: [album], contentAudience: audience)
        }
        let store = PortfolioStore()
        store.applyPublishedManifest(manifest(.administrator))
        XCTAssertTrue(store.portfolios.isEmpty)
        XCTAssertEqual(store.managedPortfolios.map(\.id), [album.id])
        XCTAssertFalse(try XCTUnwrap(store.managedPortfolios.first).isVisibleToViewers)
        XCTAssertTrue(AdminContentEditingPolicy.isFullAdministratorManifest(manifest(.administrator)))
        store.enforcePermissionScope(canViewFullGallery: false, canViewVideo: false)
        XCTAssertTrue(store.portfolios.isEmpty)
        album.isVisible = true
        store.applyPublishedManifest(manifest(.administrator))
        XCTAssertEqual(store.portfolios.first?.images, album.images)
        store.applyPublishedManifest(manifest(.viewer))
        XCTAssertTrue(store.managedPortfolios.isEmpty)
        store.discardProtectedContent()
    }

    @MainActor
    func testEmptyAlbumManifestClearsOldContentAndRejectsLateRefresh() {
        let base = makeManifest(aboutPortraitURL: nil)
        let empty = AppContentManifest(schemaVersion: 1, updatedAt: .now,
            heroImages: base.heroImages, aboutPortraitURL: nil, launchPosters: [],
            showreel: nil, dramas: [], portfolios: [], contentAudience: .viewer)
        XCTAssertTrue(ContentManifestPolicy.isValid(empty))
        XCTAssertTrue(ContentSecurityPolicy.isTrusted(empty))
        let store = PortfolioStore()
        store.applyPublishedManifest(base)
        let oldID = store.beginContentRefresh()
        let newID = store.beginContentRefresh()
        XCTAssertTrue(store.completeContentRefresh(newID, with: empty))
        XCTAssertTrue(store.portfolios.isEmpty)
        XCTAssertEqual(store.contentOrigin, .network)
        XCTAssertFalse(store.completeContentRefresh(oldID, with: base))
        XCTAssertTrue(store.portfolios.isEmpty)
        store.discardProtectedContent()
    }

    private func makeManifest(
        aboutPortraitURL: URL?, imageCount: Int = 3,
        launchPosters: [LaunchPosterContent]? = ContentCatalog.launchPosters
    ) -> AppContentManifest {
        AppContentManifest(
            schemaVersion: 1,
            updatedAt: .now,
            heroImages: [ContentCatalog.heroImages[0]],
            aboutPortraitURL: aboutPortraitURL,
            launchPosters: launchPosters,
            showreel: ContentCatalog.showreel,
            dramas: ContentCatalog.dramas,
            portfolios: [makePortfolio(imageCount: imageCount)]
        )
    }
}

@MainActor
private final class SignOutNotificationTestAccount: FanNotificationAccount {
    var notificationContext: FanNotificationContext? = .init(userID: "account-a", sessionGeneration: 1)
    let inbox = FanNotificationStore()
    var generation: UInt64 = 1
    var notificationPreference = true
    var messageID = "11111111-2222-4333-8444-555555555555"

    var message: FanNotification {
        FanNotification(
            notificationID: messageID, title: "当前账号消息", body: notificationContext?.userID ?? "",
            sensitive: true, createdAt: Date().addingTimeInterval(-60),
            expiresAt: Date().addingTimeInterval(3600), readAt: Date().addingTimeInterval(-30)
        )
    }

    func fetchNotificationPage(cursor: String?) async throws -> FanNotificationPage {
        guard notificationContext != nil else { throw FanNotificationError.signInRequired }
        return FanNotificationPage(notifications: [message], nextCursor: nil, unreadCount: 0)
    }

    func fetchNotification(id: String) async throws -> FanNotification { message }
    func markNotificationRead(id: String) async throws -> FanNotification { message }

    func clearLocalState() {
        generation &+= 1
        notificationContext = nil
        inbox.updateContext(nil)
    }

    func switchToNewAccount() {
        generation &+= 1
        notificationContext = .init(userID: "account-b", sessionGeneration: generation)
        messageID = "11111111-2222-4333-8444-666666666666"
        inbox.updateContext(notificationContext)
    }
}

@MainActor
private final class SuspendedSignOutTestSender {
    private(set) var requests: [FanSignOutOperation.Request] = []
    var firstRequestStarted: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?

    func send(_ request: FanSignOutOperation.Request) async throws {
        requests.append(request)
        if requests.count == 1 {
            await withCheckedContinuation {
                continuation = $0
                firstRequestStarted?()
            }
        }
        // Model an old-session 401 after another account has signed in. The
        // production error decoder only throws; it must not clear that account.
        throw FanAccountError.sessionExpired
    }

    func resume() { let pending = continuation; continuation = nil; pending?.resume() }
}

@MainActor
final class FanSignOutLifecycleTests: XCTestCase {
    func testCleanupTransportTimesOutAgainstLoopbackPeerThatNeverCompletesTLS() async throws {
        // No external traffic or credentials: accept TCP only on loopback and
        // deliberately never answer TLS, reproducing a stalled connection.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "Loopback listener ready")
        var connections: [NWConnection] = []
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                connections.append(connection)
                connection.start(queue: .main)
            }
        }
        listener.start(queue: .main)
        let cleanup = FanSignOutTransportPolicy.makeSession()
        defer {
            cleanup.invalidateAndCancel()
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let url = try XCTUnwrap(URL(string: "https://127.0.0.1:\(port.rawValue)/cleanup-timeout-fixture"))
        var request = URLRequest(url: url)
        request.timeoutInterval = cleanup.configuration.timeoutIntervalForRequest
        let started = ContinuousClock.now
        do {
            _ = try await cleanup.data(for: request)
            XCTFail("Stalled TLS connection must not succeed")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(8),
                          "Cleanup must not inherit the normal 45-second resource timeout")
        XCTAssertFalse(connections.isEmpty, "Test must reach the loopback listener")
    }

    func testCleanupTransportHasShortTotalTimeoutWithoutChangingRegularAccountTransport() {
        let normal = SecureURLSessionFactory.make(requestTimeout: 30, resourceTimeout: 45)
        let first = FanSignOutTransportPolicy.makeSession()
        let second = FanSignOutTransportPolicy.makeSession()
        defer {
            normal.invalidateAndCancel()
            first.invalidateAndCancel()
            second.invalidateAndCancel()
        }
        XCTAssertFalse(first === normal)
        XCTAssertFalse(first === second)
        XCTAssertEqual(normal.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(normal.configuration.timeoutIntervalForResource, 45)
        XCTAssertTrue(normal.configuration.waitsForConnectivity)
        for cleanup in [first, second] {
            XCTAssertEqual(cleanup.configuration.timeoutIntervalForRequest, 3)
            XCTAssertEqual(cleanup.configuration.timeoutIntervalForResource, 3)
            XCTAssertFalse(cleanup.configuration.waitsForConnectivity)
            XCTAssertNil(cleanup.configuration.urlCache)
            XCTAssertNil(cleanup.configuration.httpCookieStorage)
            XCTAssertNil(cleanup.configuration.urlCredentialStorage)
            XCTAssertTrue(cleanup.delegate is RejectingRedirectURLSessionDelegate)
        }
    }

    func testUnbindTimeoutStillAttemptsFrozenSessionLogoutAndDoesNotRestoreAccess() async {
        let frozenToken = UUID().uuidString
        var locallySignedIn = true
        let operation = FanSignOutOperation.begin(
            authorizationToken: frozenToken, unbindingBody: Data("{}".utf8)
        ) { locallySignedIn = false }
        var sent: [FanSignOutOperation.Request] = []
        await operation.complete { request in
            XCTAssertFalse(locallySignedIn)
            sent.append(request)
            throw URLError(.timedOut)
        }
        XCTAssertFalse(locallySignedIn)
        XCTAssertEqual(sent.map(\.method), ["DELETE", "POST"])
        XCTAssertTrue(sent.allSatisfy { $0.authorizationToken == frozenToken })
    }

    func testSignOutClearsMessagesBeforeNetworkAndLateFailureCannotClearNewAccount() async throws {
        let account = SignOutNotificationTestAccount()
        await account.inbox.refresh(using: account)
        await account.inbox.open(id: account.messageID, using: account)
        XCTAssertEqual(account.inbox.detail?.body, "account-a")
        let oldGeneration = account.generation
        let oldToken = UUID().uuidString
        let oldBody = try JSONSerialization.data(withJSONObject: [
            "installID": UUID().uuidString.lowercased(), "bindingGeneration": "8",
        ])
        let operation = FanSignOutOperation.begin(
            authorizationToken: oldToken, unbindingBody: oldBody,
            clearLocalState: account.clearLocalState
        )
        // No Task has even started: this state must be cleared synchronously.
        XCTAssertNil(account.notificationContext)
        XCTAssertTrue(account.inbox.notifications.isEmpty)
        XCTAssertNil(account.inbox.detail)
        XCTAssertGreaterThan(account.generation, oldGeneration)
        XCTAssertTrue(account.notificationPreference, "退出不能改写用户的通知偏好")

        let sender = SuspendedSignOutTestSender()
        let started = expectation(description: "旧账号解绑请求挂起")
        sender.firstRequestStarted = { started.fulfill() }
        let completion = Task { await operation.complete(using: sender.send) }
        await fulfillment(of: [started], timeout: 2)
        await account.inbox.refresh(using: account) // foreground while signed out
        XCTAssertTrue(account.inbox.notifications.isEmpty)
        XCTAssertNil(account.notificationContext)

        account.switchToNewAccount()
        await account.inbox.refresh(using: account)
        await account.inbox.open(id: account.messageID, using: account)
        let newContext = account.notificationContext
        let newGeneration = account.generation
        sender.resume()
        await completion.value
        XCTAssertEqual(account.notificationContext, newContext)
        XCTAssertEqual(account.generation, newGeneration)
        XCTAssertEqual(account.inbox.notifications.first?.body, "account-b")
        XCTAssertEqual(account.inbox.detail?.body, "account-b")
        XCTAssertEqual(sender.requests.map(\.method), ["DELETE", "POST"])
        XCTAssertEqual(sender.requests.map(\.path), ["shuzijun/v1/fan/push-device", "shuzijun/v1/fan/logout"])
        XCTAssertTrue(sender.requests.allSatisfy { $0.authorizationToken == oldToken })
        XCTAssertEqual(sender.requests.first?.body, oldBody)
        XCTAssertNil(sender.requests.last?.body)
    }

    func testMissingUnbindBodyStillLogsOutOldSessionAndMissingTokenStillClearsLocalState() async {
        var cleared = 0
        var sent: [FanSignOutOperation.Request] = []
        let oldToken = UUID().uuidString
        let operation = FanSignOutOperation.begin(authorizationToken: oldToken, unbindingBody: nil) { cleared += 1 }
        XCTAssertEqual(cleared, 1)
        await operation.complete { sent.append($0) }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.path, "shuzijun/v1/fan/logout")
        XCTAssertEqual(sent.first?.authorizationToken, oldToken)
        let noSession = FanSignOutOperation.begin(authorizationToken: nil, unbindingBody: nil) { cleared += 1 }
        XCTAssertEqual(cleared, 2)
        await noSession.complete { _ in XCTFail("无旧凭据时不得发送匿名注销请求") }
    }

}
