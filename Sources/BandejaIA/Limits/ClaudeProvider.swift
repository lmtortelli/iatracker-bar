import BandejaIACore
import Foundation
import Security

/// Operador que consulta limites remotamente. Detecção de uso fica no `ActivityClassifier`
/// e nos `LogIngestor`s; aqui só a parte de limites.
protocol UsageProvider {
    var id: ProviderID { get }
    func fetchLimits(now: Date) async throws -> [LimitSnapshot]
}

/// Limites oficiais do Claude. Credencial, na ordem escolhida em Preferências:
/// token OAuth do Claude Code (Keychain, item `Claude Code-credentials`) ou `sessionKey` do claude.ai.
/// O token nunca é renovado aqui (isso rotacionaria o refresh token do Claude Code) nem registrado em log.
final class ClaudeProvider: UsageProvider, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case noCredential
        case unauthorized
        case http(Int)
        case network
        case parse
    }

    let id = ProviderID.claude
    private let session: URLSession
    private let lock = NSLock()
    /// Token em memória até expirar, para não abrir o pedido do Keychain a cada consulta.
    private var cachedToken: (value: String, expiresAt: Date)?
    /// Sem token válido: só tenta ler o Keychain de novo depois disto.
    private var nextKeychainRead = Date.distantPast

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLimits(now: Date) async throws -> [LimitSnapshot] {
        let preferSessionKey = UserDefaults.standard.string(forKey: Preferences.Key.claudeCredentialSource)
            == ClaudeCredentialSource.sessionKey.rawValue
        let attempts: [() async throws -> [LimitSnapshot]?] = preferSessionKey
            ? [{ try await self.viaSessionKey(now: now) }, { try await self.viaOAuth(now: now) }]
            : [{ try await self.viaOAuth(now: now) }, { try await self.viaSessionKey(now: now) }]

        var lastError: Failure = .noCredential
        for attempt in attempts {
            do {
                if let snapshots = try await attempt() { return snapshots }
            } catch let failure as Failure {
                lastError = failure
            }
        }
        throw lastError
    }

    // MARK: OAuth do Claude Code

    private func viaOAuth(now: Date) async throws -> [LimitSnapshot]? {
        guard let token = oauthToken(now: now) else { return nil }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw Failure.network }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            return try await perform(request, now: now)
        } catch Failure.unauthorized {
            invalidateToken()
            throw Failure.unauthorized
        }
    }

    private func oauthToken(now: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedToken, cached.expiresAt > now.addingTimeInterval(60) {
            return cached.value
        }
        guard now >= nextKeychainRead else { return nil }

        // Pode abrir o pedido de permissão do macOS: este método roda fora da main thread.
        let (status, credential) = Self.readClaudeCodeCredential()
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            // Usuário negou o acesso: não pergunta de novo nesta execução.
            cachedToken = nil
            nextKeychainRead = .distantFuture
            return nil
        }
        guard let credential, !credential.accessToken.isEmpty, credential.expiresAt > now.addingTimeInterval(60) else {
            // Sem login no Claude Code ou token vencido (o próprio Claude Code renova ao ser usado).
            cachedToken = nil
            nextKeychainRead = now.addingTimeInterval(30 * 60)
            return nil
        }
        cachedToken = (credential.accessToken, credential.expiresAt)
        return credential.accessToken
    }

    private func invalidateToken() {
        lock.lock()
        cachedToken = nil
        nextKeychainRead = Date().addingTimeInterval(5 * 60)
        lock.unlock()
    }

    private static func readClaudeCodeCredential() -> (OSStatus, (accessToken: String, expiresAt: Date)?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return (status, nil) }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return (status, (token, Date(timeIntervalSince1970: expiresMs / 1000)))
    }

    // MARK: sessionKey do claude.ai

    private func viaSessionKey(now: Date) async throws -> [LimitSnapshot]? {
        guard let key = Keychain.read(account: Keychain.Account.claudeSessionKey), !key.isEmpty else { return nil }

        guard let orgsURL = URL(string: "https://claude.ai/api/organizations") else { throw Failure.network }
        var orgs = URLRequest(url: orgsURL, timeoutInterval: 15)
        orgs.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await load(orgs)
        try check(response)
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let org = list.first?["uuid"] as? String
        else { throw Failure.parse }

        guard let usageURL = URL(string: "https://claude.ai/api/organizations/\(org)/usage") else { throw Failure.parse }
        var usage = URLRequest(url: usageURL, timeoutInterval: 15)
        usage.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        return try await perform(usage, now: now)
    }

    // MARK: HTTP

    private func perform(_ request: URLRequest, now: Date) async throws -> [LimitSnapshot] {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BandejaIA", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await load(request)
        try check(response)
        do {
            return try ClaudeLimits.parse(data, fetchedAt: now)
        } catch {
            throw Failure.parse
        }
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw Failure.network
        }
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.network }
        switch http.statusCode {
        case 200: return
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.http(http.statusCode)
        }
    }
}
