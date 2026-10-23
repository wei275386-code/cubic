import Foundation

enum AppVersion {
    static var display: String { display(info: Bundle.main.infoDictionary ?? [:]) }
    static func display(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "未知版本"
        let build = info["CFBundleVersion"] as? String ?? "未知 build"
        return "\(version) (\(build))"
    }
}
