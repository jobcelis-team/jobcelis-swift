import XCTest
@testable import Jobcelis

final class WebhookVerifierTests: XCTestCase {
    // Reference signature computed with OpenSSL: HMAC-SHA256, Base64 without padding
    private let secret = "whsec_test"
    private let body = #"{"topic":"order.created"}"#
    private let signature = "sha256=KLzSz4jfY3SIZDJngpuNBRF5E+T5gBdTyf4dAqEaxzg"

    func testAcceptsAValidSignature() {
        XCTAssertTrue(WebhookVerifier.verify(secret: secret, body: body, signature: signature))
    }

    func testRejectsATamperedBody() {
        XCTAssertFalse(WebhookVerifier.verify(secret: secret, body: #"{"topic":"order.paid"}"#, signature: signature))
    }

    func testRejectsTheWrongSecret() {
        XCTAssertFalse(WebhookVerifier.verify(secret: "whsec_other", body: body, signature: signature))
    }

    func testRejectsAMalformedHeader() {
        XCTAssertFalse(WebhookVerifier.verify(secret: secret, body: body, signature: "KLzSz4jfY3SIZDJngpuNBRF5E"))
        XCTAssertFalse(WebhookVerifier.verify(secret: secret, body: body, signature: "sha256="))
    }

    func testClientBuildsOnEveryPlatform() {
        XCTAssertNotNil(JobcelisClient(apiKey: "test"))
    }
}
