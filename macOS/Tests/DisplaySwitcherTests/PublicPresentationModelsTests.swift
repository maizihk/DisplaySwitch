import AppKit
import XCTest

private final class ManualSettingsSaveFeedbackScheduler: SettingsSaveFeedbackScheduling {
    final class Task: SettingsSaveFeedbackScheduledTask {
        let delay: TimeInterval
        let action: () -> Void
        private(set) var isCancelled = false

        init(delay: TimeInterval, action: @escaping () -> Void) {
            self.delay = delay
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }

        func fireEvenIfCancelled() {
            action()
        }
    }

    private(set) var tasks: [Task] = []

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SettingsSaveFeedbackScheduledTask {
        let task = Task(delay: delay, action: action)
        tasks.append(task)
        return task
    }
}

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
        XCTAssertEqual(
            DisplayControlModuleContent.items(showsLinkedControls: false),
            [.linkAllDisplays]
        )
        XCTAssertEqual(
            DisplayControlModuleContent.items(showsLinkedControls: true),
            [.linkAllDisplays, .separator, .linkedDisplayControls]
        )
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

    func testUSBSettingsLayoutUsesTwoGroupsAndMergesDynamicDisplayRows() {
        for count in [0, 1, 2, 3, 5] {
            let displays = (0..<count).map {
                mappingDisplay(id: "display-\($0)", name: "模拟显示器 \($0 + 1)")
            }
            let layout = SettingsPageLayoutProjection.usb(
                displays: displays, learningInProgress: false
            )

            XCTAssertEqual(layout.groups.map(\.id), [
                .usbAutomation, .usbCollaboration
            ])
            XCTAssertEqual(Array(layout.groups[0].rows.prefix(5)).map(\.id), [
                "usb-automatic-switch", "usb-automation-controls-separator",
                "usb-trigger-device", "usb-connection-status", "usb-peer-inputs-separator"
            ])
            XCTAssertEqual(
                layout.groups[0].rows.filter { $0.kind == .separator }.map(\.id),
                ["usb-automation-controls-separator", "usb-peer-inputs-separator"]
            )
            let mappingRows = Array(layout.groups[0].rows.dropFirst(5))
            XCTAssertEqual(mappingRows.count, max(1, count))
            if count == 0 {
                XCTAssertEqual(mappingRows.first?.id, "usb-mapping-empty")
            } else {
                XCTAssertEqual(mappingRows.map(\.title), displays.map(\.name))
                XCTAssertTrue(mappingRows.allSatisfy { $0.action == .editValue })
            }
            XCTAssertEqual(layout.groups[1].rows.map(\.action), [
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

        XCTAssertEqual(rows.first { $0.id == "usb-trigger-device" }?.action, .learnUSBDevice)
        XCTAssertFalse(rows.first { $0.id == "usb-trigger-device" }?.isEnabled ?? true)
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

    func testFormRowsAlignLabelsWithCardContentWhileKeepingControlColumnStable() {
        let layout = SettingsFormRowLayout.leadingLabelFixedControlColumn
        XCTAssertTrue(layout.alignsLabelWithCardContentLeading)
        XCTAssertTrue(layout.keepsControlColumnStable)
        XCTAssertEqual(SettingsFormRowLayout.contentWidth, 590)
        XCTAssertEqual(SettingsFormRowLayout.labelColumnWidth, 90)
        XCTAssertEqual(SettingsFormRowLayout.controlColumnSpacing, 10)
        XCTAssertEqual(SettingsFormRowLayout.controlColumnWidth, 490)
    }

    func testProfileNameRowUsesOneStableControlColumnWithFlexibleFieldAndTrailingSwitch() throws {
        let layout = SettingsTrailingAccessoryRowLayout()
        XCTAssertTrue(layout.usesSingleControlColumn)
        XCTAssertTrue(layout.leadingControlExpandsInsideColumn)
        XCTAssertTrue(layout.trailingAccessoryIsPinnedInsideColumn)
        XCTAssertFalse(layout.fixesLeadingControlWidth)
        XCTAssertEqual(
            SettingsTrailingAccessoryRowLayout.labelColumnWidth
                + SettingsTrailingAccessoryRowLayout.columnSpacing
                + SettingsTrailingAccessoryRowLayout.controlColumnWidth,
            SettingsTrailingAccessoryRowLayout.contentWidth
        )

        let field = NSTextField()
        let toggle = NSSwitch()
        let row = labeledTrailingAccessoryControlRow(
            title: "配置名称",
            control: field,
            accessory: toggle
        )
        let label = try XCTUnwrap(row.arrangedSubviews.first as? NSTextField)
        let controlColumn = try XCTUnwrap(row.arrangedSubviews.last as? NSStackView)

        XCTAssertEqual(row.arrangedSubviews.count, 2)
        XCTAssertEqual(label.stringValue, "配置名称")
        XCTAssertEqual(row.orientation, .horizontal)
        XCTAssertEqual(row.alignment, .centerY)
        XCTAssertEqual(row.spacing, CGFloat(SettingsTrailingAccessoryRowLayout.columnSpacing))
        XCTAssertEqual(controlColumn.arrangedSubviews.count, 2)
        XCTAssertTrue(controlColumn.arrangedSubviews[0] === field)
        XCTAssertTrue(controlColumn.arrangedSubviews[1] === toggle)
        XCTAssertEqual(controlColumn.orientation, .horizontal)
        XCTAssertEqual(controlColumn.alignment, .centerY)
        XCTAssertEqual(
            controlColumn.spacing,
            CGFloat(SettingsTrailingAccessoryRowLayout.controlAccessorySpacing)
        )
        XCTAssertLessThan(
            field.contentHuggingPriority(for: .horizontal).rawValue,
            toggle.contentHuggingPriority(for: .horizontal).rawValue
        )
        XCTAssertLessThan(
            field.contentCompressionResistancePriority(for: .horizontal).rawValue,
            toggle.contentCompressionResistancePriority(for: .horizontal).rawValue
        )
        XCTAssertFalse(field.constraints.contains {
            $0.firstAttribute == .width && $0.relation == .equal && $0.constant > 0
        })
        XCTAssertTrue(controlColumn.constraints.contains {
            $0.firstAttribute == .width
                && $0.constant == CGFloat(SettingsTrailingAccessoryRowLayout.controlColumnWidth)
        })
        XCTAssertTrue(row.constraints.contains {
            $0.firstAttribute == .width
                && $0.constant == CGFloat(SettingsTrailingAccessoryRowLayout.contentWidth)
        })

        row.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsTrailingAccessoryRowLayout.contentWidth,
            height: max(field.intrinsicContentSize.height, toggle.intrinsicContentSize.height)
        )
        row.layoutSubtreeIfNeeded()
        controlColumn.layoutSubtreeIfNeeded()
        let expectedFieldWidth = CGFloat(SettingsTrailingAccessoryRowLayout.controlColumnWidth)
            - CGFloat(SettingsTrailingAccessoryRowLayout.controlAccessorySpacing)
            - toggle.intrinsicContentSize.width
        XCTAssertEqual(field.frame.width, expectedFieldWidth, accuracy: 1)
        XCTAssertEqual(toggle.frame.maxX, controlColumn.bounds.maxX, accuracy: 1)
        XCTAssertGreaterThan(field.frame.width, toggle.frame.width)
    }

    func testUSBAndCollaborationMappingListsShareCenteredTwoColumnContract() {
        for count in [0, 1, 3] {
            let layouts = [
                SettingsMappingListLayout.usb(displayCount: count),
                SettingsMappingListLayout.collaboration(displayCount: count)
            ]
            XCTAssertEqual(layouts[0], layouts[1])
            for layout in layouts {
                XCTAssertEqual(layout.displayCount, count)
                XCTAssertEqual(SettingsMappingListLayout.title, "对端输入源")
                XCTAssertEqual(
                    SettingsMappingListLayout.labelColumnWidth,
                    SettingsFormRowLayout.labelColumnWidth
                )
                XCTAssertEqual(
                    SettingsMappingListLayout.listColumnWidth,
                    SettingsFormRowLayout.controlColumnWidth
                )
                XCTAssertTrue(layout.usesTwoColumnRow)
                XCTAssertTrue(layout.centersTitleAgainstListContainer)
                XCTAssertFalse(layout.usesManualVerticalOffset)
                XCTAssertEqual(layout.showsEmptyState, count == 0)
            }
        }
    }

    func testUSBAndCollaborationUseSameCenteredAppKitMappingRowForZeroOneAndManyDisplays() throws {
        for count in [0, 1, 3] {
            let layouts = [
                SettingsMappingListLayout.usb(displayCount: count),
                SettingsMappingListLayout.collaboration(displayCount: count)
            ]
            for layout in layouts {
                let list = NSStackView()
                if layout.showsEmptyState {
                    list.addArrangedSubview(NSTextField(labelWithString: "尚未检测到显示器。"))
                } else {
                    (0..<layout.displayCount).forEach { _ in list.addArrangedSubview(NSView()) }
                }

                let row = labeledVerticalControlRow(
                    title: SettingsMappingListLayout.title,
                    control: list
                )
                let title = try XCTUnwrap(row.arrangedSubviews.first as? NSTextField)

                XCTAssertEqual(row.orientation, .horizontal)
                XCTAssertEqual(row.alignment, .centerY)
                XCTAssertEqual(row.spacing, CGFloat(SettingsFormRowLayout.controlColumnSpacing))
                XCTAssertEqual(row.arrangedSubviews.count, 2)
                XCTAssertEqual(title.stringValue, "对端输入源")
                XCTAssertTrue(row.arrangedSubviews[1] === list)
                XCTAssertTrue(row.constraints.contains {
                    $0.firstAttribute == .width
                        && $0.constant == CGFloat(SettingsFormRowLayout.contentWidth)
                })
                XCTAssertTrue(list.constraints.contains {
                    $0.firstAttribute == .width
                        && $0.constant == CGFloat(SettingsFormRowLayout.controlColumnWidth)
                })
            }
        }
    }

    func testMergedUSBModuleShowsOnlyOneInlinePeerInputTitle() {
        let layout = SettingsPageLayoutProjection.usb(displays: [], learningInProgress: false)
        XCTAssertEqual(layout.groups.map(\.id), [.usbAutomation, .usbCollaboration])
        XCTAssertEqual(layout.groups.map { $0.id.title }, ["自动切换", "联动协同"])
        XCTAssertFalse(layout.groups.map { $0.id.title }.contains(SettingsMappingListLayout.title))
        XCTAssertEqual(SettingsMappingListLayout.title, "对端输入源")
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
            .collaborationStatus, .collaborationConfiguration
        ])
        XCTAssertEqual(layout.groups.map { $0.id.title }, ["协同状态", "配置"])
        XCTAssertEqual(layout.groups[0].rows.map(\.action), [
            nil, .requestLocalNetworkPermission, .inspectCollaboration
        ])
        XCTAssertEqual(Array(layout.groups[1].rows.prefix(3)).map(\.id), [
            "collaboration-selector", "collaboration-add",
            "collaboration-selection-details-separator"
        ])
        XCTAssertEqual(layout.groups[1].rows[2].kind, .separator)
        XCTAssertEqual(
            layout.groups[1].rows.filter { $0.kind == .separator }.map(\.id),
            [
                "collaboration-selection-details-separator",
                "collaboration-peer-inputs-separator",
                "collaboration-actions-separator"
            ]
        )
        XCTAssertEqual(
            layout.groups[1].rows.filter { $0.id.hasPrefix("collaboration-mapping-") }.map(\.title),
            displays.map(\.name)
        )
        XCTAssertTrue(layout.groups[1].rows.contains {
            $0.id == "collaboration-delete" && $0.action == .deleteCollaborationProfile && $0.isEnabled
        })
        XCTAssertFalse(layout.groups[1].rows.contains {
            $0.id == SettingsSaveStatusPresentation.rowID
        })
        XCTAssertEqual(layout.windowFooterRows.map(\.id), [SettingsSaveStatusPresentation.rowID])
        XCTAssertFalse(layout.windowFooterRows[0].isVisible)
        XCTAssertTrue(layout.scrollContentFooterRows.isEmpty)
        XCTAssertFalse(layout.groups[1].rows.contains { $0.id == "collaboration-move-up" })
        XCTAssertFalse(layout.groups[1].rows.contains { $0.id == "collaboration-move-down" })
        XCTAssertFalse(layout.groups[1].rows.contains { $0.title == "上移配置" })
        XCTAssertFalse(layout.groups[1].rows.contains { $0.title == "下移配置" })
    }

    func testCollaborationSaveStatusIsSingleBottomFooterWithSemanticPresentation() {
        XCTAssertEqual(SettingsSaveStatusPresentation.placement, .nonScrollingWindowFooter)
        XCTAssertTrue(SettingsSaveStatusPresentation.isNonScrollingWindowFooter)
        XCTAssertFalse(SettingsSaveStatusPresentation.isInsideScrollDocument)
        XCTAssertTrue(SettingsSaveStatusPresentation.isAnchoredToWindowBottom)
        XCTAssertFalse(SettingsSaveStatusPresentation.isInDetailsCard)
        XCTAssertEqual(SettingsSaveStatusPresentation.horizontalAlignment, .leading)
        XCTAssertEqual(SettingsSaveStatusPresentation.successVisibilityDuration, 2)

        let saved = SettingsSaveStatusPresentation.saved
        XCTAssertEqual(saved.text, "已保存")
        XCTAssertEqual(saved.symbolName, "checkmark.circle.fill")
        XCTAssertEqual(saved.textColor, .systemGreen)
        XCTAssertEqual(saved.iconColor, .systemGreen)
        XCTAssertEqual(saved.accessibilityLabel, "协同配置保存状态")
        XCTAssertEqual(saved.accessibilityValue, "已保存")

        let failed = SettingsSaveStatusPresentation.failedRestored
        XCTAssertEqual(failed.text, "保存失败，已恢复")
        XCTAssertEqual(failed.symbolName, "exclamationmark.circle.fill")
        XCTAssertEqual(failed.textColor, .systemRed)
        XCTAssertEqual(failed.iconColor, .systemRed)
        XCTAssertEqual(failed.accessibilityLabel, "协同配置保存状态")
        XCTAssertEqual(failed.accessibilityValue, "保存失败，已恢复")

        let layout = SettingsPageLayoutProjection.collaboration(
            displays: [mappingDisplay(id: "display-a", name: "模拟显示器")],
            hasSelectedProfile: true,
            profileCount: 1,
            selectedProfileIndex: 0,
            inspectionInProgress: false,
            saveFeedbackState: .visible(.saved)
        )
        XCTAssertTrue(layout.scrollContentFooterRows.isEmpty)
        XCTAssertEqual(layout.windowFooterRows.map(\.id), [SettingsSaveStatusPresentation.rowID])
        XCTAssertTrue(layout.windowFooterRows[0].isVisible)
        XCTAssertFalse(layout.groups.flatMap(\.rows).contains {
            $0.id == SettingsSaveStatusPresentation.rowID
        })
    }

    func testSaveFeedbackIsInitiallyHiddenAndSuccessfulSaveAutoHidesAfterTwoSeconds() {
        let scheduler = ManualSettingsSaveFeedbackScheduler()
        var states: [SettingsSaveFeedbackState] = []
        let controller = SettingsSaveFeedbackController(scheduler: scheduler) { scope, state in
            XCTAssertEqual(scope, .collaboration)
            states.append(state)
        }

        XCTAssertEqual(controller.state, .hidden)
        XCTAssertTrue(states.isEmpty)

        controller.recordPersistenceResult(.succeeded, scope: .collaboration)

        XCTAssertEqual(controller.state, .visible(.saved))
        XCTAssertEqual(states, [.visible(.saved)])
        XCTAssertEqual(scheduler.tasks.map(\.delay), [2])
        XCTAssertFalse(scheduler.tasks[0].isCancelled)

        scheduler.tasks[0].fireEvenIfCancelled()

        XCTAssertEqual(controller.state, .hidden)
        XCTAssertEqual(states, [.visible(.saved), .hidden])
    }

    func testConsecutiveSuccessfulSavesCancelAndSupersedePreviousHide() {
        let scheduler = ManualSettingsSaveFeedbackScheduler()
        let controller = SettingsSaveFeedbackController(scheduler: scheduler)

        controller.recordPersistenceResult(.succeeded, scope: .collaboration)
        controller.recordPersistenceResult(.succeeded, scope: .collaboration)

        XCTAssertEqual(scheduler.tasks.count, 2)
        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        XCTAssertFalse(scheduler.tasks[1].isCancelled)

        scheduler.tasks[0].fireEvenIfCancelled()
        XCTAssertEqual(controller.state, .visible(.saved))

        scheduler.tasks[1].fireEvenIfCancelled()
        XCTAssertEqual(controller.state, .hidden)
    }

    func testSaveFailurePersistsUntilNextSuccessThenUsesFreshAutoHide() {
        let scheduler = ManualSettingsSaveFeedbackScheduler()
        let controller = SettingsSaveFeedbackController(scheduler: scheduler)

        controller.recordPersistenceResult(.succeeded, scope: .collaboration)
        controller.recordPersistenceResult(.failed, scope: .collaboration)

        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        XCTAssertEqual(controller.state, .visible(.failedRestored))
        scheduler.tasks[0].fireEvenIfCancelled()
        XCTAssertEqual(controller.state, .visible(.failedRestored))

        controller.recordPersistenceResult(.succeeded, scope: .collaboration)

        XCTAssertEqual(controller.state, .visible(.saved))
        XCTAssertEqual(scheduler.tasks.count, 2)
        scheduler.tasks[1].fireEvenIfCancelled()
        XCTAssertEqual(controller.state, .hidden)
    }

    func testSaveFeedbackResetCancelsPendingHideAndReturnsToInitialHiddenState() {
        let scheduler = ManualSettingsSaveFeedbackScheduler()
        let controller = SettingsSaveFeedbackController(scheduler: scheduler)

        controller.recordPersistenceResult(.succeeded, scope: .collaboration)
        controller.reset()

        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        XCTAssertEqual(controller.state, .hidden)
        scheduler.tasks[0].fireEvenIfCancelled()
        XCTAssertEqual(controller.state, .hidden)
    }

    func testNavigationDismissesOnlyTransientSuccessAndPreservesFailure() {
        let scheduler = ManualSettingsSaveFeedbackScheduler()
        let controller = SettingsSaveFeedbackController(scheduler: scheduler)

        controller.recordPersistenceResult(.succeeded, scope: .collaboration)
        controller.dismissTransientSuccess()

        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        XCTAssertEqual(controller.state, .hidden)

        controller.recordPersistenceResult(.failed, scope: .collaboration)
        controller.dismissTransientSuccess()

        XCTAssertEqual(controller.state, .visible(.failedRestored))
    }

    func testSaveFeedbackControllerReleaseCancelsPendingHideSafely() {
        let scheduler = ManualSettingsSaveFeedbackScheduler()
        var controller: SettingsSaveFeedbackController? = SettingsSaveFeedbackController(scheduler: scheduler)

        controller?.recordPersistenceResult(.succeeded, scope: .collaboration)
        controller = nil

        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        scheduler.tasks[0].fireEvenIfCancelled()
    }

    func testNonCollaborationPersistenceResultsNeverPolluteCollaborationFeedback() {
        let scheduler = ManualSettingsSaveFeedbackScheduler()
        let controller = SettingsSaveFeedbackController(scheduler: scheduler)

        controller.recordPersistenceResult(.succeeded, scope: .none)
        controller.recordPersistenceResult(.failed, scope: .none)

        XCTAssertEqual(controller.state, .hidden)
        XCTAssertTrue(scheduler.tasks.isEmpty)

        controller.recordPersistenceResult(.failed, scope: .collaboration)
        controller.recordPersistenceResult(.succeeded, scope: .none)
        controller.recordPersistenceResult(.failed, scope: .none)

        XCTAssertEqual(controller.state, .visible(.failedRestored))
        XCTAssertTrue(scheduler.tasks.isEmpty)

        controller.recordPersistenceResult(.succeeded, scope: .collaboration)
        controller.recordPersistenceResult(.failed, scope: .none)

        XCTAssertEqual(controller.state, .visible(.saved))
        XCTAssertEqual(scheduler.tasks.count, 1)
        XCTAssertFalse(scheduler.tasks[0].isCancelled)
    }

    func testUSBAndCollaborationSaveFeedbackRemainIndependent() {
        let scheduler = ManualSettingsSaveFeedbackScheduler()
        let controller = SettingsSaveFeedbackController(scheduler: scheduler)

        XCTAssertEqual(controller.state(for: .usb), .hidden)
        XCTAssertEqual(controller.state(for: .collaboration), .hidden)

        controller.recordPersistenceResult(.failed, scope: .usb)
        XCTAssertEqual(controller.state(for: .usb), .visible(.failedRestored(scope: .usb)))
        XCTAssertEqual(controller.state(for: .collaboration), .hidden)
        XCTAssertTrue(scheduler.tasks.isEmpty)

        controller.recordPersistenceResult(.succeeded, scope: .collaboration)
        XCTAssertEqual(controller.state(for: .usb), .visible(.failedRestored(scope: .usb)))
        XCTAssertEqual(
            controller.state(for: .collaboration), .visible(.saved(scope: .collaboration))
        )
        XCTAssertEqual(scheduler.tasks.count, 1)

        controller.recordPersistenceResult(.succeeded, scope: .usb)
        XCTAssertEqual(controller.state(for: .usb), .visible(.saved(scope: .usb)))
        XCTAssertEqual(scheduler.tasks.count, 2)
        scheduler.tasks[0].fireEvenIfCancelled()
        XCTAssertEqual(controller.state(for: .usb), .visible(.saved(scope: .usb)))
        XCTAssertEqual(controller.state(for: .collaboration), .hidden)
        scheduler.tasks[1].fireEvenIfCancelled()
        XCTAssertEqual(controller.state(for: .usb), .hidden)
    }

    func testUSBFailureCancelsTimerAndPersistsUntilNextUSBSuccess() {
        let scheduler = ManualSettingsSaveFeedbackScheduler()
        let controller = SettingsSaveFeedbackController(scheduler: scheduler)

        controller.recordPersistenceResult(.succeeded, scope: .usb)
        controller.recordPersistenceResult(.failed, scope: .usb)

        XCTAssertTrue(scheduler.tasks[0].isCancelled)
        scheduler.tasks[0].fireEvenIfCancelled()
        XCTAssertEqual(controller.state(for: .usb), .visible(.failedRestored(scope: .usb)))

        controller.recordPersistenceResult(.succeeded, scope: .usb)
        XCTAssertEqual(controller.state(for: .usb), .visible(.saved(scope: .usb)))
        XCTAssertEqual(scheduler.tasks.count, 2)
    }

    func testUSBSaveStatusUsesSameFixedLeadingFooterContract() {
        let layout = SettingsPageLayoutProjection.usb(
            displays: [mappingDisplay(id: "display-a", name: "模拟显示器")],
            learningInProgress: false,
            saveFeedbackState: .visible(.saved(scope: .usb))
        )

        XCTAssertEqual(layout.windowFooterRows.map(\.id), [SettingsSaveStatusPresentation.rowID])
        XCTAssertTrue(layout.windowFooterRows[0].isVisible)
        XCTAssertTrue(layout.scrollContentFooterRows.isEmpty)
        XCTAssertFalse(layout.groups.flatMap(\.rows).contains {
            $0.id == SettingsSaveStatusPresentation.rowID
        })
        XCTAssertEqual(SettingsSaveStatusPresentation.saved(scope: .usb).accessibilityLabel,
                       "USB 配置保存状态")
    }

    func testInputSourceFieldsTreatBlankAsMissingAndRejectZeroOrOverflow() {
        XCTAssertEqual(InputSourceValuePolicy.parseField(""), .empty)
        XCTAssertEqual(InputSourceValuePolicy.parseField("  \n"), .empty)
        XCTAssertEqual(InputSourceValuePolicy.parseField("17"), .valid(17))
        for value in ["0", "-1", "65536", "not-a-number", "999999999999999999999"] {
            XCTAssertEqual(InputSourceValuePolicy.parseField(value), .invalid)
        }
    }

    func testUnchangedPersistenceDoesNotCreateSaveFeedbackEvent() {
        XCTAssertFalse(SettingsPersistenceFeedbackPolicy.hasActualChange(from: 17, to: 17))
        XCTAssertTrue(SettingsPersistenceFeedbackPolicy.hasActualChange(from: 17, to: 18))
    }

    func testCollaborationSettingsVisibilityAndInspectionEnablementAreConservative() {
        let empty = SettingsPageLayoutProjection.collaboration(
            displays: [], hasSelectedProfile: false, profileCount: 0,
            selectedProfileIndex: 0,
            inspectionInProgress: false
        )
        XCTAssertTrue(empty.groups[1].rows.dropFirst(2).allSatisfy { !$0.isVisible })
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
        XCTAssertFalse(checking.groups[1].rows.first {
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
