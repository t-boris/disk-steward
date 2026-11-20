import Foundation

/// Provides the current application version from the app bundle Info.plist,
/// falling back to the embedded semantic version when running from SwiftPM/CLI.
public enum DiskStewardVersion {
    public static let fallbackVersion = "1.0.0"
    public static let fallbackBuild = "2"

    public static var current: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return version
        }
        return fallbackVersion
    }

    public static var build: String {
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
           !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return build
        }
        return fallbackBuild
    }

    public static var displayString: String {
        "Disk Steward \(current) (build \(build))"
    }
}
