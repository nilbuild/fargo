import Foundation
import AppKit
import AuthenticationServices
import CryptoKit
import Security

@MainActor @Observable
final class YouTubeAuth {
    static let clientId = "893873338434-rg1dv2qssh8gbqvr2a76bldljojar217.apps.googleusercontent.com"
    static let scopes = "https://www.googleapis.com/auth/youtube.readonly"

    static var isConfigured: Bool {
        return !clientId.hasPrefix("YOUR_")
    }

    static var redirectScheme: String {
        let suffix = ".apps.googleusercontent.com"
        guard clientId.hasSuffix(suffix) else {
            return "com.googleusercontent.apps.\(clientId)"
        }
        return "com.googleusercontent.apps.\(clientId.dropLast(suffix.count))"
    }

    static var redirectUri: String {
        return "\(redirectScheme):/oauth2redirect"
    }

    private(set) var isSignedIn = false
    private(set) var channelInfo: YouTubeChannelInfo?
    private(set) var channelError: String?
    private(set) var isAuthenticating = false
    private(set) var authError: String?

    private var tokens: YouTubeTokens?
    private var webAuthSession: ASWebAuthenticationSession?
    private let anchorProvider = WebAuthAnchorProvider()

    private let keychainService = "com.streamif.youtube"
    private let keychainAccount = "oauth-tokens"

    init() {
        loadTokensFromKeychain()
    }

    // MARK: - Public API

    func signIn() {
        guard !isAuthenticating else { return }
        guard YouTubeAuth.isConfigured else {
            presentConfigurationError()
            return
        }

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: YouTubeAuth.clientId),
            URLQueryItem(name: "redirect_uri", value: YouTubeAuth.redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: YouTubeAuth.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let url = components.url else { return }

        isAuthenticating = true
        authError = nil

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: YouTubeAuth.redirectScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.webAuthSession = nil

                guard let callbackURL else {
                    self.finishSignIn(error: error)
                    return
                }

                guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.finishSignIn(error: nil)
                    return
                }

                await self.exchangeCodeForTokens(code: code, verifier: verifier)
                self.isAuthenticating = false
            }
        }

        session.presentationContextProvider = anchorProvider
        webAuthSession = session

        guard session.start() else {
            webAuthSession = nil
            isAuthenticating = false
            authError = "Could not open the Google sign-in window."
            return
        }
    }

    func cancelSignIn() {
        webAuthSession?.cancel()
        webAuthSession = nil
        isAuthenticating = false
    }

    func signOut() {
        let revokedToken = tokens?.accessToken

        tokens = nil
        isSignedIn = false
        channelError = nil
        channelInfo = nil
        authError = nil
        deleteTokensFromKeychain()

        guard let revokedToken else { return }

        Task {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(revokedToken)")!)
            request.httpMethod = "POST"
            try? await URLSession.shared.data(for: request)
        }
    }

    func getAccessToken() async -> String? {
        guard var tokens = tokens else { return nil }

        if tokens.isExpired {
            guard let refreshed = await refreshAccessToken(refreshToken: tokens.refreshToken) else {
                signOut()
                return nil
            }
            tokens = refreshed
            self.tokens = refreshed
            saveTokensToKeychain()
        }

        return tokens.accessToken
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, verifier: String) async {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id=\(YouTubeAuth.clientId)",
            "code=\(code)",
            "code_verifier=\(verifier)",
            "grant_type=authorization_code",
            "redirect_uri=\(YouTubeAuth.redirectUri)",
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let accessToken = json?["access_token"] as? String,
                  let refreshToken = json?["refresh_token"] as? String,
                  let expiresIn = json?["expires_in"] as? Int,
                  let scope = json?["scope"] as? String else {
                authError = (json?["error_description"] as? String) ?? "Google rejected the sign-in request."
                print("[YouTubeAuth] Token exchange rejected: \(json ?? [:])")
                return
            }

            let tokens = YouTubeTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
                scope: scope
            )
            self.tokens = tokens
            self.isSignedIn = true
            saveTokensToKeychain()
            await fetchChannelInfo()
        } catch {
            authError = "Could not reach Google to complete sign-in."
            print("[YouTubeAuth] Token exchange failed: \(error)")
        }
    }

    private func refreshAccessToken(refreshToken: String) async -> YouTubeTokens? {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id=\(YouTubeAuth.clientId)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let accessToken = json?["access_token"] as? String,
                  let expiresIn = json?["expires_in"] as? Int else {
                return nil
            }

            return YouTubeTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
                scope: tokens?.scope ?? ""
            )
        } catch {
            return nil
        }
    }

    // MARK: - Channel Info

    private func fetchChannelInfo() async {
        guard let token = await getAccessToken() else { return }

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "mine", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                var detail = "HTTP \(http.statusCode)"
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = object["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    detail = message
                }
                channelError = "Could not read your channel: \(detail)"
                print("[YouTubeAuth] Channel lookup failed: \(detail)")
                return
            }

            let decoded = try JSONDecoder().decode(YouTubeListResponse<YouTubeChannelItem>.self, from: data)

            guard let item = decoded.items?.first else {
                // A Google account with no channel authenticates fine and then
                // fails every YouTube call, which is easy to mistake for a bug.
                channelError = "This Google account has no YouTube channel. Sign out and pick the channel you stream from."
                print("[YouTubeAuth] Signed-in account has no YouTube channel")
                return
            }

            channelError = nil
            channelInfo = YouTubeChannelInfo(
                channelId: item.id,
                channelTitle: item.snippet?.title ?? "",
                thumbnailUrl: item.snippet?.thumbnails?.default?.url
            )
        } catch {
            channelError = "Could not read your channel: \(error.localizedDescription)"
            print("[YouTubeAuth] Failed to fetch channel info: \(error)")
        }
    }

    // MARK: - Sign-in Failures

    private func finishSignIn(error: Error?) {
        isAuthenticating = false

        guard let error else {
            authError = "Google did not return an authorization code."
            return
        }

        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
            return
        }

        authError = error.localizedDescription
        print("[YouTubeAuth] Sign-in failed: \(error)")
    }

    private func presentConfigurationError() {
        authError = "YouTube sign-in is not configured. See README.md."

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "YouTube sign-in is not configured"
        alert.informativeText = """
        This build has no Google OAuth client ID.

        Register an "iOS" OAuth client in the Google Cloud console, then set YouTubeAuth.clientId and the matching URL scheme in Info.plist. Setup steps are in README.md.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain

    private func saveTokensToKeychain() {
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadTokensFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data,
           let saved = try? JSONDecoder().decode(YouTubeTokens.self, from: data) {
            tokens = saved
            isSignedIn = true
            Task { await fetchChannelInfo() }
        }
    }

    private func deleteTokensFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Web Auth Presentation

private final class WebAuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return MainActor.assumeIsolated {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        }
    }
}
