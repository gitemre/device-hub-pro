import XCTest
@testable import DeviceHubProKit

/// `LinkUri`, the model of `android.net.Uri`, against the AOSP sources each
/// case names (no device output).
final class LinkUriTests: XCTestCase {
    // MARK: - Decoding

    /// UriCodec.decode android-16.0.0_r1:77–176 (convertPlus false,
    /// throwOnFailure false).
    func testDecodingFollowsUriCodec() {
        XCTAssertEqual(LinkUri.decode("exa%6Dple.com"), "example.com")
        XCTAssertEqual(LinkUri.decode("m%C3%BCnchen"), "münchen")
        XCTAssertEqual(LinkUri.decode("a+b"), "a+b", "convertPlus is false")
        XCTAssertEqual(LinkUri.decode("h%0Ax"), "h\nx")
        XCTAssertEqual(LinkUri.decode("%E2%80%A8"), "\u{2028}")
        // Raw non-ASCII passes through.
        XCTAssertEqual(LinkUri.decode("ü%20ş"), "ü ş")
    }

    /// The quirks of the same code: a `%` cut short ends the decoding; a
    /// bad digit gives U+FFFD, then the byte of the digits read so far.
    func testDecodingQuirks() {
        XCTAssertEqual(LinkUri.decode("a%4"), "a\u{FFFD}")
        XCTAssertEqual(LinkUri.decode("a%"), "a\u{FFFD}")
        // `%4x`: x is not hex → U+FFFD, then the byte 0x04; then `b`, `A`.
        XCTAssertEqual(LinkUri.decode("a%4xb%41"), "a\u{FFFD}\u{4}bA")
        XCTAssertEqual(LinkUri.decode("%AZ"), "\u{FFFD}\n", "0x0A: a line feed without %0A")
        XCTAssertEqual(LinkUri.decode("%DZ"), "\u{FFFD}\r")
        XCTAssertEqual(LinkUri.decode("%Z1"), "\u{FFFD}\u{0}1")
        XCTAssertEqual(LinkUri.decode("%C3x"), "\u{FFFD}x", "a lone UTF-8 lead byte")
    }

    // MARK: - Hosts

    /// Uri.java android-16.0.0_r1:737–760 (the authority) and 1121–1175
    /// (the host), android-9.0.0_r1 (API 28) and android-7.0.0_r1 (API 27
    /// and older).
    func testTheHostRules() {
        let backslash = #"https://evil.example\@video.example.com/watch"#
        XCTAssertEqual(LinkUri.host(of: backslash), "evil.example", "`\\` ends the authority")
        XCTAssertEqual(LinkUri.host(of: backslash, rule: .api28), "evil.example")
        XCTAssertEqual(LinkUri.host(of: backslash, rule: .api27), "video.example.com")

        let userInfo = "https://a@b@c.example:80/x"
        XCTAssertEqual(LinkUri.host(of: userInfo), "c.example")
        XCTAssertEqual(LinkUri.host(of: userInfo, rule: .api28), "c.example")
        XCTAssertEqual(LinkUri.host(of: userInfo, rule: .api27), "b@c.example")

        let ipv6 = "http://[::1]:8080/x"
        XCTAssertEqual(LinkUri.host(of: ipv6), "[::1]")
        XCTAssertEqual(LinkUri.host(of: ipv6, rule: .api28), "[", "the first `:` after the last `@`")

        XCTAssertEqual(LinkUri.host(of: "https://example.com:port/"), "example.com:port", "not a port: digits only")
        XCTAssertEqual(LinkUri.host(of: "myapp:///path"), "")
        XCTAssertNil(LinkUri.host(of: "geo:41,29"))
        XCTAssertEqual(LinkUri.host(of: "https://www%2Evideo.example.com/"), "www.video.example.com")
        // A combining mark after `/` is one Swift character, but Android
        // still ends the authority at the `/`.
        XCTAssertEqual(LinkUri.host(of: "myapp://x/\u{301}y"), "x")
    }

    // MARK: - What am prints

    /// Uri.toSafeString android-16.0.0_r1:400–436 (the host, all schemes)
    /// and android-12.0.0_r1:399–440 (the decoded scheme-specific part for
    /// schemes other than http, https, ftp, rtsp, and the masked ones).
    func testTheEchoesThatHoldALineBreak() {
        XCTAssertEqual(LinkUri.safeStringEchoes(of: "https://example.com/a%0Ab"), [], "web links print only the host")
        XCTAssertEqual(LinkUri.safeStringEchoes(of: "myapp://x/y"), [])
        XCTAssertEqual(LinkUri.safeStringEchoes(of: "tel:1%0A2"), [], "masked with x")
        XCTAssertEqual(
            LinkUri.safeStringEchoes(of: "myapp://x/a%0Ab#f%0A"),
            ["dat=myapp://x/a\r\nb", "dat=myapp://x/a\nb"],
            "API 32 and older print the path and query of a custom scheme, not the fragment; the PTY form first"
        )
        let host = LinkUri.safeStringEchoes(of: "https://h%0Ax:8080/p")
        XCTAssertTrue(host.contains("dat=https://h\nx"), "\(host)")
        XCTAssertTrue(host.contains("dat=https://h\r\nx"), "\(host)")
        XCTAssertEqual(host, host.sorted { $0.utf16.count > $1.utf16.count }, "longest first")
        XCTAssertEqual(LinkUri.flattened("dat=a\nb\r\nc\u{2028}d"), "dat=a b  c d")
    }

    // MARK: - Domain names

    /// Patterns.DOMAIN_NAME android-16.0.0_r1:293–356.
    func testDomainNames() {
        for host in [
            "example.com", "video.example.com", "a_b.example.com", "münchen.de", "xn--mnchen-3ya.de",
            "site.xn--p1ai", "203.0.113.2", "198.51.100.255", "1.0.0.0", "a.bc",
        ] {
            XCTAssertTrue(LinkUri.isDomainName(host), host)
        }
        for host in [
            "localhost", "devicehubpro-verifier", "", "a.b", "example.com.", ".example.com", "-a.com", "a-.com",
            "*.example.com", "exa mple.com", "[::1]", "0.1.2.3", "256.1.1.1", "1.2.3", "1.2.3.4.5", "xn--p1ai",
            "a.c0m", "01.2.3.4", "01.2.3.4x",
        ] {
            XCTAssertFalse(LinkUri.isDomainName(host), host)
        }
        XCTAssertTrue(LinkUri.isDomainName(String(repeating: "a", count: 63) + ".com"))
        XCTAssertFalse(LinkUri.isDomainName(String(repeating: "a", count: 64) + ".com"))
    }
}
