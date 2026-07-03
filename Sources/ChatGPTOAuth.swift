import AppKit
import CryptoKit
import Foundation
import Network

/// "Sign in with ChatGPT" OAuth for LLM refinement using a ChatGPT Plus/Pro
/// subscription instead of an API key.
///
/// Implements the same PKCE authorization-code flow as the official Codex CLI
/// (public client id, localhost callback on port 1455). Tokens are stored in
/// `~/.config/macwhisper/chatgpt-oauth.json` with owner-only permissions.
/// Intended for personal use with the user's own subscription, mirroring the
/// community OAuth plugins for opencode and similar open-source tools.
final class ChatGPTOAuth {
    static let shared = ChatGPTOAuth()

    // OAuth constants from the official Codex CLI (openai/codex).
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    private static let tokenURL = "https://auth.openai.com/oauth/token"
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scope = "openid profile email offline_access"
    private static let callbackPort: NWEndpoint.Port = 1455

    struct AuthError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Credentials: Codable {
        var access: String
        var refresh: String
        /// Epoch seconds when the access token expires.
        var expiresAt: TimeInterval
        var accountID: String
    }

    private static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macwhisper/chatgpt-oauth.json")
    }

    private var listener: NWListener?
    private var pendingVerifier: String?
    private var pendingState: String?
    private var signInCompletion: ((Result<Void, Error>) -> Void)?

    var isSignedIn: Bool { loadCredentials() != nil }

    // MARK: - Sign in / out

    /// Starts the browser OAuth flow. The completion fires on an arbitrary queue
    /// after the callback is received and tokens are stored (or on failure).
    func signIn(completion: @escaping (Result<Void, Error>) -> Void) {
        // A previous unfinished attempt holds the port; tear it down first.
        stopCallbackServer()

        let verifier = Self.randomURLSafeString(bytes: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(bytes: 16)
        pendingVerifier = verifier
        pendingState = state
        signInCompletion = completion

        do {
            try startCallbackServer()
        } catch {
            finishSignIn(.failure(AuthError(message: "Could not open callback port 1455: \(error.localizedDescription)")))
            return
        }

        var comps = URLComponents(string: Self.authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        NSWorkspace.shared.open(comps.url!)

        // Give up after 5 minutes so the port isn't held forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, self.signInCompletion != nil else { return }
            self.finishSignIn(.failure(AuthError(message: "Sign-in timed out")))
        }
    }

    func signOut() {
        try? FileManager.default.removeItem(at: Self.credentialsURL)
    }

    /// Runs `completion` with a valid access token + account id, refreshing the
    /// token first when it is expired or about to expire.
    func withFreshToken(completion: @escaping (Result<(access: String, accountID: String), Error>) -> Void) {
        guard let creds = loadCredentials() else {
            completion(.failure(AuthError(message: "Not signed in with ChatGPT")))
            return
        }
        // Refresh when within 5 minutes of expiry.
        if creds.expiresAt - Date().timeIntervalSince1970 > 300 {
            completion(.success((creds.access, creds.accountID)))
            return
        }
        requestToken(params: [
            "grant_type": "refresh_token",
            "refresh_token": creds.refresh,
            "client_id": Self.clientID,
        ]) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let new):
                self?.storeCredentials(new)
                completion(.success((new.access, new.accountID)))
            }
        }
    }

    // MARK: - Callback server (localhost:1455)

    private func startCallbackServer() throws {
        // Bind to loopback only: the default binds to all interfaces, which
        // would expose the OAuth callback server to the local network.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: Self.callbackPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                self.handleHTTPRequest(request, on: connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func stopCallbackServer() {
        listener?.cancel()
        listener = nil
    }

    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        // "GET /auth/callback?code=…&state=… HTTP/1.1"
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let comps = URLComponents(string: String(parts[1])),
              comps.path == "/auth/callback" else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        let code = comps.queryItems?.first { $0.name == "code" }?.value
        let state = comps.queryItems?.first { $0.name == "state" }?.value

        guard let code, state == pendingState else {
            respond(connection, status: "400 Bad Request",
                    body: "<h2>Sign-in failed</h2><p>Missing code or state mismatch. Return to Mac Whisper and try again.</p>")
            finishSignIn(.failure(AuthError(message: "OAuth callback missing code or state mismatch")))
            return
        }
        respond(connection, status: "200 OK",
                body: "<h2>Signed in to Mac Whisper</h2><p>You can close this window and return to the app.</p>")

        let verifier = pendingVerifier ?? ""
        requestToken(params: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": Self.redirectURI,
        ]) { [weak self] result in
            switch result {
            case .failure(let error):
                self?.finishSignIn(.failure(error))
            case .success(let creds):
                self?.storeCredentials(creds)
                self?.finishSignIn(.success(()))
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:80px\">\(body)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finishSignIn(_ result: Result<Void, Error>) {
        stopCallbackServer()
        pendingVerifier = nil
        pendingState = nil
        let completion = signInCompletion
        signInCompletion = nil
        completion?(result)
    }

    // MARK: - Token endpoint

    private func requestToken(params: [String: String], completion: @escaping (Result<Credentials, Error>) -> Void) {
        var req = URLRequest(url: URL(string: Self.tokenURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(AuthError(message: "Token request failed (HTTP \(status)): \(detail)")))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String,
                  let refresh = json["refresh_token"] as? String,
                  let expiresIn = json["expires_in"] as? TimeInterval else {
                completion(.failure(AuthError(message: "Token response missing fields")))
                return
            }
            guard let accountID = Self.chatGPTAccountID(fromJWT: access) else {
                completion(.failure(AuthError(message: "Could not extract ChatGPT account id from token")))
                return
            }
            completion(.success(Credentials(
                access: access,
                refresh: refresh,
                expiresAt: Date().timeIntervalSince1970 + expiresIn,
                accountID: accountID
            )))
        }.resume()
    }

    /// The ChatGPT account id lives in the access token's
    /// `https://api.openai.com/auth` claim.
    private static func chatGPTAccountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        return auth?["chatgpt_account_id"] as? String
    }

    // MARK: - Credential storage

    private func loadCredentials() -> Credentials? {
        guard let data = try? Data(contentsOf: Self.credentialsURL) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private func storeCredentials(_ creds: Credentials) {
        let url = Self.credentialsURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(creds) else { return }
        try? data.write(to: url, options: .atomic)
        // The token is password-equivalent for the ChatGPT account: owner-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Encoding helpers

    private static func randomURLSafeString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Fetches and caches the Codex CLI system prompt that the ChatGPT backend
/// expects in the `instructions` field. The backend validates this prompt, so
/// requests are rejected without it. Cached in ~/.config/macwhisper/cache/.
enum CodexInstructions {

    private static var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macwhisper/cache")
    }

    /// Prompt file in openai/codex (codex-rs/core/) for a given model.
    private static func promptFile(for model: String) -> String {
        let m = model.lowercased()
        if m.contains("gpt-5.2-codex") { return "gpt-5.2-codex_prompt.md" }
        if m.contains("codex-max") { return "gpt-5.1-codex-max_prompt.md" }
        if m.contains("codex") { return "gpt_5_codex_prompt.md" }
        if m.contains("gpt-5.2") { return "gpt_5_2_prompt.md" }
        return "gpt_5_1_prompt.md"
    }

    static func fetch(for model: String, completion: @escaping (String?) -> Void) {
        let file = promptFile(for: model)
        let cacheURL = cacheDir.appendingPathComponent(file)
        if let cached = try? String(contentsOf: cacheURL, encoding: .utf8), !cached.isEmpty {
            completion(cached)
            return
        }
        // Resolve the latest release tag, then fetch the prompt from that tag.
        var tagReq = URLRequest(url: URL(string: "https://api.github.com/repos/openai/codex/releases/latest")!)
        tagReq.timeoutInterval = 15
        URLSession.shared.dataTask(with: tagReq) { data, _, _ in
            let tag = data
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["tag_name"] as? String } ?? "main"
            let rawURL = URL(string: "https://raw.githubusercontent.com/openai/codex/\(tag)/codex-rs/core/\(file)")!
            URLSession.shared.dataTask(with: rawURL) { data, response, _ in
                guard let data,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                    completion(nil)
                    return
                }
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
                completion(text)
            }.resume()
        }.resume()
    }
}
