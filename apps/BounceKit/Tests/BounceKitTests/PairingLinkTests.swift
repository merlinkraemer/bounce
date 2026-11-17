import XCTest
@testable import BounceKit

final class PairingLinkTests: XCTestCase {
    private let macID = UUID(uuidString: "9B2C0E7A-4D61-4C3B-8F50-1A2B3C4D5E6F")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLink(lane: PairingLane = .production, name: String = "Alex\u{2019}s MacBook Pro") -> PairingLink {
        PairingLink(
            macDeviceID: macID,
            macName: name,
            token: PairingToken.generate(),
            expiresAt: now.addingTimeInterval(300),
            lane: lane
        )
    }

    func testTokenIsBase64URLWith128Bits() {
        let token = PairingToken.generate()
        XCTAssertTrue(PairingToken.isWellFormed(token))
        XCTAssertEqual(token.count, 22)
        XCTAssertFalse(token.contains("="))
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        let padded = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
        XCTAssertEqual(Data(base64Encoded: padded)?.count, 16)
    }

    func testTokensAreUnique() {
        XCTAssertEqual(Set((0..<200).map { _ in PairingToken.generate() }).count, 200)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(PairingToken.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(PairingToken.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(PairingToken.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(PairingToken.constantTimeEquals("", "a"))
        XCTAssertTrue(PairingToken.constantTimeEquals("", ""))
    }

    func testIssuerAcceptsCurrentTokenOnce() {
        var issuer = PairingTokenIssuer(now: now)
        let token = issuer.token
        XCTAssertTrue(issuer.consume(token, now: now.addingTimeInterval(10)))
        XCTAssertFalse(issuer.consume(token, now: now.addingTimeInterval(11)))
        XCTAssertNotEqual(issuer.token, token)
    }

    func testIssuerRejectsExpiredToken() {
        var issuer = PairingTokenIssuer(lifetime: 300, now: now)
        let token = issuer.token
        XCTAssertFalse(issuer.consume(token, now: now.addingTimeInterval(300)))
        XCTAssertFalse(issuer.consume(token, now: now.addingTimeInterval(301)))
    }

    func testIssuerRejectsWrongTokenWithoutRotating() {
        var issuer = PairingTokenIssuer(now: now)
        let token = issuer.token
        XCTAssertFalse(issuer.consume(PairingToken.generate(), now: now))
        XCTAssertFalse(issuer.consume("", now: now))
        XCTAssertEqual(issuer.token, token)
        XCTAssertTrue(issuer.consume(token, now: now))
    }

    func testIssuerRotatesOnlyWhenExpired() {
        var issuer = PairingTokenIssuer(lifetime: 300, now: now)
        let first = issuer.token
        XCTAssertFalse(issuer.rotateIfExpired(now: now.addingTimeInterval(299)))
        XCTAssertEqual(issuer.token, first)
        XCTAssertTrue(issuer.rotateIfExpired(now: now.addingTimeInterval(300)))
        XCTAssertNotEqual(issuer.token, first)
        XCTAssertEqual(issuer.expiresAt, now.addingTimeInterval(600))
    }

    func testBuildThenParseRoundTrip() throws {
        let link = makeLink()
        let parsed = try PairingLink.parse(link.url, lane: .production)
        XCTAssertEqual(parsed, link)
    }

    func testProductionAndDevelopmentSchemes() {
        XCTAssertEqual(makeLink(lane: .production).url.scheme, "bounce")
        XCTAssertEqual(makeLink(lane: .development).url.scheme, "bounce-dev")
        XCTAssertEqual(makeLink().url.host, "pair")
    }

    func testDevLinkRoundTrip() throws {
        let link = makeLink(lane: .development)
        XCTAssertEqual(try PairingLink.parse(link.url, lane: .development), link)
    }

    func testLaneMismatchIsRejectedBothWays() {
        XCTAssertThrowsError(try PairingLink.parse(makeLink(lane: .development).url, lane: .production)) {
            XCTAssertEqual($0 as? PairingLinkError, .laneMismatch)
        }
        XCTAssertThrowsError(try PairingLink.parse(makeLink(lane: .production).url, lane: .development)) {
            XCTAssertEqual($0 as? PairingLinkError, .laneMismatch)
        }
    }

    func testRejectsForeignSchemeAndHost() {
        XCTAssertThrowsError(try PairingLink.parse(URL(string: "https://example.com/pair?v=1")!, lane: .production)) {
            XCTAssertEqual($0 as? PairingLinkError, .notAPairingLink)
        }
        XCTAssertThrowsError(try PairingLink.parse(URL(string: "bounce://other?v=1")!, lane: .production)) {
            XCTAssertEqual($0 as? PairingLinkError, .notAPairingLink)
        }
    }

    func testRejectsUnsupportedVersion() {
        let url = URL(string: makeLink().url.absoluteString.replacingOccurrences(of: "v=1", with: "v=2"))!
        XCTAssertThrowsError(try PairingLink.parse(url, lane: .production)) {
            XCTAssertEqual($0 as? PairingLinkError, .unsupportedVersion(2))
        }
    }

    func testRejectsMalformedPayloads() {
        let good = makeLink().url.absoluteString
        let badToken = good.replacingOccurrences(of: "t=", with: "t=x")
        let badID = good.replacingOccurrences(of: "i=", with: "i=zz")
        let missingName = URL(string: "bounce://pair?v=1&i=\(macID.uuidString)&t=\(PairingToken.generate())&e=1")!
        for url in [URL(string: badToken)!, URL(string: badID)!, missingName, URL(string: "bounce://pair")!] {
            XCTAssertThrowsError(try PairingLink.parse(url, lane: .production)) {
                XCTAssertEqual($0 as? PairingLinkError, .malformed)
            }
        }
    }

    func testExpiry() {
        let link = makeLink()
        XCTAssertFalse(link.isExpired(at: now.addingTimeInterval(299)))
        XCTAssertTrue(link.isExpired(at: now.addingTimeInterval(300)))
    }

    func testPayloadStaysSmallEnoughForQR() {
        XCTAssertLessThan(makeLink().url.absoluteString.utf8.count, 160)
    }
}
