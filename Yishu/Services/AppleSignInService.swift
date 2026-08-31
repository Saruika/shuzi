import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct FanAppleChallenge: Decodable, Equatable {
    let challengeID: String
    let nonce: String
    let state: String
    let expiresAt: Date

    func isValid(now: Date = Date()) -> Bool {
        challengeID.range(
            of: #"^[A-Za-z0-9_-]{16,128}$"#,
            options: .regularExpression
        ) != nil
            && nonce.range(
                of: #"^[A-Za-z0-9_-]{32,128}$"#,
                options: .regularExpression
            ) != nil
            && state.range(
                of: #"^[A-Za-z0-9_-]{32,128}$"#,
                options: .regularExpression
            ) != nil
            && expiresAt > now
            && expiresAt.timeIntervalSince(now) <= 10 * 60
    }
}

struct FanAppleCredentialSubmission {
    let identityToken: String
    let authorizationCode: String
    let challengeID: String
    let state: String
    /// Used only for Apple's local credential-state checks after the server
    /// accepts the signed identity token. It is never sent to our API.
    let localAppleUserID: String
}

enum FanAppleCredentialStateDecision: Equatable {
    case authorize
    case revoke
    case transfer
    case unknown
}

enum FanAppleCredentialQueryDisposition: Equatable {
    case evaluateCredential
    case retryKeepingSession
}

enum FanAppleCredentialStatePolicy {
    static func queryDisposition(hasError: Bool) -> FanAppleCredentialQueryDisposition {
        hasError ? .retryKeepingSession : .evaluateCredential
    }

    static func decision(
        for state: ASAuthorizationAppleIDProvider.CredentialState
    ) -> FanAppleCredentialStateDecision {
        switch state {
        case .authorized:
            .authorize
        case .revoked, .notFound:
            .revoke
        case .transferred:
            .transfer
        @unknown default:
            .unknown
        }
    }
}

enum AppleSignInSecurity {
    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func statesMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt(left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            difference |= UInt(l ^ r)
        }
        return difference == 0
    }

    static func validatedIdentityToken(_ data: Data?) -> String? {
        guard let data, (64...16_384).contains(data.count),
              let value = String(data: data, encoding: .utf8),
              value.split(separator: ".", omittingEmptySubsequences: false).count == 3,
              value.range(
                of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#,
                options: .regularExpression
              ) != nil else { return nil }
        return value
    }

    static func validatedAuthorizationCode(_ data: Data?) -> String? {
        guard let data, (1...4_096).contains(data.count),
              let value = String(data: data, encoding: .utf8),
              value.range(
                of: #"^[\u{21}-\u{7E}]+$"#,
                options: .regularExpression
              ) != nil else { return nil }
        return value
    }
}

enum AppleSignInCoordinatorError: LocalizedError {
    case cancelled
    case challengeExpired
    case invalidCredential
    case staleResponse
    case presentationUnavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: "已取消“通过 Apple 登录”。"
        case .challengeExpired: "登录验证已过期，请重新尝试。"
        case .invalidCredential: "Apple 返回的登录凭据无效，请重新尝试。"
        case .staleResponse: "登录状态已经变化，请重新尝试。"
        case .presentationUnavailable: "暂时无法显示 Apple 登录页面，请稍后重试。"
        }
    }
}

@MainActor
final class AppleSignInCoordinator: NSObject, ObservableObject {
    @Published private(set) var isWorking = false

    private weak var presentationAnchor: UIWindow?
    private var controller: ASAuthorizationController?
    private var challenge: FanAppleChallenge?
    private var completion: ((Result<FanAppleCredentialSubmission, Error>) -> Void)?
    private var generation: UInt64 = 0

    func start(
        challenge: FanAppleChallenge,
        presentationAnchor: UIWindow?,
        completion: @escaping (Result<FanAppleCredentialSubmission, Error>) -> Void
    ) {
        cancel(notifying: false)
        guard challenge.isValid() else {
            completion(.failure(AppleSignInCoordinatorError.challengeExpired))
            return
        }
        guard let presentationAnchor else {
            completion(.failure(AppleSignInCoordinatorError.presentationUnavailable))
            return
        }

        generation &+= 1
        self.presentationAnchor = presentationAnchor
        self.challenge = challenge
        self.completion = completion
        isWorking = true

        let request = ASAuthorizationAppleIDProvider().createRequest()
        // Data minimization: nickname and Douyin ID are collected explicitly in
        // the next form. We do not request Apple's name or email scopes.
        request.nonce = AppleSignInSecurity.sha256Hex(challenge.nonce)
        request.state = challenge.state

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        controller.performRequests()
    }

    func cancel() {
        cancel(notifying: false)
    }

    private func cancel(notifying: Bool) {
        generation &+= 1
        controller?.cancel()
        controller = nil
        presentationAnchor = nil
        challenge = nil
        let completion = self.completion
        self.completion = nil
        isWorking = false
        if notifying { completion?(.failure(AppleSignInCoordinatorError.cancelled)) }
    }

    private func finish(_ result: Result<FanAppleCredentialSubmission, Error>) {
        controller = nil
        presentationAnchor = nil
        challenge = nil
        let completion = self.completion
        self.completion = nil
        isWorking = false
        completion?(result)
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor [weak self] in
            guard let self, controller === self.controller,
                  let challenge = self.challenge,
                  challenge.isValid(),
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  AppleSignInSecurity.statesMatch(credential.state, challenge.state),
                  let identityToken = AppleSignInSecurity.validatedIdentityToken(
                    credential.identityToken
                  ),
                  let authorizationCode = AppleSignInSecurity.validatedAuthorizationCode(
                    credential.authorizationCode
                  ),
                  !credential.user.isEmpty,
                  credential.user.count <= 1_024 else {
                self?.finish(.failure(AppleSignInCoordinatorError.invalidCredential))
                return
            }
            self.finish(.success(FanAppleCredentialSubmission(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                challengeID: challenge.challengeID,
                state: challenge.state,
                localAppleUserID: credential.user
            )))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self, controller === self.controller else { return }
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                self.finish(.failure(AppleSignInCoordinatorError.cancelled))
            } else {
                self.finish(.failure(AppleSignInCoordinatorError.invalidCredential))
            }
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { presentationAnchor ?? ASPresentationAnchor() }
    }
}
