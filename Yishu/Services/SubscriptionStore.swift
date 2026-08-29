import Combine
import StoreKit

@MainActor
final class SubscriptionStore: ObservableObject {
    static let monthlyProductID = "cn.com.shuzijun.yishu.photos.monthly"

    @Published private(set) var monthlyProduct: Product?
    @Published private(set) var hasActiveSubscription = false
    @Published private(set) var entitlementJWS: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published var statusMessage: String?

#if DEBUG
    @Published private(set) var isDebugAccessEnabled = false
#endif

    private var transactionUpdatesTask: Task<Void, Never>?

    var hasFullPhotoAccess: Bool {
#if DEBUG
        hasActiveSubscription || isDebugAccessEnabled
#else
        hasActiveSubscription
#endif
    }

    var localizedMonthlyPrice: String {
        monthlyProduct?.displayPrice ?? "¥3"
    }

    var canPurchase: Bool {
        monthlyProduct != nil && !isPurchasing
    }

    init() {
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self?.refreshEntitlement()
            }
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            monthlyProduct = try await Product.products(for: [Self.monthlyProductID]).first
            await refreshEntitlement()
            statusMessage = monthlyProduct == nil
                ? "订阅商品正在准备中，请稍后再试。"
                : nil
        } catch {
            await refreshEntitlement()
            statusMessage = "暂时无法连接 App Store，请检查网络后重试。"
        }
    }

    func purchaseMonthly() async {
        guard let monthlyProduct else {
            statusMessage = "订阅商品尚未就绪，请稍后重试。"
            await refresh()
            return
        }

        isPurchasing = true
        statusMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await monthlyProduct.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    statusMessage = "购买凭证未通过 Apple 验证，请联系支持。"
                    return
                }
                await transaction.finish()
                await refreshEntitlement()
                if !hasActiveSubscription {
                    statusMessage = "订阅正在处理中，请稍后再试。"
                }
            case .pending:
                statusMessage = "购买正在等待确认，确认后会自动解锁。"
            case .userCancelled:
                break
            @unknown default:
                statusMessage = "购买状态暂时无法确认，请稍后重试。"
            }
        } catch {
            statusMessage = "购买未完成：\(error.localizedDescription)"
        }
    }

    func restorePurchases() async {
        isPurchasing = true
        statusMessage = nil
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await refreshEntitlement()
            statusMessage = hasActiveSubscription
                ? "已恢复订阅，全部作品现已解锁。"
                : "没有找到仍在有效期内的订阅。"
        } catch {
            statusMessage = "恢复购买失败：\(error.localizedDescription)"
        }
    }

    func clearStatusMessage() {
        statusMessage = nil
    }

#if DEBUG
    func toggleDebugAccess() {
        isDebugAccessEnabled.toggle()
        statusMessage = isDebugAccessEnabled ? "测试模式：全部作品已解锁。" : nil
    }
#endif

    private func refreshEntitlement() async {
        var isEntitled = false
        var activeEntitlementJWS: String?
        let now = Date()

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.monthlyProductID,
                  transaction.revocationDate == nil else {
                continue
            }

            if let expirationDate = transaction.expirationDate, expirationDate <= now {
                continue
            }

            isEntitled = true
            activeEntitlementJWS = result.jwsRepresentation
            break
        }

        hasActiveSubscription = isEntitled
        entitlementJWS = activeEntitlementJWS
    }
}

enum PhotoAccessPolicy {
    static let freePreviewCount = 3

    static func isFreePreview(_ image: PortfolioImage, in portfolio: Portfolio) -> Bool {
        guard let index = portfolio.images.firstIndex(where: { $0.id == image.id }) else {
            return false
        }
        return index < freePreviewCount
    }

    static func canAccess(
        _ image: PortfolioImage,
        in portfolio: Portfolio,
        hasSubscription: Bool,
        isAdministrator: Bool
    ) -> Bool {
        isAdministrator || hasSubscription || isFreePreview(image, in: portfolio)
    }

    static func accessibleImages(
        in portfolio: Portfolio,
        hasSubscription: Bool,
        isAdministrator: Bool
    ) -> [PortfolioImage] {
        guard !isAdministrator, !hasSubscription else { return portfolio.images }
        return Array(portfolio.images.prefix(freePreviewCount))
    }
}
