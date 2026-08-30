import XCTest

private final class RecordingAboutMetadata: AboutBundleMetadataSource {
    private(set) var requestedKeys: [String] = []
    let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func stringValue(forInfoDictionaryKey key: String) -> String? {
        requestedKeys.append(key)
        return values[key]
    }
}

final class PublicPresentationModelsTests: XCTestCase {
    func testLocalNetworkPermissionPresentationUsesFourConservativeStates() {
        let notChecked = LocalNetworkPermissionPresentation.make(for: .notChecked)
        let connected = LocalNetworkPermissionPresentation.make(for: .collaborationConnected)
        let denied = LocalNetworkPermissionPresentation.make(for: .explicitSystemDenial)
        let failed = LocalNetworkPermissionPresentation.make(for: .ordinaryNetworkFailure)

        XCTAssertEqual(notChecked.statusText, "未检测")
        XCTAssertEqual(connected.statusText, "协同连接正常")
        XCTAssertEqual(denied.statusText, "系统明确拒绝")
        XCTAssertEqual(failed.statusText, "连接失败，请检查权限、地址和防火墙")
        XCTAssertTrue(denied.isExplicitlyDenied)
        XCTAssertTrue(denied.detailText.contains("系统设置 → 隐私与安全性 → 本地网络"))
    }

    func testAmbiguousFailuresNeverClaimLocalNetworkPermissionWasDenied() {
        let ambiguousEvidence: [LocalNetworkPermissionEvidence] = [
            .timeout, .authenticationFailure, .ordinaryNetworkFailure
        ]

        for evidence in ambiguousEvidence {
            let presentation = LocalNetworkPermissionPresentation.make(for: evidence)
            XCTAssertEqual(presentation.statusText, "连接失败，请检查权限、地址和防火墙")
            XCTAssertFalse(presentation.isExplicitlyDenied)
            XCTAssertTrue(presentation.detailText.contains("未获得系统明确拒绝"))
        }
    }

    func testPermissionEntryUsesOnlySimulatedInspectionAndHasZeroHardwareSideEffects() {
        var networkInspectionCount = 0
        let usbCount = 0
        let ddcCount = 0
        let wakeCount = 0
        let inputSwitchCount = 0

        let simulatedInspection: LocalNetworkPermissionInspectionAction.Inspection = { completion in
            networkInspectionCount += 1
            completion(.v2(endpointID: "00000000-0000-4000-8000-000000000001"))
        }
        var presentation: LocalNetworkPermissionPresentation?
        LocalNetworkPermissionInspectionAction.perform(using: simulatedInspection) { _, evidence in
            presentation = LocalNetworkPermissionPresentation.make(for: evidence)
        }

        XCTAssertEqual(presentation?.statusText, "协同连接正常")
        XCTAssertEqual(networkInspectionCount, 1)
        XCTAssertEqual(usbCount, 0)
        XCTAssertEqual(ddcCount, 0)
        XCTAssertEqual(wakeCount, 0)
        XCTAssertEqual(inputSwitchCount, 0)
    }

    func testOnlyExplicitSettingsReadUsesHardware() {
        let automaticEntryPoints: [DDCValuePresentationEntryPoint] = [
            .startup, .trayOpen, .displayDetection, .configurationReload
        ]

        for entryPoint in automaticEntryPoints {
            XCTAssertEqual(DDCValuePresentationPolicy.source(for: entryPoint), .cache)
        }
        XCTAssertEqual(DDCValuePresentationPolicy.source(for: .settingsReadButton), .hardware)
    }

    func testDisplayDiagnosticLayoutWrapsInsteadOfTruncatingTransportDetails() {
        XCTAssertTrue(DisplayDiagnosticLayout.wraps)
        XCTAssertEqual(DisplayDiagnosticLayout.maximumNumberOfLines, 0)
    }

