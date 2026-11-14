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

    func read(previous: ClaudeSnapshot?, completion: @escaping (ClaudeSnapshot) -> Void) {
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
