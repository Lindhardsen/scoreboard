import XCTest
@testable import ScoreboardWatch

final class ScoreboardClientTests: XCTestCase {
    private let credentials = Credentials(server: URL(string: "https://example.test")!, username: "jan", token: "tok")

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func client() -> ScoreboardClient {
        ScoreboardClient(transport: { try StubProtocol.respond($0) })
    }

    func testNormalizesServerURL() {
        XCTAssertEqual(ServerURL.normalize("volley.lindhardsen.org/"), URL(string: "https://volley.lindhardsen.org"))
        XCTAssertEqual(ServerURL.normalize("  https://volley.lindhardsen.org  "), URL(string: "https://volley.lindhardsen.org"))
        XCTAssertEqual(ServerURL.normalize("http://10.0.0.5:8081"), URL(string: "http://10.0.0.5:8081"))
        XCTAssertNil(ServerURL.normalize(""))
        XCTAssertNil(ServerURL.normalize("   "))
    }

    func testFormEncodingEscapesReservedCharacters() {
        let body = String(decoding: FormBody.encode([("a", "x&y=z+1 ö"), ("b", "<div/>")]), as: UTF8.self)
        XCTAssertEqual(body, "a=x%26y%3Dz%2B1%20%C3%B6&b=%3Cdiv%2F%3E")
    }

    func testFetchTokenMapsStatuses() async {
        let server = credentials.server
        for (status, expected) in [(401, ClientError.wrongPassword), (429, .rateLimited), (404, .unknownUser), (500, .server(500))] {
            StubProtocol.handler = { _ in (status, [:], Data()) }
            do {
                _ = try await client().fetchToken(server: server, username: "jan", password: "pw")
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? ClientError, expected)
            }
        }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/jan/api/token")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, [:], Data(#"{"token":"tok-123"}"#.utf8))
        }
        let token = try? await client().fetchToken(server: server, username: "jan", password: "pw")
        XCTAssertEqual(token, "tok-123")
    }

    func testUploadSendsFormAndReadsScraperHeader() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/jan/upload.php")
            let body = String(decoding: request.bodyData, as: UTF8.self)
            XCTAssertTrue(body.contains("token=tok"), body)
            XCTAssertTrue(body.contains("filename=scoreboard.xml"), body)
            XCTAssertTrue(body.contains("filedata=%3Cdiv"), body)
            return (200, ["X-Scraper-Running": "1"], Data("OK".utf8))
        }
        let result = try await client().upload(.empty, credentials)
        XCTAssertEqual(result, UploadResult(scraperRunning: true))

        StubProtocol.handler = { _ in (200, [:], Data("OK".utf8)) }
        let quiet = try await client().upload(.empty, credentials)
        XCTAssertEqual(quiet, UploadResult(scraperRunning: false))
    }

    func testUploadForbidden() async {
        StubProtocol.handler = { _ in (403, [:], Data()) }
        do {
            _ = try await client().upload(.empty, credentials)
            XCTFail("expected forbidden")
        } catch {
            XCTAssertEqual(error as? ClientError, .forbidden)
        }
    }

    func testFetchScoreboardParsesAndTreats404AsMissing() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/jan/scoreboard.xml")
            return (200, [:], Data(ScoreboardXML.serialize(.empty).utf8))
        }
        let board = try await client().fetchScoreboard(credentials)
        XCTAssertEqual(board, .empty)
        StubProtocol.handler = { _ in (404, [:], Data()) }
        let missing = try await client().fetchScoreboard(credentials)
        XCTAssertNil(missing)
    }
}

/// Scripted HTTP responses for ScoreboardClient's transport.
enum StubProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    static func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard let handler else { throw URLError(.notConnectedToInternet) }
        let (status, headers, data) = handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

extension URLRequest {
    /// URLSession hands protocols the body as a stream.
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
