import Foundation

protocol AboutBundleMetadataSource {
    func stringValue(forInfoDictionaryKey key: String) -> String?
}

extension Bundle: AboutBundleMetadataSource {
    func stringValue(forInfoDictionaryKey key: String) -> String? {
        object(forInfoDictionaryKey: key) as? String
    }
}

struct AboutPageContent: Equatable {
    static let repositoryURL = URL(string: "https://github.com/maizihk/DisplaySwitch")!
    static let licenseURL = URL(string: "https://github.com/maizihk/DisplaySwitch/blob/main/LICENSE")!
    static let thirdPartyURL = URL(
        string: "https://github.com/maizihk/DisplaySwitch/tree/main/macOS/ThirdParty"
    )!

    let productName: String
    let summary: String
    let versionText: String
    let platformText: String
    let buildNotice: String

    static func make(
        metadata: AboutBundleMetadataSource,
        architecture: String = currentArchitecture
    ) -> AboutPageContent {
        let name = metadata.stringValue(forInfoDictionaryKey: "CFBundleName")
            ?? "DisplaySwitcher"
        let shortVersion = metadata.stringValue(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) ?? "未知"
        let buildVersion = metadata.stringValue(forInfoDictionaryKey: "CFBundleVersion")
            ?? "未知"
        return AboutPageContent(
            productName: name,
            summary: "一款在 macOS 与 Windows 之间协同切换显示器和 USB 设备的原生菜单栏工具。",
            versionText: "版本 \(shortVersion) (\(buildVersion))",
            platformText: "macOS · \(architecture) · 协议 v2",
            buildNotice: "源码构建和测试包不等于经过签名与公证的正式发行版。"
        )
    }

    private static var currentArchitecture: String {
#if arch(arm64)
        return "Apple Silicon (arm64)"
#elseif arch(x86_64)
        return "Intel (x86_64)"
#else
        return "未知架构"
#endif
    }
}

struct ManualSwitchMenuEntry: Equatable {
    let profileID: String
    let title: String

    static func entries(in document: DisplayConfigurationStoreV5Document) -> [ManualSwitchMenuEntry] {
        DisplayConfigurationStore.menuEligibleProfiles(in: document).map {
            ManualSwitchMenuEntry(profileID: $0.id, title: "切换到 \($0.name)")
        }
    }
}
