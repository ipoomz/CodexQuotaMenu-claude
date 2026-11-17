import Foundation
import Security

/// Reads the Claude Code OAuth token from the user's Keychain (in memory only)
/// and asks Anthropic's usage endpoint for the 5-hour and weekly limits.
final class ClaudeUsageReader {
    private static let keychainService = "Claude Code-credentials"
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Uses the claude.ai cookie when one is saved (it lasts weeks), and falls
    /// back to the Claude Code OAuth token otherwise or when the cookie fails.
    func read(
        cookie: String?,
        previous: ClaudeSnapshot?,
        completion: @escaping (ClaudeSnapshot) -> Void
    ) {
        guard let cookie, let filtered = ClaudeUsageParser.filteredCookieHeader(from: cookie) else {
            readOAuth(previous: previous, completion: completion)
            return
        }
        readWeb(cookie: filtered) { [weak self] result in
            switch result {
            case .success(let snapshot):
                completion(snapshot)
            case .failure(let webError):
                self?.readOAuth(previous: previous) { oauthSnapshot in
                    if oauthSnapshot.errorMessage == nil {
                        completion(oauthSnapshot)
                    } else {
                        completion(.failure(webError, previous: previous))
                    }
                }
            }
        }
    }

    private let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private func webRequest(path: String, cookie: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://claude.ai\(path)")!)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        return request
    }

    private func perform(
        _ request: URLRequest,
        completion: @escaping (Result<Data, ClaudeUsageError>) -> Void
    ) {
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network("No HTTP response")))
                return
            }
            guard (200...299).contains(http.statusCode), let data else {
                switch http.statusCode {
                case 401, 403:
                    completion(.failure(.cookieInvalid))
                case 429:
                    let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    completion(.failure(.rateLimited(retryAfter: retry)))
                default:
                    completion(.failure(.api(http.statusCode)))
                }
                return
            }
            completion(.success(data))
        }.resume()
    }

    private func readWeb(
        cookie: String,
        completion: @escaping (Result<ClaudeSnapshot, ClaudeUsageError>) -> Void
    ) {
        perform(webRequest(path: "/api/organizations", cookie: cookie)) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                guard let orgID = ClaudeUsageParser.parseOrganizationID(data) else {
                    completion(.failure(.parseFailed))
                    return
                }
                self.perform(self.webRequest(path: "/api/organizations/\(orgID)/usage", cookie: cookie)) { usageResult in
                    switch usageResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let usageData):
                        do {
                            var snapshot = try ClaudeUsageParser.parseUsage(usageData, planType: nil)
                            snapshot.source = "claude.ai cookie"
                            completion(.success(snapshot))
                        } catch {
                            completion(.failure(.parseFailed))
                        }
                    }
                }
            }
        }
    }

    private func readOAuth(previous: ClaudeSnapshot?, completion: @escaping (ClaudeSnapshot) -> Void) {
        guard let credentials = Self.loadCredentials() else {
            completion(.failure(ClaudeUsageError.credentialsMissing, previous: previous))
            return
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuotaMenu/2.5", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(ClaudeUsageError.network(error.localizedDescription), previous: previous))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(ClaudeUsageError.network("No HTTP response"), previous: previous))
                return
            }
            guard (200...299).contains(http.statusCode), let data else {
                let failure: ClaudeUsageError
                switch http.statusCode {
                case 401, 403:
                    failure = .unauthorized
                case 429:
                    let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    failure = .rateLimited(retryAfter: retry)
                default:
                    failure = .api(http.statusCode)
                }
                completion(.failure(failure, previous: previous))
                return
            }
            do {
                completion(try ClaudeUsageParser.parseUsage(data, planType: credentials.planType))
            } catch {
                completion(.failure(error, previous: previous))
            }
        }.resume()
    }

    private static func loadCredentials() -> (accessToken: String, planType: String?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return ClaudeUsageParser.parseCredentials(data)
    }
}
