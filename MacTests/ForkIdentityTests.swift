import Foundation
import XCTest

final class ForkIdentityTests: XCTestCase {
    func testUpdateDestinationsBelongToThisFork() {
        XCTAssertEqual(ForkUpdates.repositoryURL.absoluteString,
                       "https://github.com/nmt3325/openairdisplay")
        XCTAssertEqual(ForkUpdates.updateURL.absoluteString,
                       "https://github.com/nmt3325/openairdisplay/releases/latest")
        XCTAssertEqual(ForkUpdates.webURL, ForkUpdates.updateURL)
        XCTAssertEqual(ForkUpdates.iOSManifestURL.host, "raw.githubusercontent.com")
        XCTAssertEqual(ForkUpdates.iOSManifestURL.path,
                       "/nmt3325/openairdisplay/main/public/openairdisplay-ios-version.json")
    }

    func testMigrationKeepsPreferencesButNotUpstreamUpdaterState() {
        let nonce = UUID().uuidString
        let old = "test.openairdisplay.legacy.\(nonce)"
        let new = "test.openairdisplay.current.\(nonce)"
        let defaults = UserDefaults(suiteName: new)!
        defer {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
        defaults.setPersistentDomain([
            "quality": "best", "receiverFullscreen": false,
            "displaySerialBump.usb:first": 12,
            "SUFeedURL": "https://opendisplay.app/appcast.xml",
            "SULastCheckTime": 1, "NSWindow Frame panel": "old"
        ], forName: old)
        defaults.setPersistentDomain(["quality": "fast"], forName: new)
        XCTAssertTrue(ForkPreferences.migrate(from: old, to: new, defaults: defaults))
        let migrated = defaults.persistentDomain(forName: new)!
        XCTAssertEqual(migrated["quality"] as? String, "fast")
        XCTAssertEqual(migrated["receiverFullscreen"] as? Bool, false)
        XCTAssertEqual(migrated["displaySerialBump.usb:first"] as? Int, 12)
        XCTAssertNil(migrated["SUFeedURL"])
        XCTAssertNil(migrated["SULastCheckTime"])
        XCTAssertNil(migrated["NSWindow Frame panel"])
        XCTAssertEqual(migrated[ForkPreferences.marker] as? Bool, true)
        XCTAssertFalse(ForkPreferences.migrate(from: old, to: new, defaults: defaults))
    }

    func testMigrationMapsSenderAndReceiverToSeparateIdentities() {
        XCTAssertEqual(ForkPreferences.legacyDomains["io.github.nmt3325.openairdisplay.mac"],
                       "com.peetzweg.opensidecar.mac")
        XCTAssertEqual(ForkPreferences.legacyDomains["io.github.nmt3325.openairdisplay.mac.receiver"],
                       "com.peetzweg.opensidecar.mac.receiver")
        XCTAssertNil(ForkPreferences.legacyDomains["io.github.nmt3325.openairdisplay.ios"])
    }
}
