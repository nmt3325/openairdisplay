import Foundation

/// One-time migration of app-owned preferences; never touches macOS TCC grants.
/// Later releases retain the same fork bundle ID and therefore the same domain.
enum ForkPreferences {
    static let marker = "openairdisplay.legacyPreferencesMigrated"
    static let legacyDomains = [
        "io.github.nmt3325.openairdisplay.mac": "com.peetzweg.opensidecar.mac",
        "io.github.nmt3325.openairdisplay.mac.receiver": "com.peetzweg.opensidecar.mac.receiver",
        "io.github.nmt3325.openairdisplay.mac.debug": "com.peetzweg.opensidecar.mac.debug",
        "io.github.nmt3325.openairdisplay.mac.receiver.debug": "com.peetzweg.opensidecar.mac.receiver.debug",
    ]

    static func run() {
        guard let current = Bundle.main.bundleIdentifier,
              let legacy = legacyDomains[current] else { return }
        migrate(from: legacy, to: current, defaults: .standard)
    }

    @discardableResult
    static func migrate(from legacy: String, to current: String,
                        defaults: UserDefaults) -> Bool {
        var destination = defaults.persistentDomain(forName: current) ?? [:]
        guard destination[marker] as? Bool != true else { return false }
        let source = defaults.persistentDomain(forName: legacy) ?? [:]
        for (key, value) in source {
            // Do not carry upstream Sparkle state, OS/framework preferences or
            // its update URLs into the independently signed fork.
            guard !key.hasPrefix("SU"), !key.hasPrefix("NS"),
                  !key.hasPrefix("com.apple."), destination[key] == nil else { continue }
            destination[key] = value
        }
        destination[marker] = true
        defaults.setPersistentDomain(destination, forName: current)
        return true
    }
}