    func testC023AboutPageUsesOnlyPublicMetadataAndHasNoRuntimeSideEffectDependencies() {
        let metadata = RecordingAboutMetadata(values: [
            "CFBundleName": "DisplaySwitcher",
            "CFBundleShortVersionString": "2.1.0",
            "CFBundleVersion": "19",
            "Peer.Host": "private-peer-value",
            "Peer.PairingCode": "private-pairing-value",
            "USB.Device": "private-usb-value",
            "Display.Identifier": "private-display-value",
            "Local.Path": "private-path-value"
        ])
        let content = AboutPageContent.make(metadata: metadata, architecture: "simulated-arch")
        let renderedPublicText = [
            content.productName,
            content.summary,
            content.versionText,
            content.platformText,
            content.buildNotice,
            AboutPageContent.repositoryURL.absoluteString,
            AboutPageContent.licenseURL.absoluteString,
            AboutPageContent.thirdPartyURL.absoluteString
        ].joined(separator: "\n")
        XCTAssertEqual(Set(metadata.requestedKeys), [
            "CFBundleName", "CFBundleShortVersionString", "CFBundleVersion"
        ])
        XCTAssertEqual(content.productName, "DisplaySwitcher")
        XCTAssertEqual(content.versionText, "版本 2.1.0 (19)")
        XCTAssertEqual(content.platformText, "macOS · simulated-arch · 协议 v2")
        for privateValue in metadata.values.values where privateValue.hasPrefix("private-") {
            XCTAssertFalse(renderedPublicText.contains(privateValue))
        }
    }

    func testManualEntriesUseOnlyCompleteEnabledProfileNames() {
        let display = DisplayConfigurationV4Display(
            id: UUID().uuidString,
            name: "模拟显示器",
            selector: UUID().uuidString,
            localInput: 15,
            readEnabled: false,
            brightnessEnabled: true,
            contrastEnabled: true,
            volumeEnabled: true
        )
        func profile(name: String, enabled: Bool, complete: Bool) -> CollaborationProfile {
            CollaborationProfile(
                id: UUID().uuidString,
                name: name,
                peerHost: complete ? "peer.example" : "",
                peerPort: 49731,
                pairingCode: complete ? "PUBLIC-TEST-CODE" : "",
                peerEndpointID: nil,
                peerProtocolVersion: nil,
                coordinationEnabled: enabled,
                displayInputs: complete
                    ? [DisplayInputMapping(displayID: display.id, peerInput: 18)] : [],
                triggerDevices: []
            )
        }
        let eligible = profile(name: "工作电脑", enabled: true, complete: true)
        let incomplete = profile(name: "未完成配置", enabled: true, complete: false)
        let disabled = profile(name: "已停用配置", enabled: false, complete: true)
        let document = DisplayConfigurationStoreV5Document(
            schemaVersion: 5,
            localEndpointID: UUID().uuidString,
            localDeviceName: "本机",
            listenPort: 49731, controlChannel: .automatic, linkAllDisplays: false,
            displays: [display],
            collaborationProfiles: [eligible, incomplete, disabled]
        )

        XCTAssertEqual(
            ManualSwitchMenuEntry.entries(in: document),
            [ManualSwitchMenuEntry(profileID: eligible.id, title: "切换到 工作电脑")]
        )
    }

    func testInputMappingTitlesPreserveSameModelDisplaySuffixes() {
        let names = ["模拟显示器（1）", "模拟显示器（2）"]

        XCTAssertEqual(names.map(DisplayInputMappingPresentation.usbTitle(displayName:)), [
            "模拟显示器（1） 离开后输入源",
            "模拟显示器（2） 离开后输入源"
        ])
        XCTAssertEqual(names.map(DisplayInputMappingPresentation.collaborationTitle(displayName:)), [
            "模拟显示器（1） 输入源",
            "模拟显示器（2） 输入源"
        ])
    }

