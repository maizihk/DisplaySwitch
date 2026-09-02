import Foundation

enum LocalNetworkPermissionEvidence: Equatable {
    case notChecked
    case collaborationConnected
    case timeout
    case authenticationFailure
    case ordinaryNetworkFailure
    case explicitSystemDenial
}

struct LocalNetworkPermissionPresentation: Equatable {
    let statusText: String
    let detailText: String
    let isFailure: Bool
    let isExplicitlyDenied: Bool

    static func make(for evidence: LocalNetworkPermissionEvidence) -> Self {
        switch evidence {
        case .notChecked:
            return Self(
                statusText: "未检测",
                detailText: "点击“检测并申请权限”后，将使用当前协同配置执行一次真实连接检测。",
                isFailure: false,
                isExplicitlyDenied: false
            )
        case .collaborationConnected:
            return Self(
                statusText: "协同连接正常",
                detailText: "已通过当前协同配置完成认证连接。",
                isFailure: false,
                isExplicitlyDenied: false
            )
        case .explicitSystemDenial:
            return Self(
                statusText: "系统明确拒绝",
                detailText: "请前往“系统设置 → 隐私与安全性 → 本地网络”，允许 DisplaySwitcher 访问。",
                isFailure: true,
                isExplicitlyDenied: true
            )
        case .timeout, .authenticationFailure, .ordinaryNetworkFailure:
            return Self(
                statusText: "连接失败，请检查权限、地址和防火墙",
                detailText: "未获得系统明确拒绝本地网络访问的证据。",
                isFailure: true,
                isExplicitlyDenied: false
            )
        }
    }
}

enum LocalNetworkPermissionInspectionAction {
    typealias Inspection = (@escaping (PeerCapabilityInspectionResult) -> Void) -> Void

    static func perform(
        using inspection: Inspection,
        completion: @escaping (PeerCapabilityInspectionResult, LocalNetworkPermissionEvidence) -> Void
    ) {
        inspection { result in
            let evidence: LocalNetworkPermissionEvidence
            switch result {
            case .v2:
                evidence = .collaborationConnected
            case .authenticationFailed:
                evidence = .authenticationFailure
            case .noResponse:
                evidence = .timeout
            }
            completion(result, evidence)
        }
    }
}

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

    static var currentArchitecture: String {
#if arch(arm64)
        return "Apple Silicon (arm64)"
#elseif arch(x86_64)
        return "Intel (x86_64)"
#else
        return "未知架构"
#endif
    }
}

enum DisplayDDCStatusPresentation {
    static func read(
        values: [DDCCommand: DDCResolvedReading],
        skipReason: DDCReadSkipReason?
    ) -> String {
        if let skipReason { return skipReason.userFacingDescription }
        if values.isEmpty { return "读取失败" }
        if values.values.contains(where: \.estimated) { return "读取失败" }
        return "读取成功"
    }

    static func write(value: Int?, error: Error?) -> String {
        if value != nil { return "写入成功" }
        return error == nil ? "已取消" : "写入失败"
    }
}

struct DiagnosticReport: Equatable {
    let text: String

    static func make(
        metadata: AboutBundleMetadataSource,
        architecture: String,
        document: DisplayConfigurationStoreV5Document,
        safetyState: DisplayConfigurationSafetyState,
        collaborationStates: [CollaborationConnectionState],
        ddcBackendSummary: String,
        ddcAvailability: DDCBackendAvailability,
        ddcCapabilities: DDCBackendCapabilities,
        detailedRecordingEnabled: Bool,
        ddcDiagnostics: [NativeDDCDiagnosticSnapshot?],
        peerInspectionText: String,
        inputSourceText: String
    ) -> DiagnosticReport {
        let about = AboutPageContent.make(metadata: metadata, architecture: architecture)
        var lines = [
            "DisplaySwitcher diagnostic preview",
            "Session-only anonymized data. No pairing code, IP, path, endpoint ID, display UUID, or USB identifier.",
            "Generating this preview does not access the network or perform USB, wake, DDC, or input-source operations.",
            "",
            "[Application]",
            "product=\(about.productName)",
            "version=\(about.versionText.replacingOccurrences(of: "版本 ", with: ""))",
            "platform=macOS architecture=\(architecture)",
            "protocol=v2 schema=\(document.schemaVersion)",
            "configuration-safety=\(safetyState == .ready ? "ready" : "user-review-required")",
            "detailed-recording=\(detailedRecordingEnabled)",
            "",
            "[Collaboration]"
        ]

        if document.collaborationProfiles.isEmpty {
            lines.append("profiles=0")
        } else {
            for (index, profile) in document.collaborationProfiles.enumerated() {
                let state = collaborationStates.indices.contains(index)
                    ? collaborationStates[index].text : "未知"
                lines.append(
                    "profile=P\(index + 1) enabled=\(profile.coordinationEnabled)"
                        + " endpoint-bound=\(profile.peerEndpointID != nil) status=\(state)"
                )
            }
        }

        lines += [
            "",
            "[USB]",
            "enabled=\(document.usbSwitch.enabled)"
                + " trigger-configured=\(document.usbSwitch.triggerDevice != nil)"
                + " display-mappings=\(document.usbSwitch.displayInputs.count)"
                + " collaboration-wake=\(document.usbSwitch.collaborationWakeEnabled)",
            "",
            "[DDC]",
            "backend=\(ddcBackendSummary)",
            "availability=\(availabilityText(ddcAvailability))"
                + " enumerate=\(ddcCapabilities.canEnumerate)"
                + " read=\(ddcCapabilities.canReadVCP)"
                + " write=\(ddcCapabilities.canWriteVCP)"
        ]

        if document.displays.isEmpty {
            lines.append("displays=0")
        } else {
            for (index, display) in document.displays.enumerated() {
                let diagnostic = ddcDiagnostics.indices.contains(index)
                    ? ddcDiagnostics[index] : nil
                let enabled = DisplaySettingsSemantics.enabledCommands(for: display)
                    .map(\.cacheKeyComponent).sorted().joined(separator: ",")
                let state = detailedRecordingEnabled
                    ? diagnostic.map(\.userFacingDescription) ?? "not-checked"
                    : "detail-recording-disabled"
                lines.append(
                    "display=D\(index + 1) controls=\(enabled.isEmpty ? "none" : enabled)"
                        + " state=\(state)"
                )
            }
        }

        if detailedRecordingEnabled {
            lines += [
                "",
                "[Collaboration session]",
                normalizedSessionText(peerInspectionText),
                "",
                "[Input-source session]",
                normalizedSessionText(inputSourceText)
            ]
        } else {
            lines += [
                "",
                "[Detailed diagnostics]",
                "recording-disabled; enable it in General settings, reproduce the issue, then refresh this preview"
            ]
        }
        return DiagnosticReport(text: lines.joined(separator: "\n"))
    }

    private static func availabilityText(_ availability: DDCBackendAvailability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable:
            return "unavailable"
        }
    }

    private static func normalizedSessionText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "no-session-data" : trimmed
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

enum DDCValuePresentationEntryPoint: CaseIterable {
    case startup
    case trayOpen
    case displayDetection
    case configurationReload
    case settingsReadButton
}

enum DDCValuePresentationSource: Equatable {
    case cache
    case hardware
}

enum DDCValuePresentationPolicy {
    static func source(for entryPoint: DDCValuePresentationEntryPoint) -> DDCValuePresentationSource {
        entryPoint == .settingsReadButton ? .hardware : .cache
    }
}
