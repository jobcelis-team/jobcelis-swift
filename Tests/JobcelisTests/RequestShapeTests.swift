import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Jobcelis

/// Checks the paths and bodies the client sends match what the API reads.
final class RequestShapeTests: XCTestCase {
    private func makeClient(body: String = "{}") -> JobcelisClient {
        MockURLProtocol.reset([.status(200, body: body)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return JobcelisClient(
            apiKey: "test_key",
            baseURL: "https://api.test",
            session: URLSession(configuration: configuration),
            maxRetries: 0
        )
    }

    private var lastRequest: MockURLProtocol.Recorded? { MockURLProtocol.requests.last }

    func testRestrictProcessingSendsThePassword() async throws {
        let client = makeClient()
        _ = try await client.restrictProcessing(password: "secret")
        XCTAssertEqual(lastRequest?.json()["password"] as? String, "secret")
    }

    func testStatusReadsTheJSONHealthEndpoint() async throws {
        let client = makeClient(body: #"{"status":"healthy"}"#)
        let status = try await client.status()
        XCTAssertEqual(status["status"] as? String, "healthy")
        XCTAssertEqual(lastRequest?.request.url?.absoluteString, "https://api.test/health")
    }

    func testAddMemberDefaultsToViewer() async throws {
        let client = makeClient()
        _ = try await client.addMember("proj_1", email: "a@example.com")
        XCTAssertEqual(lastRequest?.json()["role"] as? String, "viewer")
    }

    func testTestPipelineWrapsThePayload() async throws {
        let client = makeClient()
        _ = try await client.testPipeline("pipe_1", payload: ["id": "1"])
        let payload = lastRequest?.json()["payload"] as? [String: Any]
        XCTAssertEqual(payload?["id"] as? String, "1")
    }

    func testUpdateRetentionPolicyWrapsThePolicy() async throws {
        let client = makeClient()
        _ = try await client.updateRetentionPolicy(["events_days": 30])
        let policy = lastRequest?.json()["retention_policy"] as? [String: Any]
        XCTAssertEqual(policy?["events_days"] as? Int, 30)
    }

    func testCreatePipelineSendsTheWebhookId() async throws {
        let client = makeClient()
        _ = try await client.createPipeline(name: "p", topics: ["a"], steps: [], webhookId: "wh_1")
        XCTAssertEqual(lastRequest?.json()["webhook_id"] as? String, "wh_1")
    }

    func testPathParametersArePercentEncoded() async throws {
        let client = makeClient()
        _ = try await client.getEvent("a/b?c")
        XCTAssertEqual(lastRequest?.request.url?.absoluteString, "https://api.test/api/v1/events/a%2Fb%3Fc")
    }
}
