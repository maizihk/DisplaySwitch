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
}
