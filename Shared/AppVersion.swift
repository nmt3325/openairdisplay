import Foundation

/// SideStore and iOS identify installed apps using the numeric bundle
/// version; the in-app display can show the full OpenAirDisplay release tag.
struct AppVersion {
    let marketing: String
    let build: String
    let forkTag: String?
    let upstream: String?

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        marketing = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        build = info["CFBundleVersion"] as? String ?? "0"
        forkTag = info["OpenAirDisplayReleaseTag"] as? String
        upstream = info["OpenAirDisplayUpstreamVersion"] as? String
    }

    var display: String {
        let tag = forkTag.flatMap { $0.hasPrefix("v") ? $0 : nil }
        return "\(tag ?? "v" + marketing) (build \(build))"
    }

    var upstreamDisplay: String { upstream ?? marketing }
}