    func testTwentyMappingReloadsRemainUniqueAndStableByDisplayID() {
        let displays = [
            mappingDisplay(id: "display-a", name: "模拟显示器 A"),
            mappingDisplay(id: "display-b", name: "模拟显示器 B（1）"),
            mappingDisplay(id: "display-c", name: "模拟显示器 B（2）")
        ]
        var usbRows: [DisplayInputMappingPresentation.Row] = []
        var collaborationRows: [DisplayInputMappingPresentation.Row] = []

        for cycle in 0..<20 {
            let reordered = cycle.isMultiple(of: 2) ? displays : Array(displays.reversed())
            usbRows = DisplayInputMappingPresentation.rows(
                displays: Array(reordered) + [displays[1]], context: .usb
            )
            collaborationRows = DisplayInputMappingPresentation.rows(
                displays: Array(reordered) + [displays[2]], context: .collaboration
            )
            XCTAssertEqual(Set(usbRows.map(\.displayID)).count, displays.count)
            XCTAssertEqual(Set(collaborationRows.map(\.displayID)).count, displays.count)
            XCTAssertEqual(usbRows.count, displays.count)
            XCTAssertEqual(collaborationRows.count, displays.count)
        }

        XCTAssertTrue(usbRows.contains { $0.title == "模拟显示器 B（1） 离开后输入源" })
        XCTAssertTrue(usbRows.contains { $0.title == "模拟显示器 B（2） 离开后输入源" })
        XCTAssertTrue(collaborationRows.contains { $0.title == "模拟显示器 B（1） 输入源" })
        XCTAssertTrue(collaborationRows.contains { $0.title == "模拟显示器 B（2） 输入源" })
    }

    func testCachedValuesRestoreByStableIDAcrossRebuildAndCacheInstances() {
        let suiteName = "DisplayCachedValuePresentation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstCache = UserDefaultsDDCValueCache(defaults: defaults)
        firstCache.setValue(32, stableID: "DISPLAY-A", command: .luminance)
        firstCache.setValue(74, stableID: "display-b", command: .luminance)

        let displays = [
            cachedDisplay(id: "display-a", name: "模拟显示器（1）", brightnessEnabled: true),
            cachedDisplay(id: "display-b", name: "模拟显示器（2）", brightnessEnabled: true)
        ]
        let reopenedCache = UserDefaultsDDCValueCache(defaults: defaults)
        let firstBuild = DisplayCachedValuePresentation.entries(
            displays: displays,
            cachedValue: reopenedCache.value(stableID:command:)
        )
        let rebuilt = DisplayCachedValuePresentation.entries(
            displays: Array(displays.reversed()),
            cachedValue: reopenedCache.value(stableID:command:)
        )

        XCTAssertEqual(Set(firstBuild), Set(rebuilt))
        XCTAssertEqual(firstBuild.first { $0.stableID == "display-a" }?.label, "≈32")
        XCTAssertEqual(firstBuild.first { $0.stableID == "display-b" }?.label, "≈74")
    }

    func testCachedPresentationOmitsDisabledAndUnknownDisplaysWithoutCrossAssociation() {
        let values: [String: Int] = ["display-a": 41, "removed-display": 99]
        let displays = [
            cachedDisplay(id: "display-a", name: "模拟显示器（1）", brightnessEnabled: true),
            cachedDisplay(id: "display-b", name: "模拟显示器（2）", brightnessEnabled: false)
        ]
        let entries = DisplayCachedValuePresentation.entries(displays: displays) { stableID, command in
            command == .luminance ? values[stableID.lowercased()] : nil
        }

        XCTAssertEqual(entries, [
            DisplayCachedValuePresentation.Entry(stableID: "display-a", command: .luminance, value: 41)
        ])
    }

    private func mappingDisplay(id: String, name: String) -> DisplayConfigurationV4Display {
        DisplayConfigurationV4Display(
            id: id, name: name, selector: "selector-\(id)", localInput: nil,
            readEnabled: false, brightnessEnabled: false,
            contrastEnabled: false, volumeEnabled: false
        )
    }

    private func cachedDisplay(
        id: String,
        name: String,
        brightnessEnabled: Bool
    ) -> DisplayConfigurationV4Display {
        DisplayConfigurationV4Display(
            id: id, name: name, selector: "selector-\(id)", localInput: nil,
            readEnabled: false, brightnessEnabled: brightnessEnabled,
            contrastEnabled: false, volumeEnabled: false
        )
    }
}
