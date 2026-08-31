import AppKit
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
    func testSettingsCardUsesDynamicSemanticSurfaceAndRoundedClipping() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let card = SettingsCardView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))

        card.appearance = light
        card.updateLayer()
        let lightCard = card.layer?.backgroundColor?.components ?? []
        let lightCanvas = SettingsSurfaceStyle.pageBackgroundColor(using: light).components ?? []

        XCTAssertEqual(card.layer?.cornerRadius, SettingsSurfaceStyle.cardCornerRadius)
        XCTAssertEqual(card.layer?.borderWidth, SettingsSurfaceStyle.cardBorderWidth)
        XCTAssertTrue(card.layer?.masksToBounds ?? false)
        XCTAssertNotNil(card.layer?.borderColor)
        XCTAssertNotEqual(lightCard, lightCanvas)

        card.appearance = dark
        card.updateLayer()
        let darkCard = card.layer?.backgroundColor?.components ?? []
        let darkCanvas = SettingsSurfaceStyle.pageBackgroundColor(using: dark).components ?? []

        XCTAssertNotEqual(darkCard, darkCanvas)
        XCTAssertNotEqual(lightCard, darkCard)
        XCTAssertNotEqual(lightCanvas, darkCanvas)
    }

    func testPageContainersAreTransparentAndDoNotCreateSecondCanvas() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let page = SettingsPageBackgroundView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let document = SettingsPageBackgroundView(frame: page.frame)
        let scroll = SettingsPageScrollView(frame: page.frame)

        XCTAssertFalse(SettingsSurfaceStyle.pagePaintsBackground)
        XCTAssertFalse(SettingsSurfaceStyle.scrollPaintsBackground)
        XCTAssertFalse(page.isOpaque)
        XCTAssertFalse(document.isOpaque)
        XCTAssertFalse(scroll.drawsBackground)
        XCTAssertFalse(scroll.contentView.drawsBackground)
        XCTAssertEqual(scroll.backgroundColor, .clear)

        page.appearance = light
        document.appearance = light
        scroll.appearance = light
        scroll.viewDidChangeEffectiveAppearance()
        XCTAssertNil(page.layer?.backgroundColor)
        XCTAssertNil(document.layer?.backgroundColor)
        XCTAssertFalse(scroll.contentView.drawsBackground)

        let lightCanvas = SettingsSurfaceStyle.pageBackgroundColor(using: light).components ?? []
        let darkCanvas = SettingsSurfaceStyle.pageBackgroundColor(using: dark).components ?? []
        XCTAssertNotEqual(lightCanvas, darkCanvas)
    }

    func testAllSettingsPagesShareTheSingleCanvasConstructionContract() {
        XCTAssertEqual(SettingsPageLayoutProjection.tabLabels, [
            "常规", "USB 切换", "协同", "显示器", "诊断", "关于"
        ])
        XCTAssertTrue(SettingsPageLayoutProjection.tabLabels.allSatisfy { _ in
            !SettingsSurfaceStyle.pagePaintsBackground && !SettingsSurfaceStyle.scrollPaintsBackground
        })
    }

    func testSettingsActionButtonStyleAppliesOneNativeRegularContract() {
        let button = NSButton(title: "测试动作", target: nil, action: nil)
        SettingsActionButtonStyle.apply(to: button)
        SettingsActionButtonStyle.apply(to: button)

        XCTAssertEqual(button.controlSize, SettingsActionButtonStyle.controlSize)
        XCTAssertEqual(button.bezelStyle, SettingsActionButtonStyle.bezelStyle)
        XCTAssertEqual(
            button.constraints.filter { $0.identifier == "SettingsActionButton.minimumHeight" }.count,
            1
        )
        XCTAssertTrue(button.constraints.contains {
            $0.identifier == "SettingsActionButton.minimumHeight"
                && $0.relation == .greaterThanOrEqual
                && $0.constant == SettingsActionButtonStyle.minimumHeight
        })
    }

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

    func testDisplayStatusLayoutUsesOneConciseLine() {
        XCTAssertFalse(DisplayStatusLayout.wraps)
        XCTAssertEqual(DisplayStatusLayout.maximumNumberOfLines, 1)
    }

    func testDisplayControlModuleDoesNotStartWithLeadingSeparator() {
        XCTAssertEqual(DisplayControlModuleContent.items.first, .linkAllDisplays)
        XCTAssertFalse(DisplayControlModuleContent.items.contains(.separator))
    }

    func testDisplayReadModuleKeepsItsMeaningfulSeparator() {
        XCTAssertEqual(DisplayReadModuleContent.items, [
            .displayReadStatus, .separator, .displayControls
        ])
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
            listenPort: 49731, linkAllDisplays: false,
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
            "模拟显示器（1）",
            "模拟显示器（2）"
        ])
        XCTAssertEqual(names.map(DisplayInputMappingPresentation.collaborationTitle(displayName:)), [
            "模拟显示器（1）",
            "模拟显示器（2）"
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

        XCTAssertTrue(usbRows.contains { $0.title == "模拟显示器 B（1）" })
        XCTAssertTrue(usbRows.contains { $0.title == "模拟显示器 B（2）" })
        XCTAssertTrue(collaborationRows.contains { $0.title == "模拟显示器 B（1）" })
        XCTAssertTrue(collaborationRows.contains { $0.title == "模拟显示器 B（2）" })
    }

    func testUSBSettingsLayoutUsesThreeGroupsAndDynamicDisplayRows() {
        for count in [0, 1, 2, 3, 5] {
            let displays = (0..<count).map {
                mappingDisplay(id: "display-\($0)", name: "模拟显示器 \($0 + 1)")
            }
            let layout = SettingsPageLayoutProjection.usb(
                displays: displays, learningInProgress: false
            )

            XCTAssertEqual(layout.groups.map(\.id), [
                .usbAutomation, .usbPeerInputs, .usbCollaboration
            ])
            XCTAssertEqual(layout.groups[0].rows.map(\.id), [
                "usb-automatic-switch", "usb-trigger-device", "usb-connection-status", "usb-learn"
            ])
            let mappingRows = layout.groups[1].rows
            XCTAssertEqual(mappingRows.count, max(1, count))
            if count == 0 {
                XCTAssertEqual(mappingRows.first?.id, "usb-mapping-empty")
            } else {
                XCTAssertEqual(mappingRows.map(\.title), displays.map(\.name))
                XCTAssertTrue(mappingRows.allSatisfy { $0.action == .editValue })
            }
            XCTAssertEqual(layout.groups[2].rows.map(\.action), [
                .selectUSBWakeProfile, .toggleUSBWake
            ])
        }
    }

    func testUSBSettingsLearningDisablesOnlyLearningAction() {
        let layout = SettingsPageLayoutProjection.usb(
            displays: [mappingDisplay(id: "display-a", name: "模拟显示器")],
            learningInProgress: true
        )
        let rows = layout.groups[0].rows

        XCTAssertFalse(rows.first { $0.id == "usb-learn" }?.isEnabled ?? true)
        XCTAssertTrue(rows.first { $0.id == "usb-automatic-switch" }?.isEnabled ?? false)
        XCTAssertTrue(rows.allSatisfy(\.isVisible))
    }

    func testHorizontalRowsPinTrailingControlsWithoutUnboundedLeadingGrowth() {
        let split = SettingsHorizontalRowAlignment.splitByFlexibleGap
        XCTAssertTrue(split.pinsTrailingControlToCardEdge)
        XCTAssertTrue(split.usesFlexibleGap)
        XCTAssertFalse(split.expandsLeadingControl)

        let expanding = SettingsHorizontalRowAlignment.expandingLeadingControl
        XCTAssertTrue(expanding.pinsTrailingControlToCardEdge)
        XCTAssertFalse(expanding.usesFlexibleGap)
        XCTAssertTrue(expanding.expandsLeadingControl)
    }

    func testCollaborationSettingsLayoutOrdersGroupsAndPreservesActions() {
        let displays = (0..<4).map {
            mappingDisplay(id: "display-\($0)", name: "模拟显示器 \($0 + 1)")
        }
        let layout = SettingsPageLayoutProjection.collaboration(
            displays: displays,
            hasSelectedProfile: true,
            profileCount: 2,
            selectedProfileIndex: 0,
            inspectionInProgress: false
        )

        XCTAssertEqual(layout.groups.map(\.id), [
            .collaborationStatus, .collaborationSelection, .collaborationDetails
        ])
        XCTAssertEqual(layout.groups[0].rows.map(\.action), [
            nil, .requestLocalNetworkPermission, .inspectCollaboration
        ])
        XCTAssertEqual(layout.groups[1].rows.map(\.action), [
            .selectCollaborationProfile, .addCollaborationProfile
        ])
        XCTAssertEqual(
            layout.groups[2].rows.filter { $0.id.hasPrefix("collaboration-mapping-") }.map(\.title),
            displays.map(\.name)
        )
        XCTAssertTrue(layout.groups[2].rows.contains {
            $0.id == "collaboration-delete" && $0.action == .deleteCollaborationProfile && $0.isEnabled
        })
        XCTAssertTrue(layout.groups[2].rows.contains {
            $0.id == "collaboration-save-status" && $0.isVisible
        })
        XCTAssertFalse(layout.groups[2].rows.first {
            $0.action == .moveCollaborationProfileUp
        }?.isEnabled ?? true)
        XCTAssertTrue(layout.groups[2].rows.first {
            $0.action == .moveCollaborationProfileDown
        }?.isEnabled ?? false)
    }

    func testCollaborationSettingsVisibilityAndInspectionEnablementAreConservative() {
        let empty = SettingsPageLayoutProjection.collaboration(
            displays: [], hasSelectedProfile: false, profileCount: 0,
            selectedProfileIndex: 0,
            inspectionInProgress: false
        )
        XCTAssertTrue(empty.groups[2].rows.allSatisfy { !$0.isVisible })
        XCTAssertFalse(empty.groups[0].rows.first {
            $0.action == .inspectCollaboration
        }?.isEnabled ?? true)

        let checking = SettingsPageLayoutProjection.collaboration(
            displays: [mappingDisplay(id: "display-a", name: "模拟显示器")],
            hasSelectedProfile: true, profileCount: 1,
            selectedProfileIndex: 0,
            inspectionInProgress: true
        )
        XCTAssertFalse(checking.groups[0].rows.first {
            $0.action == .requestLocalNetworkPermission
        }?.isEnabled ?? true)
        XCTAssertFalse(checking.groups[0].rows.first {
            $0.action == .inspectCollaboration
        }?.isEnabled ?? true)
        XCTAssertFalse(checking.groups[2].rows.first {
            $0.action == .deleteCollaborationProfile
        }?.isEnabled ?? true)
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

    func testM006DiagnosticReportPreviewsOnlyAnonymizedReadOnlyState() {
        let privateValues = [
            "192.0.2.44",
            "private-pairing-code",
            "11111111-2222-4333-8444-555555555555",
            "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
            "private-usb-reference",
            "Private Monitor Name",
            "Private Profile Name"
        ]
        let display = DisplayConfigurationV4Display(
            id: privateValues[2], name: privateValues[5], selector: privateValues[3],
            localInput: 17, readEnabled: true, brightnessEnabled: true,
            contrastEnabled: false, volumeEnabled: false
        )
        let profile = CollaborationProfile(
            id: "99999999-8888-4777-8666-555555555555",
            name: privateValues[6], peerHost: privateValues[0], peerPort: 49_731,
            pairingCode: privateValues[1],
            peerEndpointID: "77777777-6666-4555-8444-333333333333",
            peerProtocolVersion: 2, coordinationEnabled: true,
            displayInputs: [DisplayInputMapping(displayID: display.id, peerInput: 15)],
            triggerDevices: []
        )
        let document = DisplayConfigurationStoreV5Document(
            schemaVersion: 5,
            localEndpointID: "12345678-1234-4234-8234-123456789012",
            localDeviceName: "Private Mac",
            listenPort: 49_731,
            linkAllDisplays: false,
            displays: [display],
            collaborationProfiles: [profile],
            usbSwitch: USBSwitchConfiguration(
                enabled: true,
                triggerDevice: CollaborationTriggerDevice(
                    kind: "usb", localReference: privateValues[4], displayName: "Private USB"
                ),
                collaborationWakeEnabled: true,
                collaborationProfileID: profile.id,
                displayInputs: [USBDisplayInputMapping(displayID: display.id, targetInput: 15)]
            )
        )
        let diagnostic = NativeDDCDiagnosticSnapshot(
            transportPath: .typeCDPAlt,
            serviceMatched: true,
            operationCategory: .readSucceeded,
            rebuildCount: 0,
            chipAddress: 0x37,
            readDataAddress: 0x51,
            readAttemptCount: 1,
            requestChecksumMode: .legacy
        )

        let report = DiagnosticReport.make(
            metadata: RecordingAboutMetadata(values: [
                "CFBundleName": "DisplaySwitcher",
                "CFBundleShortVersionString": "2.1.0",
                "CFBundleVersion": "19"
            ]),
            architecture: "simulated-arch",
            document: document,
            safetyState: .ready,
            collaborationStates: [.connected],
            ddcBackendSummary: "Apple Silicon 原生 DDC",
            ddcAvailability: .available,
            ddcCapabilities: DDCBackendCapabilities(
                canEnumerate: true, canReadVCP: true, canWriteVCP: true
            ),
            detailedRecordingEnabled: true,
            ddcDiagnostics: [diagnostic],
            peerInspectionText: "inspection=I1 stage=completed result=v2-available",
            inputSourceText: "op=O1 display=D1 stage=write-transport-result"
        ).text

        XCTAssertTrue(report.contains("protocol=v2 schema=5"))
        XCTAssertTrue(report.contains("profile=P1 enabled=true endpoint-bound=true status=已连接"))
        XCTAssertTrue(report.contains("trigger-configured=true"))
        XCTAssertTrue(report.contains("display=D1 controls=luminance"))
        XCTAssertTrue(report.contains("checksum legacy"))
        XCTAssertTrue(report.contains("does not access the network"))
        for privateValue in privateValues {
            XCTAssertFalse(report.contains(privateValue))
        }
        XCTAssertFalse(report.contains(profile.id))
        XCTAssertFalse(report.contains(document.localEndpointID))
        XCTAssertFalse(report.contains("Private Mac"))
        XCTAssertFalse(report.contains("Private USB"))

        let disabledReport = DiagnosticReport.make(
            metadata: RecordingAboutMetadata(values: [
                "CFBundleName": "DisplaySwitcher",
                "CFBundleShortVersionString": "2.1.0",
                "CFBundleVersion": "19"
            ]),
            architecture: "simulated-arch",
            document: document,
            safetyState: .ready,
            collaborationStates: [.connected],
            ddcBackendSummary: "Apple Silicon 原生 DDC",
            ddcAvailability: .available,
            ddcCapabilities: DDCBackendCapabilities(
                canEnumerate: true, canReadVCP: true, canWriteVCP: true
            ),
            detailedRecordingEnabled: false,
            ddcDiagnostics: [diagnostic],
            peerInspectionText: "private-collaboration-trace",
            inputSourceText: "private-input-source-trace"
        ).text
        XCTAssertTrue(disabledReport.contains("detailed-recording=false"))
        XCTAssertTrue(disabledReport.contains("recording-disabled"))
        XCTAssertFalse(disabledReport.contains("checksum legacy"))
        XCTAssertFalse(disabledReport.contains("private-collaboration-trace"))
        XCTAssertFalse(disabledReport.contains("private-input-source-trace"))
    }

    func testDisplayDDCStatusNeverIncludesTransportDiagnostics() {
        let reading = DDCResolvedReading(
            reading: DDCReading(current: 52, maximum: 100), estimated: false
        )

        let text = DisplayDDCStatusPresentation.read(
            values: [.luminance: reading], skipReason: nil
        )
        XCTAssertEqual(text, "读取成功")
        for internalDetail in ["builtin-hdmi-converter", "chip", "offset", "attempts", "checksum", "rebuild"] {
            XCTAssertFalse(text.contains(internalDetail))
        }
        XCTAssertEqual(
            DisplayDDCStatusPresentation.read(values: [:], skipReason: nil),
            "读取失败"
        )
        XCTAssertEqual(
            DisplayDDCStatusPresentation.read(
                values: [.luminance: DDCResolvedReading(reading: reading.reading, estimated: true)],
                skipReason: nil
            ),
            "读取失败"
        )
        XCTAssertEqual(DisplayDDCStatusPresentation.write(value: 52, error: nil), "写入成功")
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
