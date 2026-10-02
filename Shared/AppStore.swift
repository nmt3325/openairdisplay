// Update destinations for this fork. No upstream App Store/site identity is used.
import Foundation

// This fork ships outside the App Store, so there is no listing to update
// from or review: every destination stays on the fork's own repository.
enum ForkUpdates {
    static let repositoryURL = URL(string: "https://github.com/nmt3325/openairdisplay")!
    static let updateURL = URL(string: "https://github.com/nmt3325/openairdisplay/releases/latest")!
    static let webURL = updateURL
    static let iOSManifestURL = URL(string: "https://raw.githubusercontent.com/nmt3325/openairdisplay/main/public/openairdisplay-ios-version.json")!
}
