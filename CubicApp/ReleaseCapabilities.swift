import Foundation

/// Build configuration is visible in the final Info.plist. Release is fail-closed,
/// even if an operator overrides the Info build setting or supplies cloud entitlements.
enum ReleaseCapabilities {
    static let cloudKitUnavailableMessage = "此发行版不支持 CloudKit 连接或远端下载。原账号的本机记录和历史保留，可继续编辑及导出备份。请先导出备份，再明确选择 iCloud Drive 同步目录并合并本机数据；未下载的远端记录须在可访问原 CloudKit 的兼容版本中核对并导出。"
    static var cloudKitEnabled: Bool {
        #if CUBIC_RELEASE || !DEBUG
        return false
        #else
        return permitsCloudKit(configuration: Bundle.main.object(forInfoDictionaryKey: "CubicBuildConfiguration") as? String,
            capability: Bundle.main.object(forInfoDictionaryKey: "CubicCloudKitCapability") as? String, releaseBuild: false)
        #endif
    }
    static func permitsCloudKit(configuration: String?, capability: String?, releaseBuild: Bool) -> Bool {
        !releaseBuild && configuration == "Debug" && capability == "development"
    }
}

enum AppVersion {
    static var display: String { display(info: Bundle.main.infoDictionary ?? [:]) }
    static func display(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "未知版本"
        let build = info["CFBundleVersion"] as? String ?? "未知 build"
        return "\(version) (\(build))"
    }
}
