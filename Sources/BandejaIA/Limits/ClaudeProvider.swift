import BandejaIACore
import Foundation
import Security

/// Operador que consulta limites remotamente. Detecção de uso fica no `ActivityClassifier`
/// e nos `LogIngestor`s; aqui só a parte de limites.
protocol UsageProvider {
    var id: ProviderID { get }
    func fetchLimits(now: Date) async throws -> [LimitSnapshot]
}

/// Limites oficiais do Claude com o token OAuth que o Claude Code grava no Keychain após `/login`.
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
        guard let snapshots = try await viaOAuth(now: now) else { throw Failure.noCredential }
        return snapshots
    }

    /// "Verificar agora": volta a ler o Keychain mesmo que tenha falhado (ou sido negado) há pouco.
    func allowKeychainRetry() {
        lock.lock()
        nextKeychainRead = .distantPast
        lock.unlock()
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

    static let credentialService = "Claude Code-credentials"

    /// Versões novas do Claude Code criam um item por pasta de configuração
    /// (`Claude Code-credentials-<hash>`). Lê do mais recente para o mais antigo até achar token válido.
    private static func readClaudeCodeCredential() -> (OSStatus, (accessToken: String, expiresAt: Date)?) {
        var lastStatus = errSecItemNotFound
        for service in credentialServices() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            lastStatus = SecItemCopyMatching(query as CFDictionary, &result)
            if lastStatus == errSecUserCanceled || lastStatus == errSecAuthFailed { return (lastStatus, nil) }
            guard lastStatus == errSecSuccess,
                  let data = result as? Data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty
            else { continue }
            let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            let expiresAt = Date(timeIntervalSince1970: expiresMs / 1000)
            if expiresAt > Date() { return (lastStatus, (token, expiresAt)) }
        }
        return (lastStatus, nil)
    }

    /// Nomes dos itens modificados nas últimas 24 h, do mais recente para o mais antigo.
    /// O Claude Code regrava o item ao renovar o token: item mais antigo que isso tem token vencido
    /// e nem é lido (cada leitura pode abrir um pedido de permissão do Keychain).
    /// Ler só atributos não abre o pedido.
    private static func credentialServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        let recent = Date().addingTimeInterval(-24 * 3600)
        return items
            .compactMap { item -> (String, Date)? in
                guard let service = item[kSecAttrService as String] as? String,
                      service.hasPrefix(credentialService),
                      let modified = item[kSecAttrModificationDate as String] as? Date,
                      modified > recent
                else { return nil }
                return (service, modified)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
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
