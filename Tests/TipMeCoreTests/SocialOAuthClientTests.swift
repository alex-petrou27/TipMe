import XCTest
@testable import TipMeCore

/// `OAuthCallbackResult` is the contract between the registry's
/// `/v1/oauth/{platform}/callback` redirect and the app's
/// `ASWebAuthenticationSession` completion handler — the two sides are in
/// different languages and different repositories, so nothing else catches a
/// drift between what one emits and what the other expects.
final class SocialOAuthClientTests: XCTestCase {

    func testSuccessCarriesSessionID() throws {
        let url = try XCTUnwrap(URL(string: "tipme://oauth-complete?platform=instagram&status=success&username=creator&session_id=abc123"))
        let result = try XCTUnwrap(OAuthCallbackResult(url: url))
        XCTAssertEqual(result.platform, .instagram)
        XCTAssertEqual(result.status, .success(sessionID: "abc123"))
    }

    func testFailureCarriesReason() throws {
        let url = try XCTUnwrap(URL(string: "tipme://oauth-complete?platform=tiktok&status=error&reason=account_mismatch"))
        let result = try XCTUnwrap(OAuthCallbackResult(url: url))
        XCTAssertEqual(result.platform, .tiktok)
        XCTAssertEqual(result.status, .failure(reason: "account_mismatch"))
    }

    /// A malformed or absent reason must still surface as *some* failure
    /// rather than being silently swallowed or crashing the parse.
    func testFailureWithoutReasonFallsBackToUnknown() throws {
        let url = try XCTUnwrap(URL(string: "tipme://oauth-complete?platform=tiktok&status=denied"))
        let result = try XCTUnwrap(OAuthCallbackResult(url: url))
        XCTAssertEqual(result.status, .failure(reason: "unknown_error"))
    }

    func testSuccessWithoutSessionIDFailsToParse() throws {
        let url = try XCTUnwrap(URL(string: "tipme://oauth-complete?platform=instagram&status=success"))
        XCTAssertNil(OAuthCallbackResult(url: url))
    }

    func testUnknownPlatformFailsToParse() throws {
        let url = try XCTUnwrap(URL(string: "tipme://oauth-complete?platform=facebook&status=success&session_id=abc"))
        XCTAssertNil(OAuthCallbackResult(url: url))
    }

    func testMissingPlatformFailsToParse() throws {
        let url = try XCTUnwrap(URL(string: "tipme://oauth-complete?status=success&session_id=abc"))
        XCTAssertNil(OAuthCallbackResult(url: url))
    }
}
