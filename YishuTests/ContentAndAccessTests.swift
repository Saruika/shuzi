import XCTest
import WeatherKit
@testable import Yishu

final class ContentAndAccessTests: XCTestCase {
    func testWeatherLocationAlwaysKeepsAConcisePlaceName() {
        XCTAssertEqual(WeatherPresentation.conciseLocationText("杭州市"), "杭州")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("香港特别行政区"), "香港")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("浙江·杭州"), "浙江·杭州")
        XCTAssertEqual(WeatherPresentation.conciseLocationText("  "), "当前位置")
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

    func testEveryBundledHeroHasAStableMatchingFallback() {
        XCTAssertEqual(ContentCatalog.heroImages.count, 5)
        for (index, url) in ContentCatalog.heroImages.enumerated() {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNotNil(ContentCatalog.heroAssetName(at: index))
            XCTAssertTrue(ContentSecurityPolicy.isTrustedMediaURL(url))
        }
        XCTAssertNil(ContentCatalog.heroAssetName(at: ContentCatalog.heroImages.count))
    }

    func testBundledLaunchPosterDoesNotReuseAHomeHero() {
        let homeHeroes = Set(ContentCatalog.heroImages)

        XCTAssertFalse(ContentCatalog.launchPosters.isEmpty)
        for poster in ContentCatalog.launchPosters {
            XCTAssertFalse(homeHeroes.contains(poster.imageURL))
        }
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
        XCTAssertTrue(ContentManifestPolicy.isSupportedCacheSchemaVersion(3))
        XCTAssertFalse(ContentManifestPolicy.isSupportedCacheSchemaVersion(4))
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

    func testPublishedManifestUsesAStableTrustedHTTPSEndpoint() {
        let endpoint = ContentCatalog.publishedManifestURL

        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.host, "shuzijun.com.cn")
        XCTAssertNil(endpoint.user)
        XCTAssertNil(endpoint.password)
    }

    func testPrivacyPolicyUsesTheOfficialHTTPSOrigin() {
        XCTAssertTrue(AppNetworkSecurityPolicy.isTrustedHTTPSOrigin(ContentCatalog.privacyPolicyURL))
        XCTAssertEqual(ContentCatalog.privacyPolicyURL.path, "/app-privacy")
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

    func testFanRegistrationRequiresASafeDouyinID() {
        XCTAssertEqual(FanAccountValidation.normalizedDouyinID(" @YiShu_2026 "), "yishu_2026")
        XCTAssertEqual(FanAccountValidation.normalizedDouyinID("一只梳子君"), "一只梳子君")
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("https://v.douyin.com/example"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("a b"))
        XCTAssertNil(FanAccountValidation.normalizedDouyinID("@"))
    }

    func testFanPasswordPolicyRequiresLengthAndTwoCharacterCategories() {
        XCTAssertTrue(FanAccountValidation.isValidPassword("fansafety2026"))
        XCTAssertTrue(FanAccountValidation.isValidPassword("乖乖影像安全2026"))
        XCTAssertTrue(FanAccountValidation.isValidPassword("long-password"))
        XCTAssertFalse(FanAccountValidation.isValidPassword("onlyletters"))
        XCTAssertFalse(FanAccountValidation.isValidPassword("short1"))
        XCTAssertFalse(FanAccountValidation.isValidPassword(" fansafety2026"))
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

    private func makeManifest(aboutPortraitURL: URL?, imageCount: Int = 3) -> AppContentManifest {
        AppContentManifest(
            schemaVersion: 1,
            updatedAt: .now,
            heroImages: [ContentCatalog.heroImages[0]],
            aboutPortraitURL: aboutPortraitURL,
            launchPosters: ContentCatalog.launchPosters,
            showreel: ContentCatalog.showreel,
            dramas: ContentCatalog.dramas,
            portfolios: [makePortfolio(imageCount: imageCount)]
        )
    }
}
