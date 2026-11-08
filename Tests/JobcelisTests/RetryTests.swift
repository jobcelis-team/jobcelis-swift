import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Jobcelis

/// Answers requests with scripted replies (the last one repeats) and records them.
final class MockURLProtocol: URLProtocol {
    enum Reply {
        case status(Int, headers: [String: String] = [:], body: String = #"{"error":"status"}"#)
        case networkError
    }

    struct Recorded {
        let request: URLRequest
        let body: Data?

        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }

        func json() -> [String: Any] {
            guard let body = body, let object = try? JSONSerialization.jsonObject(with: body) else { return [:] }
            return object as? [String: Any] ?? [:]
        }
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var recorded: [Recorded] = []

    static func reset(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies
        recorded = []
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        Self.lock.lock()
        Self.recorded.append(Recorded(request: request, body: body))
        let index = min(Self.recorded.count, Self.replies.count) - 1
        let reply = Self.replies[index]
        Self.lock.unlock()

        switch reply {
        case let .status(code, headers, text):
            var fields = headers
            fields["Content-Type"] = "application/json"
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: fields)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .networkError:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
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

final class RetryTests: XCTestCase {
    private func makeClient(_ replies: [MockURLProtocol.Reply], maxRetries: Int = JobcelisClient.defaultMaxRetries) -> JobcelisClient {
        MockURLProtocol.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = JobcelisClient(
            apiKey: "test_key",
            baseURL: "https://api.test",
            session: URLSession(configuration: configuration),
            maxRetries: maxRetries
        )
        client.retryBaseDelay = 0.001
        return client
    }

    private func assertAPIError(_ status: Int, file: StaticString = #filePath, line: UInt = #line, _ call: () async throws -> Void) async {
        do {
            try await call()
            XCTFail("expected HTTP \(status)", file: file, line: line)
        } catch let error as JobcelisError {
            XCTAssertEqual(error.statusCode, status, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testGetRetries503UntilItSucceeds() async throws {
        let client = makeClient([.status(503), .status(503), .status(200, body: #"{"id":"evt_1"}"#)])
        let event = try await client.getEvent("evt_1")
        XCTAssertEqual(event["id"] as? String, "evt_1")
        XCTAssertEqual(MockURLProtocol.requests.count, 3)
    }

    func testRetries429AfterRetryAfter() async throws {
        let client = makeClient([.status(429, headers: ["Retry-After": "0"]), .status(200, body: #"{"status":"ok"}"#)])
        let started = Date()
        let health = try await client.health()
        XCTAssertEqual(health["status"] as? String, "ok")
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testSendEventKeepsTheSameIdempotencyKeyOnEveryAttempt() async throws {
        let client = makeClient([.status(502), .networkError, .status(202, body: #"{"event_id":"evt_1"}"#)])
        let result = try await client.sendEvent(topic: "order.created", payload: ["id": 1])
        XCTAssertEqual(result["event_id"] as? String, "evt_1")

        let requests = MockURLProtocol.requests
        XCTAssertEqual(requests.count, 3)
        let key = try XCTUnwrap(requests[0].header("X-Idempotency-Key"))
        XCTAssertNotNil(UUID(uuidString: key))
        XCTAssertEqual(Array(key)[14], "4")
        XCTAssertTrue(requests.allSatisfy { $0.header("X-Idempotency-Key") == key })
    }

    func testSendEventKeepsACallerSuppliedIdempotencyKey() async throws {
        let client = makeClient([.status(503), .status(202, body: #"{"event_id":"evt_1"}"#)])
        _ = try await client.sendEvent(topic: "order.created", payload: [:], idempotencyKey: "my-key")
        let requests = MockURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.header("X-Idempotency-Key") == "my-key" })
    }

    func testSendEventsAddsMissingIdempotencyKeys() async throws {
        let client = makeClient([.status(503), .status(202, body: #"{"accepted":2}"#)])
        _ = try await client.sendEvents([
            ["topic": "a", "payload": [:]],
            ["topic": "b", "payload": [:], "idempotency_key": "existing"],
        ])

        let requests = MockURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        let keys = requests.map { request -> [String?] in
            let events = request.json()["events"] as? [[String: Any]] ?? []
            return events.map { $0["idempotency_key"] as? String }
        }
        let generated = try XCTUnwrap(keys[0].first ?? nil)
        XCTAssertNotNil(UUID(uuidString: generated))
        XCTAssertEqual(keys[0], [generated, "existing"])
        XCTAssertEqual(keys[1], keys[0], "retries send the same keys")
    }

    func testPostWithoutIdempotencyKeyIsNotRetriedOnNetworkError() async {
        let client = makeClient([.networkError, .status(201, body: #"{"id":"wh_1"}"#)])
        do {
            _ = try await client.createWebhook(url: "https://example.com/hook")
            XCTFail("expected a network error")
        } catch {
            XCTAssertTrue(error is URLError, "\(error)")
        }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testPostWithoutIdempotencyKeyIsRetriedOn503() async throws {
        let client = makeClient([.status(503), .status(201, body: #"{"id":"wh_1"}"#)])
        let webhook = try await client.createWebhook(url: "https://example.com/hook")
        XCTAssertEqual(webhook["id"] as? String, "wh_1")
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testGetIsRetriedOnNetworkError() async throws {
        let client = makeClient([.networkError, .status(200, body: #"{"id":"evt_1"}"#)])
        let event = try await client.getEvent("evt_1")
        XCTAssertEqual(event["id"] as? String, "evt_1")
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testZeroMaxRetriesMakesOneRequest() async {
        let client = makeClient([.status(503)], maxRetries: 0)
        await assertAPIError(503) { _ = try await client.getEvent("evt_1") }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testGivesUpAfterMaxRetriesWithTheLastError() async {
        let client = makeClient([.status(503)], maxRetries: 2)
        await assertAPIError(503) { _ = try await client.getEvent("evt_1") }
        XCTAssertEqual(MockURLProtocol.requests.count, 3)
    }

    func testNonRetryableStatusesAreNotRetried() async {
        for code in [400, 404, 500] {
            let client = makeClient([.status(code), .status(200, body: "{}")])
            await assertAPIError(code) { _ = try await client.getEvent("evt_1") }
            XCTAssertEqual(MockURLProtocol.requests.count, 1, "status \(code)")
        }
    }

    func testDefaultMaxRetries() {
        XCTAssertEqual(JobcelisClient(apiKey: "k").maxRetries, 6)
    }

    func testBackoffDoublesUpTo30SecondsWithJitter() {
        let client = JobcelisClient(apiKey: "k")
        for (attempt, seconds) in [(1, 1.0), (2, 2.0), (3, 4.0), (4, 8.0), (5, 16.0), (6, 30.0), (7, 30.0), (40, 30.0)] {
            let delay = client.backoffDelay(attempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, seconds * 0.8 - 1e-9, "attempt \(attempt)")
            XCTAssertLessThanOrEqual(delay, seconds * 1.2 + 1e-9, "attempt \(attempt)")
        }
    }

    func testParsesRetryAfter() {
        XCTAssertEqual(JobcelisClient.parseRetryAfter("0"), 0)
        XCTAssertEqual(JobcelisClient.parseRetryAfter("5"), 5)
        XCTAssertEqual(JobcelisClient.parseRetryAfter("120"), 60)
        XCTAssertNil(JobcelisClient.parseRetryAfter("soon"))
        XCTAssertNil(JobcelisClient.parseRetryAfter(nil))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: Date().addingTimeInterval(10))
        let delay = try? XCTUnwrap(JobcelisClient.parseRetryAfter(date))
        XCTAssertNotNil(delay)
        XCTAssertGreaterThan(delay ?? 0, 0)
        XCTAssertLessThanOrEqual(delay ?? 100, 10)
    }
}
