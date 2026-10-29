import Foundation

enum ClientError: Error, Equatable {
    case invalidServer
    case unreachable
    case wrongPassword
    case rateLimited
    case unknownUser
    case forbidden
    case badResponse
    case server(Int)
}

struct UploadResult: Equatable, Sendable {
    var scraperRunning: Bool
}

protocol ScoreboardAPI: Sendable {
    func fetchToken(server: URL, username: String, password: String) async throws -> String
    /// nil when the user has no scoreboard yet.
    func fetchScoreboard(_ c: Credentials) async throws -> Scoreboard?
    func upload(_ board: Scoreboard, _ c: Credentials) async throws -> UploadResult
}

enum ServerURL {
    /// Accepts what people type: adds https:// when no scheme is given and drops trailing slashes.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }
}

enum FormBody {
    private static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ fields: [(String, String)]) -> Data {
        let pairs = fields.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

/// Talks to the same endpoints as html/scoreboard.js, plus the token endpoint.
struct ScoreboardClient: ScoreboardAPI {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Injectable because watchOS routes URLSession through a system proxy that ignores custom URLProtocols.
    var transport: Transport = { try await URLSession.shared.data(for: $0) }

    func fetchToken(server: URL, username: String, password: String) async throws -> String {
        let (data, response) = try await send(post(server.appending(path: "\(username)/api/token"),
                                                   [("password", password)]))
        switch response.statusCode {
        case 200:
            struct TokenResponse: Decodable { let token: String }
            guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data).token, !token.isEmpty
            else { throw ClientError.badResponse }
            return token
        case 401: throw ClientError.wrongPassword
        case 404: throw ClientError.unknownUser
        case 429: throw ClientError.rateLimited
        default: throw ClientError.server(response.statusCode)
        }
    }

    func fetchScoreboard(_ c: Credentials) async throws -> Scoreboard? {
        var components = URLComponents(url: c.server.appending(path: "\(c.username)/scoreboard.xml"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970)))]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            guard let board = try? ScoreboardXML.parse(data) else { throw ClientError.badResponse }
            return board
        case 404: return nil
        default: throw ClientError.server(response.statusCode)
        }
    }

    func upload(_ board: Scoreboard, _ c: Credentials) async throws -> UploadResult {
        let (_, response) = try await send(post(c.server.appending(path: "\(c.username)/upload.php"), [
            ("token", c.token),
            ("filename", "scoreboard.xml"),
            ("filedata", ScoreboardXML.serialize(board)),
        ]))
        switch response.statusCode {
        case 200: return UploadResult(scraperRunning: response.value(forHTTPHeaderField: "X-Scraper-Running") == "1")
        case 403: throw ClientError.forbidden
        default: throw ClientError.server(response.statusCode)
        }
    }

    private func post(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormBody.encode(fields)
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = 10
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
            return (data, http)
        } catch is URLError {
            throw ClientError.unreachable
        }
    }
}
