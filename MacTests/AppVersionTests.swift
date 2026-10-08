import XCTest

final class AppVersionTests: XCTestCase {
    func testForkVersionShowsFullTagAndIPACompatibleNumber() {
        let v = AppVersion(info: [
            "CFBundleShortVersionString": "1.25.17",
            "CFBundleVersion": "21",
            "OpenAirDisplayReleaseTag": "v1.25.0-air.17",
            "OpenAirDisplayUpstreamVersion": "1.25.0"
        ])
        XCTAssertEqual(v.display, "v1.25.0-air.17 (build 21)")
        XCTAssertEqual(v.marketing, "1.25.17")
        XCTAssertEqual(v.upstreamDisplay, "1.25.0")
    }
    func testDeveloperAndLegacyBundlesHaveSensibleFallback() {
        XCTAssertEqual(AppVersion(info: [
            "CFBundleShortVersionString": "0.0.0",
            "CFBundleVersion": "1",
            "OpenAirDisplayReleaseTag": "dev"
        ]).display, "v0.0.0 (build 1)")
        XCTAssertEqual(AppVersion(info: [
            "CFBundleShortVersionString": "1.25.0",
            "CFBundleVersion": "20"
        ]).display, "v1.25.0 (build 20)")
    }
}
