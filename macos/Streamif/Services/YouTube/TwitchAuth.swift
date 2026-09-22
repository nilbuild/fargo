import Foundation
import AppKit
import Security

@MainActor @Observable
final class TwitchAuth {
    static let clientId = "y9v1bdcjhi0dgymdxzyuiwbxetx6e0"
    static let scopes = "chat:read user:read:email"

    static var isConfigured: Bool {
        return !clientId.hasPrefix("YOUR_")
    }

    private(set) var isSignedIn = false
    private(set) var username: String?
    private(set) var isAuthenticating = false
    private(set) var userCode: String?
    private(set) var verificationUri: String?
    private(set) var authError: String?

    private var accessToken: String?
    private var refreshToken: String?
    private var pollingTask: Task<Void, Never>?

    private let keychainService = "com.streamif.twitch"
    private let keychainAccount = "oauth-tokens"

    init() {
        loadTokensFromKeychain()
    }

    // MARK: - Public API

    func signIn() {
        guard !isAuthenticating else { return }
        guard TwitchAuth.isConfigured else {
            presentConfigurationError()
            return
        }

        isAuthenticating = true
        userCode = nil
        verificationUri = nil
        authError = nil

        Task {
            await startDeviceCodeFlow()
        }
    }

    func cancelSignIn() {
        pollingTask?.cancel()
        pollingTask = nil
        isAuthenticating = false
        userCode = nil
        verificationUri = nil
    }

    func signOut() {
        pollingTask?.cancel()
        pollingTask = nil
        accessToken = nil
        refreshToken = nil
        username = nil
        isSignedIn = false
        userCode = nil
        verificationUri = nil
        authError = nil
        deleteTokensFromKeychain()
    }

    func getAccessToken() async -> String? {
        guard let token = accessToken else { return nil }

        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let login = json["login"] as? String, username == nil {
                    username = login
                }
                return token
            }

            if let refreshed = await refreshAccessToken() {
                return refreshed
            }
            signOut()
            return nil
        } catch {
            return token
        }
    }

    // MARK: - Device Code Flow

    private func startDeviceCodeFlow() async {
        let url = URL(string: "https://id.twitch.tv/oauth2/device")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(TwitchAuth.clientId)&scopes=\(TwitchAuth.scopes.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? TwitchAuth.scopes)"
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let deviceCode = json["device_code"] as? String,
                  let code = json["user_code"] as? String,
                  let uri = json["verification_uri"] as? String,
                  let interval = json["interval"] as? Int else {
                authError = "Twitch rejected the sign-in request. Check that TwitchAuth.clientId is a Public client."
                isAuthenticating = false
                return
            }

            userCode = code
            verificationUri = uri

            if let verifyUrl = URL(string: uri) {
                NSWorkspace.shared.open(verifyUrl)
            }

            pollingTask = Task {
                await pollForToken(deviceCode: deviceCode, interval: interval)
            }
        } catch {
            print("[TwitchAuth] Device code request failed: \(error)")
            authError = "Could not reach Twitch to start sign-in."
            isAuthenticating = false
        }
    }

    private func presentConfigurationError() {
        authError = "Twitch sign-in is not configured. See README.md."

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Twitch sign-in is not configured"
        alert.informativeText = """
        This build has no Twitch client ID.

        Register an application on the Twitch developer console with client type "Public", then set TwitchAuth.clientId. Setup steps are in README.md.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func pollForToken(deviceCode: String, interval: Int) async {
        let pollInterval = UInt64(max(interval, 5)) * 1_000_000_000

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pollInterval)
            if Task.isCancelled { break }

            let url = URL(string: "https://id.twitch.tv/oauth2/token")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let body = [
                "client_id=\(TwitchAuth.clientId)",
                "scopes=\(TwitchAuth.scopes.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? TwitchAuth.scopes)",
                "device_code=\(deviceCode)",
                "grant_type=urn:ietf:params:oauth:grant-type:device_code",
            ].joined(separator: "&")

            request.httpBody = body.data(using: .utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                    if let token = json?["access_token"] as? String {
                        accessToken = token
                        refreshToken = json?["refresh_token"] as? String
                        isSignedIn = true
                        isAuthenticating = false
                        userCode = nil
                        verificationUri = nil
                        saveTokensToKeychain()
                        await fetchUsername()
                        return
                    }
                }

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = json["message"] as? String {
                    if message == "authorization_pending" {
                        continue
                    }
                    // slow_down, expired, access_denied
                    print("[TwitchAuth] Polling error: \(message)")
                    authError = message
                    isAuthenticating = false
                    userCode = nil
                    verificationUri = nil
                    return
                }
            } catch {
                if !Task.isCancelled {
                    print("[TwitchAuth] Polling failed: \(error)")
                }
            }
        }

        isAuthenticating = false
        userCode = nil
        verificationUri = nil
    }

    // MARK: - Token Refresh

    private func refreshAccessToken() async -> String? {
        guard let refresh = refreshToken else { return nil }

        let url = URL(string: "https://id.twitch.tv/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id=\(TwitchAuth.clientId)",
            "refresh_token=\(refresh)",
            "grant_type=refresh_token",
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let token = json?["access_token"] as? String else { return nil }

            accessToken = token
            if let newRefresh = json?["refresh_token"] as? String {
                refreshToken = newRefresh
            }
            saveTokensToKeychain()
            return token
        } catch {
            return nil
        }
    }

    // MARK: - Username

    private func fetchUsername() async {
        guard let token = accessToken else { return }

        var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let login = json["login"] as? String {
                username = login
            }
        } catch {
            print("[TwitchAuth] Failed to fetch username: \(error)")
        }
    }

    // MARK: - Keychain

    private func saveTokensToKeychain() {
        guard let accessToken else { return }
        let dict: [String: String] = [
            "access_token": accessToken,
            "refresh_token": refreshToken ?? "",
            "username": username ?? "",
        ]
        guard let data = try? JSONEncoder().encode(dict) else { return }

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
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            accessToken = dict["access_token"]
            refreshToken = dict["refresh_token"]
            username = dict["username"]
            if accessToken != nil {
                isSignedIn = true
            }
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
