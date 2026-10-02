// Update destinations for this fork. No upstream App Store/site identity is used.
import Foundation

enum ForkUpdates {
    static let repositoryURL = URL(string: "https://github.com/nmt3325/openairdisplay")!
    static let updateURL = URL(string: "https://github.com/nmt3325/openairdisplay/releases/latest")!
    static let webURL = updateURL
    static let iOSManifestURL = URL(string: "https://raw.githubusercontent.com/nmt3325/openairdisplay/main/public/openairdisplay-ios-version.json")!
}
