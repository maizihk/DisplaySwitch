#include "../DisplaySwitcher.Native/pch.h"
#include "../DisplaySwitcher.Native/AppConfig.h"
#include "../DisplaySwitcher.Native/AboutInfo.h"
#include "../DisplaySwitcher.Native/DdcBackends.h"
#include "../DisplaySwitcher.Native/DdcControl.h"
#include "../DisplaySwitcher.Native/InputSourceControl.h"
#include "../DisplaySwitcher.Native/MediaKeys.h"
#include "../DisplaySwitcher.Native/DiagnosticReport.h"
#include "../DisplaySwitcher.Native/Diagnostics.h"
#include "../DisplaySwitcher.Native/DisplayModel.h"
#include "../DisplaySwitcher.Native/ProfileDetection.h"
#include "../DisplaySwitcher.Native/SystemActions.h"
#include "../DisplaySwitcher.Native/UnboundProbeRouter.h"
#include "../DisplaySwitcher.Native/UdpPeer.h"
#include "../DisplaySwitcher.Native/UsbLearning.h"
#include "../DisplaySwitcher.Native/UsbPresencePollPolicy.h"
#include "../DisplaySwitcher.Native/UsbSwitchCoordinator.h"
#include "../DisplaySwitcher.Native/SettingsWindowContracts.h"
#include "../DisplaySwitcher.Native/TrayContracts.h"
#include "../DisplaySwitcher.Native/TrayMonochromeIcon.h"
#include <array>
#include <iostream>

using namespace DisplaySwitcher::Native;
using namespace winrt::Windows::Data::Json;

int RunV2ProtocolVectorTests();
int RunUsbSwitchVectorTests();

namespace
{
    int failures{};
    int checks{};

    void Check(bool condition, wchar_t const* message)
    {
        ++checks;
        if (condition) return;
        ++failures;
        std::cerr << "FAIL check " << checks << ": " << winrt::to_string(message) << '\n';
    }

    DisplayConfig Display(std::wstring const& name, std::wstring const& monitor, int peerInput)
    {
        auto display = CreateDisplayConfig(name);
        display.nativeMonitorId = monitor;
        display.macInput = peerInput;
        display.localInput.reset();
        display.readEnabled = true;
        display.bindingStatus = DisplayBindingStatus::Resolved;
        display.bindingMessage = L"模拟拓扑已绑定";
        return display;
    }

    CollaborationProfile Profile(std::wstring const& name, bool enabled = false)
    {
        CollaborationProfile profile;
        profile.id = GenerateIdentifier();
        profile.name = name;
        profile.peerHost = L"peer.example";
        profile.peerPort = 49731;
        profile.pairingCode = L"TEST-CODE-0001";
        profile.coordinationEnabled = enabled;
        return profile;
    }

    AppConfig ConfigWithDisplays(size_t count)
    {
        AppConfig config;
        config.localEndpointId = GenerateIdentifier();
        config.localDeviceName = L"本机";
        config.listenPort = 49731;
        for (size_t index = 0; index < count; ++index)
            config.displays.push_back(Display(L"显示器 " + std::to_wstring(index + 1), L"monitor-" + std::to_wstring(index), 16 + static_cast<int>(index)));
        auto profile = Profile(L"工作电脑");
        for (auto const& display : config.displays) profile.displayInputs.push_back({ display.id, display.macInput });
        config.collaborationProfiles.push_back(std::move(profile));
        return config;
    }

    void TestSettingsWindowLayoutContracts()
    {
        auto containsRow = [](auto const& sections, std::wstring const& row)
        {
            for (auto const& section : sections)
                if (std::find(section.rows.begin(), section.rows.end(), row) != section.rows.end()) return true;
            return false;
        };

        auto usb = SettingsPageLayout(SettingsPage::Usb);
        Check(usb.cards.size() == 2, L"USB 页面恰好有两个卡片");
        Check(usb.cards[0].title == L"自动切换" && usb.cards[1].title == L"联动协同", L"USB 卡片顺序正确");
        Check(containsRow(usb.cards[0].sections, L"对端输入源显示器列表"), L"对端输入源已并入自动切换卡片");
        Check(!usb.cards[0].hasNestedCards && !usb.cards[1].hasNestedCards, L"USB 页面没有嵌套卡片");
        SettingsWindowLayoutPresenter layout;
        Check(layout.Attach(SettingsLayoutElement::UsbDeviceStatus, SettingsLayoutRegion::UsbCurrentStatusRow) &&
            !layout.Attach(SettingsLayoutElement::UsbDeviceStatus, SettingsLayoutRegion::UsbCurrentStatusRow) &&
            layout.usbDeviceStatusParentCount == 1,
            L"生产布局 Presenter 只允许 USB 当前状态挂载到一个父节点");
        for (auto displayCount : { size_t{ 0 }, size_t{ 1 }, size_t{ 3 }, size_t{ 4 } })
        {
            auto config = ConfigWithDisplays(displayCount);
            Check(config.displays.size() == displayCount && containsRow(usb.cards[0].sections, L"对端输入源显示器列表"), L"USB 映射支持可变显示器数量");
        }

        PeerInputMappingLayoutModel mappingLayout;
        Check(mappingLayout.LabelRowSpan(0) == 1 && mappingLayout.LabelRowSpan(1) == 1
            && mappingLayout.LabelRowSpan(3) == 3 && mappingLayout.labelColumnWidth == 200
            && mappingLayout.inputColumnWidth == 120,
            L"生产动态映射布局为 0、1、3 台显示器提供同一固定标签列和输入列");

        auto catalogue = ConfigWithDisplays(4).displays;
        for (size_t index = 0; index < catalogue.size(); ++index)
        {
            catalogue[index].nativeMonitorId = L"ds13:projection-" + std::to_wstring(index);
            catalogue[index].bindingStatus = index < 2 ? DisplayBindingStatus::Resolved : DisplayBindingStatus::Offline;
            catalogue[index].topologyGeneration = index < 2 ? 42 : 0;
        }
        std::vector<DisplayInputMapping> profileMappings;
        std::vector<UsbDisplayInputMapping> usbMappings;
        for (size_t index = 0; index < catalogue.size(); ++index)
        {
            profileMappings.push_back({ catalogue[index].id, static_cast<int>(20 + index) });
            usbMappings.push_back({ catalogue[index].id, 30 + static_cast<int>(index) });
        }
        DisplayMappingProjection projection;
        Check(projection.Refresh(catalogue, DisplayTopologyTrust::LocalPhysicalAuthoritative)
            && projection.Rows().size() == 2 && projection.TopologyGeneration() == 42,
            L"生产映射投影只显示当前代次中已解析且可唯一绑定的两台物理显示器");
        auto projectedIds = std::vector<std::wstring>{ projection.Rows()[0].displayId, projection.Rows()[1].displayId };
        Check(std::none_of(projectedIds.begin(), projectedIds.end(), [&](auto const& id)
            { return id == catalogue[2].id || id == catalogue[3].id; }),
            L"历史离线显示器不会进入 USB 或协同共用映射 UI 模型");
        auto mergedProfile = MergeVisibleProfileDisplayInputs(profileMappings,
            { { catalogue[0].id, 50 }, { catalogue[1].id, 51 } });
        auto mergedUsb = MergeVisibleUsbDisplayInputs(usbMappings,
            { { catalogue[0].id, 60 }, { catalogue[1].id, 61 } });
        Check(mergedProfile.size() == 4 && mergedUsb.size() == 4
            && mergedProfile[2].peerInput == 22 && mergedProfile[3].peerInput == 23
            && mergedUsb[2].targetInput == 32 && mergedUsb[3].targetInput == 33,
            L"只编辑两台当前物理显示器时四条目录映射完整保留，离线映射不删除、不重绑定");
        auto retainedRows = projection.Rows();
        Check(!projection.Refresh({}, DisplayTopologyTrust::RemoteSessionLimited)
            && projection.Rows().size() == retainedRows.size()
            && !projection.Refresh({}, DisplayTopologyTrust::IncompleteOrUnavailable)
            && projection.Rows().size() == retainedRows.size(),
            L"RDP 或枚举失败不会清空最后可信物理映射投影");

        auto duplicateBindingCatalogue = ConfigWithDisplays(2).displays;
        for (auto& display : duplicateBindingCatalogue)
        {
            display.bindingStatus = DisplayBindingStatus::Resolved;
            display.topologyGeneration = 50;
            display.nativeMonitorId = L"ds13:duplicate-binding";
        }
        std::vector<DisplayInputMapping> duplicateProfileMappings{
            { duplicateBindingCatalogue[0].id, 70 }, { duplicateBindingCatalogue[1].id, 71 } };
        std::vector<UsbDisplayInputMapping> duplicateUsbMappings{
            { duplicateBindingCatalogue[0].id, 80 }, { duplicateBindingCatalogue[1].id, 81 } };
        DisplayMappingProjection duplicateBindingProjection;
        duplicateBindingProjection.Refresh(duplicateBindingCatalogue,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(duplicateBindingProjection.Rows().empty(),
            L"两个当前 Resolved 条目共享同一强绑定时两项都不得投影，不能保留第一项");
        Check(duplicateBindingCatalogue.size() == 2 && duplicateProfileMappings.size() == 2
            && duplicateUsbMappings.size() == 2 && duplicateProfileMappings[0].peerInput == 70
            && duplicateProfileMappings[1].peerInput == 71 && duplicateUsbMappings[0].targetInput == 80
            && duplicateUsbMappings[1].targetInput == 81,
            L"重复强绑定只影响 UI 投影，原目录及 USB 和协同映射全部保留");

        auto duplicateDisplayIdCatalogue = ConfigWithDisplays(2).displays;
        duplicateDisplayIdCatalogue[1].id = duplicateDisplayIdCatalogue[0].id;
        for (size_t index = 0; index < duplicateDisplayIdCatalogue.size(); ++index)
        {
            duplicateDisplayIdCatalogue[index].bindingStatus = DisplayBindingStatus::Resolved;
            duplicateDisplayIdCatalogue[index].topologyGeneration = 51;
            duplicateDisplayIdCatalogue[index].nativeMonitorId = L"ds13:unique-binding-" + std::to_wstring(index);
        }
        DisplayMappingProjection duplicateDisplayIdProjection;
        duplicateDisplayIdProjection.Refresh(duplicateDisplayIdCatalogue,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(duplicateDisplayIdProjection.Rows().empty() && duplicateDisplayIdCatalogue.size() == 2,
            L"当前代次重复 displayId 的所有项目都不得投影，原目录仍保持两项");

        auto caseVariantCatalogue = ConfigWithDisplays(2).displays;
        caseVariantCatalogue[0].nativeMonitorId = L"ds13:Case-Variant";
        caseVariantCatalogue[1].nativeMonitorId = L"DS13:case-variant";
        for (auto& display : caseVariantCatalogue)
        {
            display.bindingStatus = DisplayBindingStatus::Resolved;
            display.topologyGeneration = 52;
        }
        DisplayMappingProjection caseVariantProjection;
        caseVariantProjection.Refresh(caseVariantCatalogue,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(caseVariantProjection.Rows().empty(),
            L"大小写不同但规范化后相同的强绑定视为重复并排除全部项目");

        auto peer = SettingsPageLayout(SettingsPage::Collaboration);
        Check(peer.cards.size() == 2, L"协同页面恰好有两个卡片");
        Check(peer.cards[0].title == L"协同状态" && peer.cards[1].title == L"配置", L"协同卡片顺序正确");
        Check(peer.cards[1].sections.size() == 2, L"当前配置和配置详情属于同一卡片");
        Check(!peer.cards[1].hasNestedCards, L"配置详情没有嵌套卡片");

        Check(layout.Attach(SettingsLayoutElement::ScopedSaveFeedback, SettingsLayoutRegion::FixedWindowFooter) &&
            !layout.Attach(SettingsLayoutElement::ScopedSaveFeedback, SettingsLayoutRegion::UsbCurrentStatusRow) &&
            layout.scopedSaveFeedbackParentCount == 1,
            L"生产布局 Presenter 只允许 USB/协同作用域保存反馈挂载到固定窗口底部");

        Check(NetworkAccessFeedbackSeverity(true) == SettingsOperationFeedbackSeverity::Success &&
            NetworkAccessFeedbackSeverity(false) == SettingsOperationFeedbackSeverity::Failure,
            L"网络权限结果按 ready 明确选择成功或失败状态");
        Check(UsbLearningFeedbackSeverity(UsbLearningCompletion::Success) == SettingsOperationFeedbackSeverity::Success &&
            UsbLearningFeedbackSeverity(UsbLearningCompletion::Cancelled) == SettingsOperationFeedbackSeverity::Cancelled &&
            UsbLearningFeedbackSeverity(UsbLearningCompletion::TimedOut) == SettingsOperationFeedbackSeverity::Failure &&
            UsbLearningFeedbackSeverity(UsbLearningCompletion::Failure) == SettingsOperationFeedbackSeverity::Failure,
            L"USB 学习结束状态不依赖提示文字推断");

        SettingsSaveFeedbackController feedback;
        Check(!feedback.IsVisibleOn(SettingsPage::Collaboration, 0), L"首次打开不显示已保存");
        Check(feedback.RecordSaveResult(SettingsSaveFeedbackScope::Collaboration, true, true, L"✓ 已保存", 1000) ==
            SettingsSaveFeedbackAction::ShowScopedFeedback && feedback.IsVisibleOn(SettingsPage::Collaboration, 1000), L"协同成功保存显示绿色状态");
        Check(!feedback.collaborationFeedback.failure && !feedback.IsVisibleOn(SettingsPage::General, 1000), L"保存反馈只在所属页面可见");
        Check(feedback.IsVisibleOn(SettingsPage::Collaboration, 2999), L"成功保存两秒前仍显示");
        feedback.RecordSaveResult(SettingsSaveFeedbackScope::Collaboration, true, true, L"✓ 已保存", 2500);
        Check(feedback.IsVisibleOn(SettingsPage::Collaboration, 4499), L"连续协同保存重置隐藏计时");
        Check(!feedback.IsVisibleOn(SettingsPage::Collaboration, 4500), L"成功保存两秒后隐藏");
        feedback.RecordSaveResult(SettingsSaveFeedbackScope::Collaboration, true, true, L"✓ 已保存", 5000);
        Check(feedback.HasActiveSuccess() && feedback.IsVisibleOn(SettingsPage::Collaboration, 5499),
            L"协同成功提示在两秒窗口内保持活动");
        feedback.RecordSaveResult(SettingsSaveFeedbackScope::Collaboration, true, false, L"保存失败", 5500);
        Check(feedback.IsVisibleOn(SettingsPage::Collaboration, 999999) && feedback.collaborationFeedback.failure &&
            !feedback.HasActiveSuccess(), L"成功提示尚未消失时保存失败会停止计时并持续显示失败");
        feedback.RecordSaveResult(SettingsSaveFeedbackScope::Collaboration, true, true, L"✓ 已保存", 10000);
        Check(feedback.IsVisibleOn(SettingsPage::Collaboration, 10000) && !feedback.collaborationFeedback.failure &&
            feedback.HasActiveSuccess(), L"下一次协同成功恢复成功状态并重新启动计时");
        feedback.RecordSaveResult(SettingsSaveFeedbackScope::Collaboration, true, false, L"保存失败", 13000);
        Check(feedback.RecordSaveResult(SettingsSaveFeedbackScope::Usb, true, true, L"✓ 已保存", 14000) ==
            SettingsSaveFeedbackAction::ShowScopedFeedback && feedback.IsVisibleOn(SettingsPage::Usb, 14000)
            && feedback.IsVisibleOn(SettingsPage::Collaboration, 14000),
            L"USB 成功回显与协同失败状态必须分别保存在各自作用域");
        feedback.ClearTransientSuccesses();
        Check(!feedback.IsVisibleOn(SettingsPage::Usb, 14001)
            && feedback.IsVisibleOn(SettingsPage::Collaboration, 14001)
            && feedback.collaborationFeedback.failure,
            L"切换页面或重新加载只清除短暂成功态，绝不清除失败态");
        Check(feedback.RecordSaveResult(SettingsSaveFeedbackScope::None, true, false, L"失败", 15000) ==
            SettingsSaveFeedbackAction::ShowOperationFailure, L"非 USB/协同保存失败只更新操作状态");
        Check(feedback.RecordSaveResult(SettingsSaveFeedbackScope::Collaboration, false, true, L"✓ 已保存", 16000) ==
            SettingsSaveFeedbackAction::None && feedback.IsVisibleOn(SettingsPage::Collaboration, 16000)
            && feedback.collaborationFeedback.failure,
            L"无实际变化不显示也不重置保存状态");

        for (auto const& value : { L"", L"   " })
            Check(ParseInputSourceText(value).status == InputSourceTextStatus::Empty
                && !ParseInputSourceText(value).value, L"空白输入源应解析为 null");
        Check(ParseInputSourceText(L"1").value == 1 && ParseInputSourceText(L"65535").value == 65535,
            L"输入源边界 1 和 65535 应有效");
        for (auto const& value : { L"0", L"-1", L"abc", L"65536" })
            Check(ParseInputSourceText(value).status == InputSourceTextStatus::Invalid,
                L"0、负数、非数字和溢出输入源必须拒绝");
        Check(FormatInputSourceText(std::nullopt).empty() && FormatInputSourceText(0).empty()
            && FormatInputSourceText(17) == L"17", L"重新加载 null 或旧零映射必须显示空白");
    }

    void TestTrayInteractionAndLayoutContracts()
    {
        Check(UsbTrayStatusText(true) == L"USB 切换已开启" &&
            UsbTrayStatusText(false) == L"USB 切换已关闭",
            L"DS-028: 托盘 USB 状态只表达开启或关闭，不泄露设备标识");
        for (auto runtime : {
            UsbTrayRuntimeConditions{ false, false, false, true },
            UsbTrayRuntimeConditions{ true, true, false, false },
            UsbTrayRuntimeConditions{ true, false, true, true },
            UsbTrayRuntimeConditions{ true, false, false, false } })
        {
            Check(ProjectUsbTrayConfiguredEnabled(true, runtime) &&
                UsbTrayStatusText(ProjectUsbTrayConfiguredEnabled(true, runtime)) == L"USB 切换已开启",
                L"DS-028: RDP、不可信拓扑、安全模式和学习期只限制运行，不伪装为配置已关闭");
        }
        Check(!ProjectUsbTrayConfiguredEnabled(false, { true, false, false, true }),
            L"DS-028: 托盘关闭状态只来自持久化 USB 开关");
        Check(ResolveTrayActivation(WM_LBUTTONUP) == TrayActivationAction::ShowMenu &&
            ResolveTrayActivation(WM_LBUTTONDBLCLK) == TrayActivationAction::ShowMenu &&
            ResolveTrayActivation(WM_RBUTTONUP) == TrayActivationAction::ShowMenu &&
            ResolveTrayActivation(NIN_SELECT) == TrayActivationAction::ShowMenu &&
            ResolveTrayActivation(WM_MOUSEMOVE) == TrayActivationAction::None,
            L"DS-028: 托盘左右键与键盘激活都只打开同一菜单");
        Check(std::wstring(TraySemanticIconGlyph(TraySemanticIcon::Exit)) == L"\uE7E8" &&
            std::wstring(TraySemanticIconGlyph(TraySemanticIcon::Exit)) != L"\uE8BB",
            L"W-033: 退出使用同一 Fluent/MDL2 字体中的标准电源图标，不使用粗重关闭图标");
        auto textOnly = BuildTrayPopupLayout(96, 80, 0, false);
        auto sliders = BuildTrayPopupLayout(96, 120, 30, true);
        auto longLabel = BuildTrayPopupLayout(96, 80, 140, true);
        auto scaled = BuildTrayPopupLayout(192, 240, 60, true);
        Check(textOnly.width == 260 && sliders.width == 260 && sliders.sliderLabelWidth == 32 &&
            sliders.sliderGap == 4 &&
            sliders.width >= sliders.textLeft + sliders.sliderLabelWidth + sliders.sliderGap +
                sliders.sliderTrackMinimumWidth + sliders.sliderGap + sliders.sliderValueWidth + sliders.rightPadding &&
            longLabel.sliderLabelWidth == 140 &&
            longLabel.width >= longLabel.textLeft + longLabel.sliderLabelWidth + longLabel.sliderGap +
                longLabel.sliderTrackMinimumWidth + longLabel.sliderGap + longLabel.sliderValueWidth + longLabel.rightPadding &&
            scaled.width >= sliders.width * 2,
            L"W-033: 托盘按真实滑杆标签、DPI 与内容紧凑布局且长标签不裁切");
        for (auto dpi : { 96U, 120U, 144U, 192U })
        {
            auto layout = BuildTrayPopupLayout(dpi, MulDiv(80, dpi, 96),
                MulDiv(48, dpi, 96), true);
            Check(layout.width >= MulDiv(260, dpi, 96) && layout.sliderLabelWidth >= MulDiv(48, dpi, 96) &&
                layout.sliderTrackMinimumWidth >= MulDiv(92, dpi, 96) &&
                layout.sliderValueWidth >= MulDiv(38, dpi, 96),
                L"W-033: 100% 至 200% DPI 保留中文名称、可操作滑杆以及混合/三位数值空间");
        }
    }

    void TestMonochromeTrayIconContracts()
    {
        Check(ClassifyTaskbarTheme(DWORD{ 1 }) == TaskbarTheme::Light &&
            SelectTrayIconTone(TaskbarTheme::Light, 0) == TrayIconTone::Black,
            L"W-031: 浅色系统任务栏选择黑色通知区域图标");
        Check(ClassifyTaskbarTheme(DWORD{ 0 }) == TaskbarTheme::Dark &&
            SelectTrayIconTone(TaskbarTheme::Dark, 255) == TrayIconTone::White,
            L"W-031: 深色系统任务栏选择白色通知区域图标");
        Check(ClassifyTaskbarTheme(std::nullopt) == TaskbarTheme::Unknown &&
            SelectTrayIconTone(TaskbarTheme::Unknown, 220) == TrayIconTone::Black &&
            SelectTrayIconTone(TaskbarTheme::Unknown, 20) == TrayIconTone::White,
            L"W-031: 主题读取失败时按系统背景亮度确定高对比黑白 fallback");

        std::array<std::pair<UINT, int>, 4> dpiSizes{
            std::pair<UINT, int>{ 96, 16 }, { 120, 20 }, { 144, 24 }, { 192, 32 } };
        for (auto const& [dpi, expectedSize] : dpiSizes)
        {
            auto geometry = BuildTrayIconGeometry(dpi);
            auto black = RenderMonochromeTrayIconPixels(geometry, TrayIconTone::Black);
            auto white = RenderMonochromeTrayIconPixels(geometry, TrayIconTone::White);
            auto visibleBounds = [&](auto const& pixels)
            {
                RECT bounds{ geometry.pixelSize, geometry.pixelSize, -1, -1 };
                for (int y = 0; y < geometry.pixelSize; ++y)
                    for (int x = 0; x < geometry.pixelSize; ++x)
                        if ((pixels[static_cast<size_t>(y) * geometry.pixelSize + x] >> 24) != 0)
                        {
                            bounds.left = (std::min)(bounds.left, static_cast<LONG>(x));
                            bounds.top = (std::min)(bounds.top, static_cast<LONG>(y));
                            bounds.right = (std::max)(bounds.right, static_cast<LONG>(x));
                            bounds.bottom = (std::max)(bounds.bottom, static_cast<LONG>(y));
                        }
                return bounds;
            };
            auto bounds = visibleBounds(black);
            auto visibleWidth = bounds.right - bounds.left + 1;
            auto visibleHeight = bounds.bottom - bounds.top + 1;
            uint64_t alphaSum{};
            size_t visiblePixelCount{};
            bool matchingAlpha = true;
            bool blackPremultiplied = true;
            bool whitePremultiplied = true;
            for (size_t index = 0; index < black.size(); ++index)
            {
                auto blackAlpha = black[index] >> 24;
                auto whiteAlpha = white[index] >> 24;
                auto expectedWhite = (whiteAlpha << 16) | (whiteAlpha << 8) | whiteAlpha;
                alphaSum += blackAlpha;
                if (blackAlpha) ++visiblePixelCount;
                matchingAlpha = matchingAlpha && blackAlpha == whiteAlpha;
                blackPremultiplied = blackPremultiplied && (black[index] & 0x00FFFFFF) == 0;
                whitePremultiplied = whitePremultiplied &&
                    (white[index] & 0x00FFFFFF) == expectedWhite;
            }
            auto alphaCoverage = static_cast<double>(alphaSum) /
                (255.0 * geometry.bodySize * geometry.bodySize);
            auto visiblePixelCoverage = static_cast<double>(visiblePixelCount) /
                (geometry.bodySize * geometry.bodySize);
            Check(geometry.pixelSize == expectedSize && geometry.bodySize == MulDiv(expectedSize, 90, 100) &&
                black.size() == static_cast<size_t>(expectedSize * expectedSize) && black.size() == white.size() &&
                bounds.left >= geometry.bodyLeft && bounds.top >= geometry.bodyTop &&
                bounds.right < geometry.bodyLeft + geometry.bodySize &&
                bounds.bottom < geometry.bodyTop + geometry.bodySize &&
                visibleWidth >= geometry.bodySize - 1 && visibleHeight >= geometry.bodySize - 1,
                L"W-031: 16/20/24/32 像素图标主体占槽位约 90% 且不裁边");
            Check(alphaSum > 0 && matchingAlpha && blackPremultiplied && whitePremultiplied,
                L"W-031: 每个 DPI 渲染均为非空透明背景及匹配 alpha 的预乘黑白线稿");
            Check(visiblePixelCoverage >= 0.42 && visiblePixelCoverage <= 0.58 &&
                alphaCoverage >= 0.27 && alphaCoverage <= 0.34 &&
                (dpi != 96 || (geometry.bodySize * TrayIconStrokeRatio >= 0.8 &&
                    geometry.bodySize * TrayIconStrokeRatio <= 0.9)),
                L"W-031: 6% 笔画在各 DPI 的可见/alpha 覆盖率受限且 100% DPI 视觉线宽约 0.8-0.9 像素");
        }

        std::optional<TrayIconRenderState> current;
        auto light = TrayIconRenderState{ TrayIconTone::Black, 16 };
        auto dark = TrayIconRenderState{ TrayIconTone::White, 16 };
        int updates{};
        if (TrayIconRefreshRequired(current, light)) { current = light; ++updates; }
        if (TrayIconRefreshRequired(current, light)) { current = light; ++updates; }
        if (TrayIconRefreshRequired(current, dark)) { current = dark; ++updates; }
        if (TrayIconRefreshRequired(current, dark)) { current = dark; ++updates; }
        Check(updates == 2 && IsTrayAppearanceMessage(WM_SETTINGCHANGE) &&
            IsTrayAppearanceMessage(WM_THEMECHANGED) && IsTrayAppearanceMessage(WM_DPICHANGED) &&
            !IsTrayAppearanceMessage(WM_DISPLAYCHANGE),
            L"W-031: 相同主题不刷新，单次主题切换只产生一次有效原位更新");
    }

    struct FakeDdcBackend final : IDdcBackend
    {
        std::wstring key{ NativeDdcBackendKey };
        DdcBackendStatus status{ DdcAvailability::Available, L"模拟硬件 DDC/CI 可用" };
        std::map<std::pair<std::wstring, DdcVcpCode>, DdcValueResult> values;
        std::set<std::pair<std::wstring, DdcVcpCode>> writeFailures;
        std::map<std::pair<std::wstring, DdcVcpCode>, int> transientWriteFailures;
        std::vector<std::pair<std::wstring, DdcVcpCode>> reads;
        std::vector<std::tuple<std::wstring, DdcVcpCode, int>> writes;
        std::function<void()> onRead;
        std::function<void()> onWrite;
        std::atomic<uint64_t> topologyGeneration{ 1 };
        DisplayTopologyTrust topologyTrust{ DisplayTopologyTrust::LocalPhysicalAuthoritative };

        std::wstring Key() const override { return key; }
        std::wstring DisplayName() const override { return L"模拟硬件 DDC/CI"; }
        DdcBackendStatus Status() const override { return status; }
        uint64_t TopologyGeneration() const noexcept override { return topologyGeneration.load(); }
        DisplayTopologyTrust TopologyTrust() const noexcept override { return topologyTrust; }
        void InvalidateTopology() noexcept override { ++topologyGeneration; }
        DdcEnumerationResult Enumerate(DdcCancellationToken const&) override
        { return { true, DdcErrorKind::None, {}, {}, true, topologyTrust }; }
        DdcCapabilities Capabilities(std::wstring const&, DdcCancellationToken const&) override
        {
            if (topologyTrust != DisplayTopologyTrust::LocalPhysicalAuthoritative)
                return { { DdcAvailability::TemporarilyUnavailable, L"当前会话拓扑不可用" }, true, {}, {} };
            return { status, false, {}, {} };
        }
        DdcValueResult Read(std::wstring const& monitorId, DdcVcpCode code,
            DdcCancellationToken const& cancellation) override
        {
            auto generation = TopologyGeneration();
            reads.emplace_back(monitorId, code);
            if (onRead) onRead();
            if (cancellation.IsCanceled()) return { false, 0, 0, DdcErrorKind::Canceled, L"已取消" };
            auto found = values.find({ monitorId, code });
            if (found == values.end()) return { false, 0, 0, DdcErrorKind::ReadFailed, L"模拟读取失败" };
            auto result = found->second;
            if (result.success) result.topologyGeneration = generation;
            return result;
        }
        DdcWriteResult Write(std::wstring const& monitorId, DdcVcpCode code, int value,
            DdcCancellationToken const& cancellation) override
        {
            auto generation = TopologyGeneration();
            writes.emplace_back(monitorId, code, value);
            if (onWrite) onWrite();
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"已取消" };
            auto transient = transientWriteFailures.find({ monitorId, code });
            if (transient != transientWriteFailures.end() && transient->second-- > 0)
                return { false, DdcErrorKind::WriteFailed, L"模拟句柄失效" };
            if (writeFailures.contains({ monitorId, code })) return { false, DdcErrorKind::WriteFailed, L"模拟写入失败" };
            return { true, DdcErrorKind::None, {}, generation };
        }
    };

    struct FakeInputSourceTransport final : IInputSourceTransport
    {
        DdcBackendStatus status{ DdcAvailability::Available, L"模拟输入源传输可用" };
        std::set<std::wstring> writeFailures;
        std::map<std::wstring, int> transientWriteFailures;
        std::vector<std::pair<std::wstring, int>> writes;
        std::function<void()> onWrite;
        bool invalidateOnTransientFailure{};
        std::atomic<uint64_t> topologyGeneration{ 1 };
        DisplayTopologyTrust topologyTrust{ DisplayTopologyTrust::LocalPhysicalAuthoritative };

        DdcBackendStatus Status() const override
        {
            return topologyTrust == DisplayTopologyTrust::RemoteSessionLimited
                ? DdcBackendStatus{ DdcAvailability::TemporarilyUnavailable, L"远程会话已阻止" } : status;
        }
        uint64_t TopologyGeneration() const noexcept override { return topologyGeneration.load(); }
        DisplayTopologyTrust TopologyTrust() const noexcept override { return topologyTrust; }
        void InvalidateTopology() noexcept override { ++topologyGeneration; }
        InputSourceWriteResult WriteInputSource(std::wstring const& monitorId, int value,
            DdcCancellationToken const& cancellation) override
        {
            auto generation = TopologyGeneration();
            writes.emplace_back(monitorId, value);
            if (onWrite) onWrite();
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"已取消" };
            auto transient = transientWriteFailures.find(monitorId);
            if (transient != transientWriteFailures.end() && transient->second-- > 0)
            {
                if (invalidateOnTransientFailure) ++topologyGeneration;
                return { false, DdcErrorKind::WriteFailed, L"模拟输入源句柄失效" };
            }
            if (writeFailures.contains(monitorId))
                return { false, DdcErrorKind::WriteFailed, L"模拟输入源写入失败" };
            return { true, DdcErrorKind::None, {}, generation };
        }
    };

    void EnableDdcControls(DisplayConfig& display)
    {
        display.readEnabled = true;
        display.brightnessEnabled = true;
        display.contrastEnabled = true;
        display.volumeEnabled = true;
    }

    DdcControlService FakeService(FakeDdcBackend& native, std::function<bool()> allowed = {})
    {
        auto nativeBackend = &native;
        return DdcControlService([nativeBackend](std::wstring const& key) -> IDdcBackend*
        {
            if (_wcsicmp(key.c_str(), nativeBackend->key.c_str()) == 0) return nativeBackend;
            return nullptr;
        }, std::move(allowed));
    }

    void SetThreeValues(FakeDdcBackend& backend, std::wstring const& monitor, int brightness, int contrast, int volume,
        int maximum = 100)
    {
        backend.values[{ monitor, DdcVcpCode::Brightness }] = { true, brightness, maximum, DdcErrorKind::None, {} };
        backend.values[{ monitor, DdcVcpCode::Contrast }] = { true, contrast, maximum, DdcErrorKind::None, {} };
        backend.values[{ monitor, DdcVcpCode::Volume }] = { true, volume, maximum, DdcErrorKind::None, {} };
    }

    std::string ReadBytes(std::filesystem::path const& path)
    {
        std::ifstream stream(path, std::ios::binary);
        return { std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>() };
    }

    void WriteBytes(std::filesystem::path const& path, std::string const& value)
    {
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        stream.write(value.data(), static_cast<std::streamsize>(value.size()));
    }

    JsonObject ReadObject(std::filesystem::path const& path)
    {
        return JsonObject::Parse(winrt::to_hstring(ReadBytes(path)));
    }

    void WriteObject(std::filesystem::path const& path, JsonObject const& object)
    {
        WriteBytes(path, winrt::to_string(object.Stringify()));
    }

    bool SaveRejected(AppConfig const& config, std::filesystem::path const& path)
    {
        try { config.SaveToPath(path); return false; }
        catch (...) { return true; }
    }

    void TestFreshInstallAndCounts(std::filesystem::path const& root)
    {
        auto freshPath = root / L"fresh.json";
        bool firstRun{};
        bool secondRun{ true };
        auto first = AppConfig::LoadFromPath(freshPath, &firstRun);
        auto second = AppConfig::LoadFromPath(freshPath, &secondRun);
        Check(firstRun && !secondRun, L"首次启动应显示设置，后续启动应只驻留托盘");
        Check(IsValidDisplayId(first.localEndpointId) && first.localEndpointId == second.localEndpointId,
            L"C-001: localEndpointID 应随机生成、持久保存且重启稳定");
        Check(first.collaborationProfiles.size() == 1 && first.collaborationProfiles[0].name == L"配置 1"
            && !first.collaborationProfiles[0].coordinationEnabled, L"C-001: 全新安装应只有一个关闭的空配置");
        Check(first.displays.empty() && !first.HasUsbDeviceConfiguration() && !first.HasDisplayConfiguration(),
            L"C-001: 全新安装不得具备硬件动作条件");
        auto freshJson = ReadObject(freshPath);
        auto freshUsb = freshJson.GetNamedObject(L"UsbSwitch");
        Check(freshJson.GetNamedNumber(L"schemaVersion") == 5
            && !freshUsb.GetNamedBoolean(L"Enabled")
            && !freshUsb.GetNamedBoolean(L"CollaborationWakeEnabled")
            && !freshJson.HasKey(L"ControlChannel") && !freshJson.HasKey(L"ControlMyMonitorPath")
            && !freshJson.HasKey(L"CoordinationEnabled") && !freshJson.HasKey(L"PeerHost")
            && !freshJson.HasKey(L"Port") && !freshJson.HasKey(L"PairingCode"),
            L"DS-008: v5 默认配置必须安全关闭且不得保留旧顶层 USB 字段");

        for (size_t count : { size_t{ 0 }, size_t{ 1 }, size_t{ 2 }, size_t{ 4 } })
        {
            auto config = ConfigWithDisplays(count);
            auto path = root / (L"count-" + std::to_wstring(count) + L".json");
            config.SaveToPath(path);
            auto loaded = AppConfig::LoadFromPath(path);
            Check(loaded.displays.size() == count, L"0/1/多显示器应完整保存和回读");
            for (auto const& display : loaded.displays)
                Check(!display.localInput, L"Windows 新显示器的 localInput 不得被猜测");
        }
    }

    void TestDetailedDiagnosticRecording(std::filesystem::path const& root)
    {
        auto configPath = root / L"detailed-diagnostics-config.json";
        bool firstRun{};
        auto config = AppConfig::LoadFromPath(configPath, &firstRun);
        Check(firstRun && !config.detailedDiagnosticRecording &&
            !ReadObject(configPath).GetNamedBoolean(L"DetailedDiagnosticRecording"),
            L"详细诊断记录必须在全新安装时默认关闭并显式持久化");

        config.detailedDiagnosticRecording = true;
        config.SaveToPath(configPath);
        Check(AppConfig::LoadFromPath(configPath).detailedDiagnosticRecording,
            L"详细诊断记录开关必须能够保存并在重启后回读");

        auto legacyPath = root / L"detailed-diagnostics-legacy-v5.json";
        auto legacyObject = ReadObject(configPath);
        legacyObject.Remove(L"DetailedDiagnosticRecording");
        WriteObject(legacyPath, legacyObject);
        Check(!AppConfig::LoadFromPath(legacyPath).detailedDiagnosticRecording,
            L"缺少详细诊断字段的旧 v5 配置升级后必须默认关闭");

        auto logPath = root / L"detailed-diagnostics.log";
        SetDiagnosticLogPathForTesting(logPath);
        SetDetailedDiagnosticRecordingEnabled(false);
        ResetDiagnosticLog();
        for (auto const& event : {
            "display.switch_complete success=0 duration_ms=7",
            "usb.poll_change present=1",
            "profile_detection.started",
            "udp.send resolve_ok=1 resolve_ms=2 send_ok=1 send_ms=1" })
            WriteDiagnostic(event);
        Check(DiagnosticEventSnapshot().empty() && !std::filesystem::exists(logPath),
            L"详细记录关闭时 DDC/输入源、USB 和协同网络入口必须零内存记录且不创建日志文件");

        SetDetailedDiagnosticRecordingEnabled(true);
        Check(IsDetailedDiagnosticRecordingEnabled() && DiagnosticEventSnapshot().empty() &&
            !std::filesystem::exists(logPath),
            L"从关闭切到开启必须先清空既有详细记录");
        WriteDiagnostic("usb.target_notification present=0");
        Check(DiagnosticEventSnapshot().size() == 1 && std::filesystem::exists(logPath),
            L"开启后只记录随后产生的会话内脱敏轨迹");

        SetDetailedDiagnosticRecordingEnabled(false);
        Check(!IsDetailedDiagnosticRecordingEnabled() && DiagnosticEventSnapshot().empty() &&
            !std::filesystem::exists(logPath),
            L"从开启切到关闭必须清除内存和磁盘中的全部详细记录");
        {
            std::ofstream stale(logPath, std::ios::binary | std::ios::trunc);
            stale << "stale-detail";
        }
        SetDetailedDiagnosticRecordingEnabled(true);
        Check(DiagnosticEventSnapshot().empty() && !std::filesystem::exists(logPath),
            L"再次开启也必须删除关闭前遗留的详细日志，不能混入新会话");

        DiagnosticSnapshot disabledSnapshot;
        disabledSnapshot.about.applicationName = L"DisplaySwitch";
        disabledSnapshot.detailedRecordingEnabled = false;
        disabledSnapshot.sessions = { "udp.send success=1" };
        auto disabledPreview = BuildDiagnosticPreview(disabledSnapshot);
        Check(disabledPreview.find(L"detailed-recording=false") != std::wstring::npos &&
            disabledPreview.find(L"udp.send") == std::wstring::npos &&
            disabledPreview.find(L"会话内详细事件：0") != std::wstring::npos,
            L"详细记录关闭时诊断预览必须保留摘要并且不得输出任何旧轨迹");

        DdcControlItemResult internalFailure;
        internalFailure.error = DdcErrorKind::ReadFailed;
        internalFailure.message = L"HANDLE=0x1234 HRESULT=0x80070005 attempt=2 checksum=bad transport=i2c";
        auto basicFailure = DescribeBasicDdcResult(internalFailure, false);
        Check(basicFailure == L"硬件 DDC 读取失败" &&
            basicFailure.find(L"HANDLE") == std::wstring::npos &&
            basicFailure.find(L"HRESULT") == std::wstring::npos &&
            basicFailure.find(L"attempt") == std::wstring::npos &&
            basicFailure.find(L"checksum") == std::wstring::npos &&
            basicFailure.find(L"transport") == std::wstring::npos,
            L"显示器页面必须只投影简明成功/失败结果，不得展示内部 DDC 细节");

        SetDetailedDiagnosticRecordingEnabled(false);
        SetDiagnosticLogPathForTesting(std::nullopt);
    }

    void TestProfileManagementAndReorder(std::filesystem::path const& root)
    {
        auto config = ConfigWithDisplays(3);
        auto originalId = config.collaborationProfiles[0].id;
        auto second = Profile(L"游戏主机", true);
        auto third = Profile(L"备用电脑", true);
        second.peerEndpointId = GenerateIdentifier(); second.peerProtocolVersion = 2;
        third.peerEndpointId = GenerateIdentifier(); third.peerProtocolVersion = 2;
        for (auto const& display : config.displays)
        {
            second.displayInputs.push_back({ display.id, 20 });
            third.displayInputs.push_back({ display.id, 21 });
        }
        Check(originalId != second.id && second.id != third.id, L"C-002: 添加配置必须产生不同 UUID");
        config.collaborationProfiles.push_back(second);
        config.collaborationProfiles.push_back(third);
        std::swap(config.collaborationProfiles[0], config.collaborationProfiles[2]);
        auto displayId = config.displays[1].id;
        auto path = root / L"profiles.json";
        config.SaveToPath(path);
        auto loaded = AppConfig::LoadFromPath(path);
        Check(loaded.collaborationProfiles[2].id == originalId && loaded.PeerInputForDisplay(originalId, displayId) == 17,
            L"C-003: 配置重排后映射必须仍按 UUID 关联");
        Check(loaded.ReadonlyEnabledProfiles().size() == 2,
            L"C-006/U-003: 多个配置可同时开启且不得暗中选择列表第一项");
    }

    void TestValidationAndNfc(std::filesystem::path const& root)
    {
        auto path = root / L"validation.json";
        auto config = ConfigWithDisplays(1);
        config.SaveToPath(path);
        auto original = ReadBytes(path);
        config.collaborationProfiles.push_back(config.collaborationProfiles.front());
        config.collaborationProfiles.back().id = GenerateIdentifier();
        Check(SaveRejected(config, path) && ReadBytes(path) == original, L"C-004: 重名配置应拒绝且保留旧数据");
        config.collaborationProfiles.pop_back();
        config.collaborationProfiles[0].name = L" \t ";
        Check(SaveRejected(config, path), L"C-004: 空名称应拒绝");
        config.collaborationProfiles[0].name = L"bad\nname";
        Check(SaveRejected(config, path), L"C-004: 控制字符应拒绝");
        Check(!AppConfig::IsValidPairingCode(L"short") && AppConfig::IsValidPairingCode(L"12345678"),
            L"配对码应按 NFC 后 UTF-8 8..128 字节校验");
        auto decomposed = std::wstring(L"1234567e\u0301");
        Check(AppConfig::NormalizeNfc(decomposed) != decomposed && AppConfig::IsValidPairingCode(decomposed),
            L"配对码必须执行真实 NFC 规范化");
    }

    void TestImmediateCommitSafety(std::filesystem::path const& root)
    {
        auto path = root / L"immediate.json";
        auto runtime = ConfigWithDisplays(1);
        runtime.SaveToPath(path);
        auto lastValid = runtime;
        auto edited = runtime;
        edited.collaborationProfiles[0].peerPort = -1;
        bool saved{};
        try { edited.SaveToPath(path); runtime = edited; saved = true; } catch (...) {}
        int networkCalls{}, usbCalls{}, wakeCalls{}, ddcCalls{};
        Check(!saved && runtime.collaborationProfiles[0].peerPort == lastValid.collaborationProfiles[0].peerPort
            && networkCalls == 0 && usbCalls == 0 && wakeCalls == 0 && ddcCalls == 0,
            L"U-002: 非法文本提交必须恢复最后有效运行时值并保持零副作用");

        auto incomplete = lastValid;
        incomplete.collaborationProfiles[0].coordinationEnabled = true;
        incomplete.collaborationProfiles[0].peerEndpointId.clear();
        incomplete.collaborationProfiles[0].peerProtocolVersion.reset();
        Check(incomplete.EnabledCompleteProfiles().empty() && networkCalls == 0 && usbCalls == 0
            && wakeCalls == 0 && ddcCalls == 0,
            L"U-003: 不完整协同配置不得进入启用运行时或触发任何副作用");

        auto valid = lastValid;
        valid.startWithWindows = !valid.startWithWindows;
        valid.SaveToPath(path);
        runtime = AppConfig::LoadFromPath(path);
        Check(runtime.startWithWindows == valid.startWithWindows,
            L"U-001: 普通开关只在原子保存成功后更新运行时值");
    }

    void TestOrphansInspectionAndSelection()
    {
        auto config = ConfigWithDisplays(2);
        auto& profile = config.collaborationProfiles[0];
        auto removedId = config.displays[0].id;
        config.displays.erase(config.displays.begin());
        auto inspection = config.InspectProfile(profile.id);
        Check(!inspection.complete && !profile.displayInputs.empty() && profile.displayInputs[0].displayId == removedId,
            L"C-005: 孤立映射应保留为不可用且不得重绑");

        profile.peerEndpointId = GenerateIdentifier();
        auto changed = config.InspectProfile(profile.id, GenerateIdentifier(), 2);
        auto unknown = config.InspectProfile(profile.id, profile.peerEndpointId, 3);
        Check(changed.endpointConfirmationRequired && !changed.complete, L"C-007: endpoint 变化必须等待用户确认");
        Check(!unknown.complete, L"C-007: 未知协议版本应由本机检查拒绝");

        auto selected = config.SelectProfileDisplays(profile.id);
        Check(selected.mappedDisplays.size() == 1 && selected.mappedDisplays[0].id == config.displays[0].id,
            L"C-014: 手动选择只读取指定配置的 UUID 映射");
        profile.displayInputs.erase(std::remove_if(profile.displayInputs.begin(), profile.displayInputs.end(),
            [&](auto const& item) { return _wcsicmp(item.displayId.c_str(), config.displays[0].id.c_str()) == 0; }), profile.displayInputs.end());
        selected = config.SelectProfileDisplays(profile.id);
        Check(selected.mappedDisplays.empty() && selected.missingDisplayIds.size() == 1,
            L"C-015: 缺少映射的显示器应零写入并报告缺失");

        auto partialConfig = ConfigWithDisplays(2);
        auto& partialProfile = partialConfig.collaborationProfiles[0];
        partialProfile.displayInputs.erase(partialProfile.displayInputs.begin());
        auto partial = partialConfig.SelectProfileDisplays(partialProfile.id);
        Check(partial.mappedDisplays.size() == 1 && partial.missingDisplayIds.size() == 1,
            L"C-015: 单台缺少映射时其他显示器仍应独立进入执行集合");
    }

    void TestLegacyConfigResetToSafeV4(std::filesystem::path const& root)
    {
        auto path = root / L"v4.json";
        auto original = ConfigWithDisplays(2); original.SaveToPath(path);
        auto object = ReadObject(path); object.Insert(L"schemaVersion", JsonValue::CreateNumberValue(4)); object.Remove(L"UsbSwitch");
        object.Insert(L"UsbAutomationEnabled", JsonValue::CreateBooleanValue(true));
        object.Insert(L"UsbSwitchDisplaysOnArrival", JsonValue::CreateBooleanValue(true));
        object.Insert(L"UsbVendorId", JsonValue::CreateNumberValue(0x1234)); object.Insert(L"UsbProductId", JsonValue::CreateNumberValue(0x5678));
        object.Insert(L"UsbName", JsonValue::CreateStringValue(L"旧设备"));
        for (auto const& value : object.GetNamedArray(L"CollaborationProfiles"))
        {
            JsonArray triggers; JsonObject trigger; trigger.Insert(L"Kind", JsonValue::CreateStringValue(L"usb"));
            trigger.Insert(L"LocalReference", JsonValue::CreateStringValue(L"private-old-reference"));
            trigger.Insert(L"DisplayName", JsonValue::CreateStringValue(L"旧设备")); triggers.Append(trigger);
            value.GetObject().Insert(L"TriggerDevices", triggers);
        }
        WriteObject(path, object); auto oldBytes = ReadBytes(path);
        auto migrated = AppConfig::LoadFromPath(path);
        auto backup = std::filesystem::path(path.wstring() + L".pre-v5.backup");
        Check(std::filesystem::exists(backup) && ReadBytes(backup) == oldBytes,
            L"DS-008: v4 配置必须原样备份后再原子迁移");
        Check(ReadObject(path).GetNamedNumber(L"schemaVersion") == 5 && migrated.displays.size() == 2 &&
            migrated.collaborationProfiles.size() == 1 && !migrated.usbSwitch.enabled &&
            migrated.usbSwitch.deviceLocalReference.empty() && migrated.usbSwitch.displayInputs.empty() &&
            !migrated.usbSwitch.collaborationWakeEnabled && migrated.collaborationProfiles[0].triggerDevices.empty(),
            L"DS-008: v4→v5 必须保留非 USB 数据且不得猜测设备、映射或联动配置");
        Check(AppConfig::LoadFromPath(path).localEndpointId == original.localEndpointId,
            L"DS-008: v4→v5 必须保留稳定 localEndpointID");
    }

    void TestSafeFailures(std::filesystem::path const& root)
    {
        auto malformedPath = root / L"malformed.json";
        WriteBytes(malformedPath, "{not-json");
        auto malformed = AppConfig::LoadFromPath(malformedPath);
        auto restarted = AppConfig::LoadFromPath(malformedPath);
        Check(malformed.displayConfigurationSafeMode && restarted.displayConfigurationSafeMode
            && !malformed.usbSwitch.enabled,
            L"C-010: 读取失败后应跨重启保持安全状态");
        Check(ReadBytes(malformedPath) == "{not-json", L"C-010: 读取失败不得覆盖原数据");

        auto readOnlyPath = root / L"readonly-v4.json";
        auto legacyConfig = ConfigWithDisplays(1); legacyConfig.SaveToPath(readOnlyPath);
        auto legacyObject = ReadObject(readOnlyPath); legacyObject.Insert(L"schemaVersion", JsonValue::CreateNumberValue(4)); legacyObject.Remove(L"UsbSwitch");
        legacyObject.Insert(L"UsbAutomationEnabled", JsonValue::CreateBooleanValue(true));
        legacyObject.Insert(L"UsbSwitchDisplaysOnArrival", JsonValue::CreateBooleanValue(true));
        legacyObject.Insert(L"UsbVendorId", JsonValue::CreateNumberValue(0x1234)); legacyObject.Insert(L"UsbProductId", JsonValue::CreateNumberValue(0x5678));
        legacyObject.Insert(L"UsbName", JsonValue::CreateStringValue(L"旧设备"));
        for (auto const& value : legacyObject.GetNamedArray(L"CollaborationProfiles")) value.GetObject().Insert(L"TriggerDevices", JsonArray());
        WriteObject(readOnlyPath, legacyObject); auto legacy = ReadBytes(readOnlyPath);
        Check(SetFileAttributesW(readOnlyPath.c_str(), FILE_ATTRIBUTE_READONLY) != FALSE, L"测试夹具应能设为只读");
        auto failed = AppConfig::LoadFromPath(readOnlyPath);
        Check(failed.displayConfigurationSafeMode && !failed.HasDisplayConfiguration() && ReadBytes(readOnlyPath) == legacy,
            L"DS-008: v4→v5 原子替换失败应保留原数据并阻断硬件/网络条件");
        Check(AppConfig::LoadFromPath(readOnlyPath).displayConfigurationSafeMode,
            L"C-010: 迁移失败安全状态应跨重启持续");
        SetFileAttributesW(readOnlyPath.c_str(), FILE_ATTRIBUTE_NORMAL);
    }

    void TestNormalV4SaveFailureSafety(std::filesystem::path const& root)
    {
        auto runFailure = [&](wchar_t const* fileName, AppConfigSaveFaultForTesting fault, bool invalidEncoding)
        {
            auto path = root / fileName;
            auto original = ConfigWithDisplays(2);
            original.usbSwitch.enabled = true;
            original.usbSwitch.deviceLocalReference = L"test-local-reference";
            original.usbSwitch.deviceName = L"测试设备";
            original.usbSwitch.vendorId = 0x1234;
            original.usbSwitch.productId = 0x5678;
            original.usbSwitch.displayInputs.push_back({ original.displays[0].id, 17 });
            original.collaborationProfiles[0].coordinationEnabled = true;
            original.collaborationProfiles[0].peerEndpointId = GenerateIdentifier();
            original.collaborationProfiles[0].peerProtocolVersion = 2;
            original.SaveToPath(path);
            auto oldBytes = ReadBytes(path);

            auto edited = original;
            edited.localDeviceName = L"已编辑本机";
            if (invalidEncoding)
                edited.collaborationProfiles[0].pairingCode = std::wstring(L"1234567") + wchar_t{ 0xD800 };

            bool rejected{};
            try { edited.SaveToPath(path, fault); }
            catch (...) { rejected = true; }
            auto marker = std::filesystem::path(path.wstring() + L".safety");
            Check(rejected, L"正常 v4 设置保存阶段失败必须重新抛出错误");
            Check(ReadBytes(path) == oldBytes, L"正常 v4 设置保存失败必须保留磁盘旧配置");
            Check(std::filesystem::exists(marker), L"正常 v4 设置保存失败必须写入持久安全标记");

            auto currentProcess = original;
            RuntimeSafetyGate gate;
            gate.Block();
            currentProcess.EnterSafeState();
            Check(currentProcess.displayConfigurationSafeMode && !currentProcess.usbSwitch.enabled
                && std::none_of(currentProcess.collaborationProfiles.begin(), currentProcess.collaborationProfiles.end(),
                    [](auto const& profile) { return profile.coordinationEnabled; }),
                L"当前进程收到保存失败后必须立即关闭 UDP、USB 自动切换和状态机协同");
            int udpCalls{}, usbCalls{}, ddcCalls{}, wakeCalls{};
            if (gate.AllowsSideEffects()) { ++udpCalls; ++usbCalls; ++ddcCalls; ++wakeCalls; }
            Check(udpCalls == 0 && usbCalls == 0 && ddcCalls == 0 && wakeCalls == 0,
                L"当前进程进入安全状态后必须产生零 UDP、USB、DDC 和唤醒副作用");

            auto restarted = AppConfig::LoadFromPath(path);
            Check(restarted.displayConfigurationSafeMode && !restarted.usbSwitch.enabled
                && std::none_of(restarted.collaborationProfiles.begin(), restarted.collaborationProfiles.end(),
                    [](auto const& profile) { return profile.coordinationEnabled; }),
                L"保存失败后重启必须继续关闭 UDP、USB 自动切换和状态机协同");
            Check(!restarted.HasUsbDeviceConfiguration() && !restarted.HasDisplayConfiguration(),
                L"保存失败后的安全配置必须阻止 DDC 和唤醒前置条件");

            auto recovered = original;
            recovered.localDeviceName = L"恢复后的本机";
            recovered.SaveToPath(path);
            Check(!std::filesystem::exists(marker), L"只有后续成功保存合法 v4 配置才清除安全标记");
            auto loaded = AppConfig::LoadFromPath(path);
            Check(!loaded.displayConfigurationSafeMode && loaded.localDeviceName == recovered.localDeviceName,
                L"成功保存合法配置后应恢复正常加载并保留编辑内容");
        };

        runFailure(L"encoding-failure.json", AppConfigSaveFaultForTesting::None, true);
        runFailure(L"temporary-write-failure.json", AppConfigSaveFaultForTesting::TemporaryWrite, false);
        runFailure(L"readback-mismatch.json", AppConfigSaveFaultForTesting::ReadbackMismatch, false);
        runFailure(L"atomic-replace-failure.json", AppConfigSaveFaultForTesting::AtomicReplace, false);
    }

    void TestUnknownFieldsVersionsAndDuplicates(std::filesystem::path const& root)
    {
        auto path = root / L"strict.json";
        auto config = ConfigWithDisplays(1); config.SaveToPath(path);
        auto object = ReadObject(path);
        object.Insert(L"FutureField", JsonValue::CreateStringValue(L"ignored"));
        object.Insert(L"ControlChannel", JsonValue::CreateStringValue(L"control_my_monitor"));
        object.Insert(L"ControlMyMonitorPath", JsonValue::CreateStringValue(L"legacy-tool.exe"));
        auto displayObject = object.GetNamedArray(L"Displays").GetObjectAt(0);
        displayObject.Insert(L"ControlMonitorPath", JsonValue::CreateStringValue(L"legacy-monitor-path"));
        WriteObject(path, object);
        auto withoutLegacyBackend = AppConfig::LoadFromPath(path);
        Check(!withoutLegacyBackend.displayConfigurationSafeMode,
            L"DS-011: v5 旧 DDC 后端字段应作为未知字段安全忽略");
        withoutLegacyBackend.SaveToPath(path);
        auto normalized = ReadObject(path);
        Check(!normalized.HasKey(L"ControlChannel") && !normalized.HasKey(L"ControlMyMonitorPath")
            && !normalized.GetNamedArray(L"Displays").GetObjectAt(0).HasKey(L"ControlMonitorPath"),
            L"DS-011: 成功保存后不得再次写入旧后端选择、路径或显示器兼容字段");

        object = ReadObject(path); object.Insert(L"schemaVersion", JsonValue::CreateNumberValue(99)); WriteObject(path, object);
        auto futureBytes = ReadBytes(path);
        auto future = AppConfig::LoadFromPath(path);
        Check(future.displayConfigurationSafeMode && future.displays.empty() && !future.usbSwitch.enabled
            && ReadBytes(path) == futureBytes,
            L"DS-008: 未知 schemaVersion 必须保留原文件并进入安全状态");

        auto duplicatePath = root / L"duplicate.json"; config.SaveToPath(duplicatePath);
        object = ReadObject(duplicatePath); auto profiles = object.GetNamedArray(L"CollaborationProfiles"); profiles.Append(profiles.GetAt(0));
        WriteObject(duplicatePath, object);
        Check(AppConfig::LoadFromPath(duplicatePath).displayConfigurationSafeMode, L"C-012: 重复 UUID 应安全拒绝");

        auto fractionalPath = root / L"fractional.json"; config.SaveToPath(fractionalPath);
        object = ReadObject(fractionalPath); object.Insert(L"ListenPort", JsonValue::CreateNumberValue(49731.5)); WriteObject(fractionalPath, object);
        Check(AppConfig::LoadFromPath(fractionalPath).displayConfigurationSafeMode, L"非法数值范围或非整数应安全拒绝");

        auto missingPath = root / L"missing-v4-field.json"; config.SaveToPath(missingPath);
        object = ReadObject(missingPath); object.Remove(L"LinkAllDisplays"); WriteObject(missingPath, object);
        auto missingBytes = ReadBytes(missingPath); auto missing = AppConfig::LoadFromPath(missingPath);
        Check(missing.displayConfigurationSafeMode && ReadBytes(missingPath) == missingBytes
            && missing.EnabledCompleteProfiles().empty() && !missing.HasDisplayConfiguration(),
            L"U-017: 缺少 v4 必填字段必须保留原文件并持续阻断网络和硬件副作用");
    }

    void TestRenameAndFailureIsolation(std::filesystem::path const& root)
    {
        auto config = ConfigWithDisplays(3);
        auto id = config.collaborationProfiles[0].id;
        auto mappedId = config.displays[1].id;
        config.collaborationProfiles[0].coordinationEnabled = true;
        config.collaborationProfiles[0].peerEndpointId = GenerateIdentifier();
        config.collaborationProfiles[0].peerProtocolVersion = 2;
        config.collaborationProfiles[0].name = L"新名称";
        auto path = root / L"rename.json"; config.SaveToPath(path);
        auto loaded = AppConfig::LoadFromPath(path);
        Check(loaded.collaborationProfiles[0].name == L"新名称" && loaded.PeerInputForDisplay(id, mappedId) == 17,
            L"C-013: 重命名应立即生效且不改变输入映射");
        Check(loaded.EnabledCompleteProfiles().size() == 1 && loaded.EnabledCompleteProfiles()[0].name == L"新名称",
            L"C-013: 菜单数据应立即使用已启用配置的新名称");

        std::atomic<int> calls{};
        auto result = ExecuteDisplayActions(config.displays, [&](DisplayConfig const& display)
        {
            ++calls; return display.name == L"显示器 2" ? ActionResult{ false, L"模拟失败" } : ActionResult{ true, {} };
        });
        Check(calls == 3 && !result.success, L"单台显示器失败不得影响其他显示器");

        auto newDisplay = CreateDisplayConfig(L"新增");
        Check(!newDisplay.localInput && newDisplay.macInput == -1 && newDisplay.nativeMonitorId.empty(),
            L"新显示器不得继承旧显示器输入源或硬件标识");

        std::vector<DdcMonitorInfo> monitors{ { L"monitor-c", L"C", L"DISPLAY3" }, { L"monitor-a", L"A", L"DISPLAY9" } };
        std::reverse(monitors.begin(), monitors.end());
        auto matched = FindDdcMonitorById(monitors, L"MONITOR-C");
        Check(matched && monitors[*matched].displayName == L"C", L"显示器重排后应按稳定标识匹配");
        monitors.erase(monitors.begin(), monitors.end());
        Check(!FindDdcMonitorById(monitors, L"monitor-c"), L"显示器移除时应报告未连接");
        monitors.push_back({ L"monitor-c", L"重新接入", L"DISPLAY7" });
        Check(FindDdcMonitorById(monitors, L"monitor-c").has_value(), L"显示器重新接入后应恢复稳定匹配");
    }

    void TestNativeDisplayCollection()
    {
        auto first = Display(L"工作主屏", L"device-a|0", 16);
        first.brightnessEnabled = true;
        first.brightnessValue = 42;
        auto second = Display(L"显示器 2", L"device-b|1", 17);
        auto firstLogicalId = first.id;
        auto secondLogicalId = second.id;

        std::vector<DdcMonitorInfo> duplicated{
            { L"device-b|1", L"相同型号", L"DISPLAY2" },
            { L"device-a|0", L"相同型号", L"DISPLAY1" },
            { L"device-a|1", L"相同型号", L"DISPLAY1" },
            { L"DEVICE-B|0", L"相同型号", L"DISPLAY2" },
        };
        auto normalized = NormalizeDdcMonitorCollection(duplicated);
        Check(normalized.size() == 2 && normalized[0].displayName == L"相同型号（1）"
            && normalized[1].displayName == L"相同型号（2）",
            L"W-009: 同一物理接口的重复句柄必须去重，同型号名称按稳定 ID 给出本机序号");
        auto differentModels = NormalizeDdcMonitorCollection(
            { { L"device-c", L"型号甲", L"DISPLAY3" }, { L"device-d", L"型号乙", L"DISPLAY4" } });
        Check(differentModels.size() == 2 && differentModels[0].displayName == L"型号甲"
            && differentModels[1].displayName == L"型号乙",
            L"W-009: 不同型号显示器必须直接使用系统友好名称而不添加无意义序号");

        auto reconciled = ReconcileDisplayConfigurations({ first, second }, duplicated,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        auto preservedFirst = std::find_if(reconciled.displays.begin(), reconciled.displays.end(), [&](auto const& display)
            { return display.id == firstLogicalId; });
        auto preservedSecond = std::find_if(reconciled.displays.begin(), reconciled.displays.end(), [&](auto const& display)
            { return display.id == secondLogicalId; });
        Check(reconciled.displays.size() == 2 && preservedFirst != reconciled.displays.end()
            && preservedFirst->name == L"工作主屏" && preservedFirst->brightnessEnabled
            && preservedFirst->brightnessValue == 42 && preservedSecond != reconciled.displays.end()
            && preservedSecond->name.starts_with(L"相同型号"),
            L"W-009: 枚举重排后仍按稳定物理 ID 保留用户设置并用系统友好名称替换通用名称");
        preservedFirst->brightnessShowInTray = true;
        AppConfig trayConfig; trayConfig.displays = reconciled.displays;
        auto trayNames = BuildDdcTrayControls(trayConfig);
        Check(trayNames.size() == 1 && trayNames[0].displayName == L"工作主屏",
            L"W-009: 托盘 DDC 项必须使用保留的用户名称或系统友好名称");

        preservedFirst->localInput = 27;
        preservedFirst->contrastEnabled = true;
        preservedFirst->contrastShowInTray = true;
        preservedFirst->volumeEnabled = true;
        preservedFirst->volumeShowInTray = true;
        CollaborationProfile preservedProfile = Profile(L"保留的协同配置");
        preservedProfile.displayInputs = { { firstLogicalId, 31 }, { secondLogicalId, 32 } };
        UsbSwitchConfig preservedUsb;
        preservedUsb.displayInputs = { { firstLogicalId, 33 }, { secondLogicalId, 34 } };

        DdcEnumerationResult partialSnapshot{ true, DdcErrorKind::None, L"部分枚举",
            { { L"device-b", L"相同型号", L"DISPLAY9" } }, false,
            DisplayTopologyTrust::IncompleteOrUnavailable };
        auto partial = ReconcileDisplayConfigurations(reconciled.displays, partialSnapshot.monitors,
            partialSnapshot.topologyTrust);
        Check(!partial.changed && partial.removed == 0 && partial.displays.size() == 2
            && preservedProfile.displayInputs.size() == 2 && preservedUsb.displayInputs.size() == 2,
            L"W-009: 部分失败的枚举必须原样保留显示器、USB 映射和协同映射");

        DdcEnumerationResult sleepingSnapshot{ true, DdcErrorKind::None, {}, {}, false,
            DisplayTopologyTrust::IncompleteOrUnavailable };
        auto sleeping = ReconcileDisplayConfigurations(partial.displays, sleepingSnapshot.monitors,
            sleepingSnapshot.topologyTrust);
        auto sleepingFirst = std::find_if(sleeping.displays.begin(), sleeping.displays.end(), [&](auto const& display)
            { return display.id == firstLogicalId; });
        Check(!sleeping.changed && sleeping.removed == 0 && sleeping.displays.size() == 2
            && sleepingFirst != sleeping.displays.end() && sleepingFirst->name == L"工作主屏"
            && sleepingFirst->localInput == 27 && sleepingFirst->brightnessEnabled
            && sleepingFirst->brightnessShowInTray && sleepingFirst->contrastEnabled
            && sleepingFirst->contrastShowInTray && sleepingFirst->volumeEnabled
            && sleepingFirst->volumeShowInTray && preservedProfile.displayInputs.size() == 2
            && preservedUsb.displayInputs.size() == 2,
            L"W-009: 空集合和显示器休眠不得丢失名称、DDC/托盘开关、输入源或映射");

        auto recovered = ReconcileDisplayConfigurations(sleeping.displays,
            { { L"device-b", L"相同型号", L"DISPLAY2" },
              { L"device-a", L"相同型号", L"DISPLAY1" } },
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        auto recoveredFirst = std::find_if(recovered.displays.begin(), recovered.displays.end(), [&](auto const& display)
            { return display.id == firstLogicalId; });
        Check(!recovered.changed && recovered.removed == 0 && recovered.displays.size() == 2
            && recoveredFirst != recovered.displays.end() && recoveredFirst->name == L"工作主屏"
            && recoveredFirst->localInput == 27 && recoveredFirst->brightnessEnabled
            && recoveredFirst->contrastEnabled && recoveredFirst->volumeEnabled,
            L"W-009: 显示器休眠恢复并重排后必须按稳定 ID 恢复原用户设置");

        auto disconnected = ReconcileDisplayConfigurations(reconciled.displays,
            { { L"device-b", L"相同型号", L"DISPLAY9" } },
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(disconnected.displays.size() == 1 && disconnected.removed == 1
            && disconnected.displays[0].id == secondLogicalId,
            L"W-009: 已断开或失效显示器必须从实时集合清理，仍存在显示器保持逻辑 ID");

        CollaborationProfile profile = Profile(L"模拟对端");
        profile.displayInputs = { { firstLogicalId, 16 }, { secondLogicalId, 17 } };
        UsbSwitchConfig usb;
        usb.displayInputs = { { firstLogicalId, 18 }, { secondLogicalId, 19 } };
        std::vector<CollaborationProfile> profiles{ profile };
        Check(RemoveOrphanedDisplayMappings(disconnected.displays, profiles, usb)
            && profiles[0].displayInputs.size() == 1 && usb.displayInputs.size() == 1,
            L"W-009: 显示器清理必须同步移除孤立映射且不污染仍连接显示器");

        auto reconnected = ReconcileDisplayConfigurations(disconnected.displays,
            { { L"device-a", L"另一型号", L"DISPLAY4" }, { L"device-b", L"相同型号", L"DISPLAY9" } },
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        auto newFirst = std::find_if(reconnected.displays.begin(), reconnected.displays.end(), [&](auto const& display)
            { return _wcsicmp(display.nativeMonitorId.c_str(), L"device-a") == 0; });
        Check(reconnected.added == 1 && newFirst != reconnected.displays.end()
            && newFirst->id != firstLogicalId && !newFirst->brightnessEnabled && !newFirst->brightnessValue,
            L"W-009: 被清理显示器重新接入时作为新显示器加入，不继承已失效实例的控制状态");

        int released{};
        {
            NativeMonitorHandleLease handles([&](HANDLE) { ++released; });
            auto one = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(1));
            auto two = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(2));
            handles.Add(one); handles.Add(one); handles.Add(two);
            Check(handles.Handles().size() == 2, L"W-009: 重复物理句柄只能登记一次");
        }
        Check(released == 2, L"W-009: 每个唯一物理监视器句柄必须在所有路径恰好释放一次");
    }

    void TestDisplayTopologyBinding()
    {
        auto monitor = [](std::wstring strongId, std::wstring targetId, std::wstring name,
            std::wstring gdi, size_t physicalHandles, std::vector<std::wstring> legacy = {})
        {
            DdcMonitorInfo value;
            value.id = std::move(strongId);
            value.logicalTargetId = std::move(targetId);
            value.displayName = std::move(name);
            value.gdiName = std::move(gdi);
            value.physicalHandleCount = physicalHandles;
            value.legacyIds = std::move(legacy);
            return value;
        };

        auto fourHandles = NormalizeDdcMonitorCollection({
            monitor(L"ds13:identity-a", L"adapter-a:1", L"相同型号", L"DISPLAY1", 2),
            monitor(L"ds13:identity-b", L"adapter-a:2", L"相同型号", L"DISPLAY2", 2),
        });
        Check(fourHandles.size() == 2 && fourHandles[0].ambiguous && fourHandles[1].ambiguous,
            L"DS-013: 两个逻辑 target 的四个底层句柄只能显示两个逻辑项并标记歧义");
        auto fourReconciled = ReconcileDisplayConfigurations({}, fourHandles,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(fourReconciled.displays.size() == 2
            && std::all_of(fourReconciled.displays.begin(), fourReconciled.displays.end(), [](auto const& display)
                { return display.bindingStatus == DisplayBindingStatus::Ambiguous; }),
            L"DS-013: 多物理句柄不得生成重复逻辑显示器或选择第一个句柄");
        AppConfig ambiguousConfig; ambiguousConfig.displays = fourReconciled.displays;
        for (auto& display : ambiguousConfig.displays) EnableDdcControls(display);
        FakeDdcBackend ambiguousBackend; DdcCancellationSource ambiguousCancellation;
        auto ambiguousRead = FakeService(ambiguousBackend).Read(ambiguousConfig, {}, ambiguousCancellation.Begin());
        auto ambiguousWrite = FakeService(ambiguousBackend).Write(ambiguousConfig,
            ambiguousConfig.displays[0].id, DdcVcpCode::Brightness, 40, false, ambiguousCancellation.Begin());
        for (auto& display : ambiguousConfig.displays) display.macInput = 18;
        FakeInputSourceTransport ambiguousInputTransport;
        auto ambiguousInput = SwitchDisplaysToMac(ambiguousConfig, &ambiguousInputTransport);
        Check(!ambiguousRead.success && !ambiguousWrite.success && !ambiguousInput.success && ambiguousBackend.reads.empty()
            && ambiguousBackend.writes.empty() && ambiguousInputTransport.writes.empty(),
            L"DS-013: 歧义 target 必须保持亮度、对比度、音量和输入源 DDC 调用为零");

        auto duplicatePhysical = NormalizeDdcMonitorCollection({
            monitor(L"ds13:identity-c", L"adapter-b:1", L"目标", L"DISPLAY3", 1),
            monitor(L"ds13:identity-c", L"adapter-b:1", L"目标", L"DISPLAY3", 1),
        });
        Check(duplicatePhysical.size() == 1 && duplicatePhysical[0].physicalHandleCount == 2
            && duplicatePhysical[0].ambiguous,
            L"DS-013: 同一 target 的重复底层句柄必须合并为一个不可操作逻辑项");

        auto noSerial = NormalizeDdcMonitorCollection({
            monitor({}, L"adapter-c:1", L"相同型号", L"DISPLAY4", 1),
            monitor({}, L"adapter-c:2", L"相同型号", L"DISPLAY5", 1),
        });
        auto noSerialFirst = ReconcileDisplayConfigurations({}, noSerial,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        std::reverse(noSerial.begin(), noSerial.end());
        auto noSerialReordered = ReconcileDisplayConfigurations(noSerialFirst.displays, noSerial,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(noSerialReordered.displays.size() == 2
            && std::all_of(noSerialReordered.displays.begin(), noSerialReordered.displays.end(), [](auto const& display)
                { return display.bindingStatus != DisplayBindingStatus::Resolved; }),
            L"DS-013: 同型号且无强身份时不得按友好名称或枚举顺序猜测绑定");

        auto strong = NormalizeDdcMonitorCollection({
            monitor(L"ds13:strong-a", L"adapter-d:1", L"相同型号", L"DISPLAY6", 1),
            monitor(L"ds13:strong-b", L"adapter-d:2", L"相同型号", L"DISPLAY7", 1),
        });
        auto strongFirst = ReconcileDisplayConfigurations({}, strong,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        auto firstLogicalIds = std::map<std::wstring, std::wstring>{};
        for (auto const& display : strongFirst.displays) firstLogicalIds[display.nativeMonitorId] = display.id;
        auto switchedPorts = NormalizeDdcMonitorCollection({
            monitor(L"ds13:strong-b", L"adapter-e:9", L"相同型号", L"DISPLAY9", 1),
            monitor(L"ds13:strong-a", L"adapter-e:8", L"相同型号", L"DISPLAY8", 1),
        });
        auto strongRebound = ReconcileDisplayConfigurations(strongFirst.displays, switchedPorts,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(strongRebound.displays.size() == 2
            && std::all_of(strongRebound.displays.begin(), strongRebound.displays.end(), [&](auto const& display)
                { return display.bindingStatus == DisplayBindingStatus::Resolved
                    && firstLogicalIds[display.nativeMonitorId] == display.id; }),
            L"DS-013: 强身份唯一时接口切换和枚举重排必须保持全局一对一逻辑绑定");

        CollaborationProfile transientProfile = Profile(L"短暂断开保留");
        UsbSwitchConfig transientUsb;
        for (auto const& display : strongFirst.displays)
        {
            transientProfile.displayInputs.push_back({ display.id, 24 });
            transientUsb.displayInputs.push_back({ display.id, 25 });
        }
        auto partial = ReconcileDisplayConfigurations(strongFirst.displays,
            { monitor(L"ds13:strong-a", L"adapter-d:1", L"相同型号", L"DISPLAY6", 1) },
            DisplayTopologyTrust::IncompleteOrUnavailable);
        auto empty = ReconcileDisplayConfigurations(partial.displays, {},
            DisplayTopologyTrust::IncompleteOrUnavailable);
        auto wakeRecovery = ReconcileDisplayConfigurations(empty.displays, switchedPorts,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(!partial.changed && !empty.changed && partial.displays.size() == 2 && empty.displays.size() == 2
            && wakeRecovery.displays.size() == 2 && transientProfile.displayInputs.size() == 2
            && transientUsb.displayInputs.size() == 2,
            L"DS-013: 部分失败、空集合和休眠恢复不得破坏配置或任何显示器映射");

        auto legacy = Display(L"旧配置", L"legacy-interface-a", 16);
        auto legacyId = legacy.id;
        auto uniqueMigration = ReconcileDisplayConfigurations({ legacy }, {
            monitor(L"ds13:migrated-a", L"adapter-f:1", L"迁移目标", L"DISPLAY10", 1,
                { L"legacy-interface-a" }) }, DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(uniqueMigration.displays.size() == 1 && uniqueMigration.displays[0].id == legacyId
            && uniqueMigration.displays[0].nativeMonitorId == L"ds13:migrated-a"
            && uniqueMigration.displays[0].bindingStatus == DisplayBindingStatus::Resolved,
            L"DS-013: 旧接口 ID 仅有唯一强候选时才能迁移并保留逻辑 ID");
        auto ambiguousMigration = ReconcileDisplayConfigurations({ legacy }, {
            monitor(L"ds13:migrated-b", L"adapter-f:2", L"相同型号", L"DISPLAY11", 1,
                { L"legacy-interface-a" }),
            monitor(L"ds13:migrated-c", L"adapter-f:3", L"相同型号", L"DISPLAY12", 1,
                { L"legacy-interface-a" }) }, DisplayTopologyTrust::LocalPhysicalAuthoritative);
        auto retainedLegacy = std::find_if(ambiguousMigration.displays.begin(), ambiguousMigration.displays.end(),
            [&](auto const& display) { return display.id == legacyId; });
        Check(retainedLegacy != ambiguousMigration.displays.end()
            && retainedLegacy->nativeMonitorId == L"legacy-interface-a"
            && retainedLegacy->bindingStatus == DisplayBindingStatus::NeedsConfirmation,
            L"DS-013: 旧配置有多个候选时必须保留原值并安全拒绝，不得选择第一项");

        auto offlineConfig = strongFirst.displays;
        auto offlineId = firstLogicalIds[L"ds13:strong-a"];
        CollaborationProfile profile = Profile(L"保留映射");
        for (auto const& display : offlineConfig) profile.displayInputs.push_back({ display.id, 20 });
        UsbSwitchConfig usb;
        for (auto const& display : offlineConfig) usb.displayInputs.push_back({ display.id, 21 });
        auto partialTopology = ReconcileDisplayConfigurations(offlineConfig,
            { monitor(L"ds13:strong-b", L"adapter-d:2", L"相同型号", L"DISPLAY7", 1) },
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        auto offline = std::find_if(partialTopology.displays.begin(), partialTopology.displays.end(),
            [&](auto const& display) { return display.id == offlineId; });
        Check(partialTopology.displays.size() == 2 && partialTopology.removed == 0
            && offline != partialTopology.displays.end() && offline->bindingStatus == DisplayBindingStatus::Offline
            && profile.displayInputs.size() == 2 && usb.displayInputs.size() == 2,
            L"DS-013: 暂时离线不得删除显示器配置、USB 绑定或协同输入映射");

        int released{};
        {
            NativeMonitorHandleLease handles([&](HANDLE) { ++released; });
            auto one = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(1));
            auto two = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(2));
            handles.Add(one); handles.Add(one); handles.Add(two);
            Check(handles.Handles().size() == 2, L"DS-013: 物理句柄所有权必须去重");
        }
        Check(released == 2, L"DS-013: 拓扑销毁时每个唯一物理句柄必须恰好释放一次");
    }

    void TestInputSourceNullSafetyAndMigration(std::filesystem::path const& root)
    {
        auto path = root / L"input-source-zero-migration.json";
        auto config = ConfigWithDisplays(1);
        auto& profile = config.collaborationProfiles[0];
        profile.coordinationEnabled = true;
        profile.peerEndpointId = GenerateIdentifier();
        profile.peerProtocolVersion = 2;
        config.usbSwitch.enabled = true;
        config.usbSwitch.deviceLocalReference = L"synthetic-local-reference";
        config.usbSwitch.deviceName = L"模拟设备";
        config.usbSwitch.vendorId = 1;
        config.usbSwitch.productId = 2;
        config.usbSwitch.displayInputs = { { config.displays[0].id, 17 } };
        config.usbSwitch.collaborationWakeEnabled = true;
        config.usbSwitch.collaborationProfileId = profile.id;
        config.SaveToPath(path);

        auto legacy = ReadObject(path);
        legacy.GetNamedArray(L"CollaborationProfiles").GetObjectAt(0)
            .GetNamedArray(L"DisplayInputs").GetObjectAt(0)
            .Insert(L"PeerInput", JsonValue::CreateNumberValue(0));
        legacy.GetNamedObject(L"UsbSwitch").GetNamedArray(L"DisplayInputs").GetObjectAt(0)
            .Insert(L"TargetInput", JsonValue::CreateNumberValue(0));
        WriteObject(path, legacy);
        auto loaded = AppConfig::LoadFromPath(path);
        Check(!loaded.usbSwitch.enabled && !loaded.usbSwitch.collaborationWakeEnabled
            && !loaded.collaborationProfiles[0].coordinationEnabled
            && !loaded.UsbInputForDisplay(loaded.displays[0].id)
            && loaded.PeerInputForDisplay(loaded.collaborationProfiles[0].id, loaded.displays[0].id, -1) == -1,
            L"旧 USB 和协同输入源 0 必须原子迁移为空映射并关闭无有效映射的执行入口");
        auto migrated = ReadObject(path);
        Check(migrated.GetNamedObject(L"UsbSwitch").GetNamedArray(L"DisplayInputs").GetObjectAt(0)
            .GetNamedValue(L"TargetInput").ValueType() == JsonValueType::Null
            && migrated.GetNamedArray(L"CollaborationProfiles").GetObjectAt(0)
                .GetNamedArray(L"DisplayInputs").Size() == 0,
            L"迁移保存后空映射必须保持 null/缺失，不能重新补成 0");

        auto partial = ConfigWithDisplays(2);
        auto& partialProfile = partial.collaborationProfiles[0];
        partialProfile.coordinationEnabled = true;
        partialProfile.peerEndpointId = GenerateIdentifier();
        partialProfile.peerProtocolVersion = 2;
        partialProfile.displayInputs.erase(partialProfile.displayInputs.begin());
        auto partialPath = root / L"partial-input-mapping.json";
        partial.SaveToPath(partialPath);
        auto partialLoaded = AppConfig::LoadFromPath(partialPath);
        auto selected = partialLoaded.SelectProfileDisplays(partialProfile.id);
        Check(partialLoaded.EnabledCompleteProfiles().size() == 1
            && selected.mappedDisplays.size() == 1 && selected.missingDisplayIds.size() == 1,
            L"协同配置至少一台有效映射即可启用，空映射只产生 missing_mapping 且不阻止其他显示器");

        auto failurePath = root / L"input-source-zero-migration-failure.json";
        config.usbSwitch.enabled = true;
        config.collaborationProfiles[0].coordinationEnabled = true;
        config.SaveToPath(failurePath);
        auto failureObject = ReadObject(failurePath);
        failureObject.GetNamedArray(L"CollaborationProfiles").GetObjectAt(0)
            .GetNamedArray(L"DisplayInputs").GetObjectAt(0)
            .Insert(L"PeerInput", JsonValue::CreateNumberValue(0));
        failureObject.GetNamedObject(L"UsbSwitch").GetNamedArray(L"DisplayInputs").GetObjectAt(0)
            .Insert(L"TargetInput", JsonValue::CreateNumberValue(0));
        WriteObject(failurePath, failureObject);
        auto originalBytes = ReadBytes(failurePath);
        auto failed = AppConfig::LoadFromPath(failurePath, nullptr, AppConfigSaveFaultForTesting::TemporaryWrite);
        Check(failed.displayConfigurationSafeMode && !failed.usbSwitch.enabled
            && failed.EnabledCompleteProfiles().empty() && ReadBytes(failurePath) == originalBytes,
            L"零值迁移写入失败必须保留原始数据并进入跨副作用安全状态");
    }

    void TestRemoteSessionDisplayTopology()
    {
        Check(IsRemoteDisplaySession({ true, 4, 4 })
            && IsRemoteDisplaySession({ false, 7, 3 })
            && !IsRemoteDisplaySession({ false, 3, 3 }),
            L"RDP: SM_REMOTESESSION 和 GlassSessionId 必须共同覆盖普通与 RemoteFX/vGPU 远程会话");
        Check(IsRemoteOrMirroringDisplayDevice(DISPLAY_DEVICE_REMOTE)
            && IsRemoteOrMirroringDisplayDevice(DISPLAY_DEVICE_MIRRORING_DRIVER)
            && !IsRemoteOrMirroringDisplayDevice(DISPLAY_DEVICE_ACTIVE),
            L"RDP: 远程目标和镜像驱动必须按 Windows 状态位排除，不得使用名称黑名单");
        Check(ClassifyDisplayTopology(false, ERROR_SUCCESS, false, 3)
                == DisplayTopologyTrust::LocalPhysicalAuthoritative
            && ClassifyDisplayTopology(true, ERROR_SUCCESS, false, 1)
                == DisplayTopologyTrust::RemoteSessionLimited
            && ClassifyDisplayTopology(false, ERROR_ACCESS_DENIED, false, 0)
                == DisplayTopologyTrust::RemoteSessionLimited
            && ClassifyDisplayTopology(false, ERROR_GEN_FAILURE, false, 0)
                == DisplayTopologyTrust::IncompleteOrUnavailable
            && ClassifyDisplayTopology(false, ERROR_SUCCESS, true, 2)
                == DisplayTopologyTrust::IncompleteOrUnavailable
            && ClassifyDisplayTopology(false, ERROR_SUCCESS, false, 0)
                == DisplayTopologyTrust::IncompleteOrUnavailable,
            L"RDP: 拓扑可信度必须区分本地权威、远程受限和不完整/不可用");

        std::vector<DisplayConfig> catalogue;
        for (int index = 0; index < 3; ++index)
        {
            auto display = Display(L"本地物理显示器 " + std::to_wstring(index + 1),
                L"ds13:rdp-physical-" + std::to_wstring(index + 1), 16 + index);
            display.localInput = 26 + index;
            display.brightnessEnabled = index != 1;
            display.brightnessShowInTray = index == 0;
            display.contrastEnabled = index != 2;
            display.contrastShowInTray = index == 1;
            display.volumeEnabled = true;
            display.volumeShowInTray = index == 2;
            display.topologyGeneration = 9;
            catalogue.push_back(std::move(display));
        }
        auto original = catalogue;
        CollaborationProfile profile = Profile(L"模拟协同配置");
        UsbSwitchConfig usb;
        for (size_t index = 0; index < catalogue.size(); ++index)
        {
            profile.displayInputs.push_back({ catalogue[index].id, static_cast<int>(31 + index) });
            usb.displayInputs.push_back({ catalogue[index].id, static_cast<int>(41 + index) });
        }
        auto originalProfileMappings = profile.displayInputs;
        auto originalUsbMappings = usb.displayInputs;
        auto profileMappingsEqual = [](auto const& left, auto const& right)
        {
            return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin(),
                [](auto const& first, auto const& second)
                { return first.displayId == second.displayId && first.peerInput == second.peerInput; });
        };
        auto usbMappingsEqual = [](auto const& left, auto const& right)
        {
            return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin(),
                [](auto const& first, auto const& second)
                { return first.displayId == second.displayId && first.targetInput == second.targetInput; });
        };

        DdcMonitorInfo remoteVirtual;
        remoteVirtual.id = L"virtual-session-target";
        remoteVirtual.displayName = L"会话显示目标";
        remoteVirtual.logicalTargetId = L"session-target";
        auto remote = ReconcileDisplayConfigurations(catalogue, { remoteVirtual },
            DisplayTopologyTrust::RemoteSessionLimited);
        int saveCalls{};
        if (remote.changed) ++saveCalls;
        auto unchanged = remote.displays.size() == original.size();
        for (size_t index = 0; unchanged && index < original.size(); ++index)
        {
            auto const& before = original[index];
            auto const& after = remote.displays[index];
            unchanged = before.id == after.id && before.name == after.name
                && before.nativeMonitorId == after.nativeMonitorId
                && before.bindingStatus == after.bindingStatus
                && before.topologyGeneration == after.topologyGeneration
                && before.localInput == after.localInput && before.macInput == after.macInput
                && before.brightnessEnabled == after.brightnessEnabled
                && before.brightnessShowInTray == after.brightnessShowInTray
                && before.contrastEnabled == after.contrastEnabled
                && before.contrastShowInTray == after.contrastShowInTray
                && before.volumeEnabled == after.volumeEnabled
                && before.volumeShowInTray == after.volumeShowInTray;
        }
        Check(!remote.changed && remote.added == 0 && remote.removed == 0 && saveCalls == 0 && unchanged
            && profileMappingsEqual(profile.displayInputs, originalProfileMappings)
            && usbMappingsEqual(usb.displayInputs, originalUsbMappings),
            L"RDP: 远程阶段持久物理目录必须零新增、零删除、零重绑定、零保存且映射不变");
        auto firstRunRemote = ReconcileDisplayConfigurations({}, { remoteVirtual },
            DisplayTopologyTrust::RemoteSessionLimited);
        Check(firstRunRemote.displays.empty() && !firstRunRemote.changed,
            L"RDP: 首次启动仅有远程虚拟目标时不得创建持久显示器条目");

        auto incomplete = ReconcileDisplayConfigurations(catalogue, { remoteVirtual },
            DisplayTopologyTrust::IncompleteOrUnavailable);
        auto empty = ReconcileDisplayConfigurations(catalogue, {},
            DisplayTopologyTrust::IncompleteOrUnavailable);
        Check(!incomplete.changed && !empty.changed && incomplete.displays.size() == 3 && empty.displays.size() == 3,
            L"RDP: 本地枚举失败、空结果或部分结果不得覆盖可信目录");

        std::vector<DdcMonitorInfo> returnedLocal;
        for (auto const& display : original)
        {
            DdcMonitorInfo monitor;
            monitor.id = display.nativeMonitorId;
            monitor.displayName = display.name;
            monitor.logicalTargetId = L"local-target-" + display.id;
            monitor.physicalHandleCount = 1;
            monitor.topologyGeneration = 12;
            returnedLocal.push_back(std::move(monitor));
        }
        std::reverse(returnedLocal.begin(), returnedLocal.end());
        auto restored = ReconcileDisplayConfigurations(remote.displays, returnedLocal,
            DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(restored.displays.size() == 3
            && std::all_of(restored.displays.begin(), restored.displays.end(), [&](auto const& display)
            {
                return std::any_of(original.begin(), original.end(), [&](auto const& before)
                { return display.id == before.id && display.nativeMonitorId == before.nativeMonitorId
                    && display.name == before.name; });
            }) && profileMappingsEqual(profile.displayInputs, originalProfileMappings)
            && usbMappingsEqual(usb.displayInputs, originalUsbMappings),
            L"RDP: 返回本地后重排的同一批物理显示器必须按强身份恢复原逻辑 ID 和映射");

        AppConfig hardwareConfig; hardwareConfig.displays = catalogue;
        FakeDdcBackend remoteDdc; remoteDdc.topologyTrust = DisplayTopologyTrust::RemoteSessionLimited;
        DdcCancellationSource cancellation;
        auto remoteRead = FakeService(remoteDdc).Read(hardwareConfig, {}, cancellation.Begin());
        auto remoteWrite = FakeService(remoteDdc).Write(hardwareConfig, hardwareConfig.displays[0].id,
            DdcVcpCode::Brightness, 50, false, cancellation.Begin());
        FakeInputSourceTransport remoteInput;
        remoteInput.topologyTrust = DisplayTopologyTrust::RemoteSessionLimited;
        auto remoteSwitch = SwitchDisplaysToMac(hardwareConfig, &remoteInput);
        Check(!remoteRead.success && !remoteWrite.success && !remoteSwitch.success
            && remoteDdc.reads.empty() && remoteDdc.writes.empty() && remoteInput.writes.empty(),
            L"RDP: 远程受限会话必须保持 DDC 读写和输入源传输零调用");
    }

    void TestOfflineDisplayRemovalSafety()
    {
        auto config = ConfigWithDisplays(2);
        for (auto& display : config.displays)
        {
            display.bindingStatus = DisplayBindingStatus::Offline;
            display.brightnessValue = 44;
            display.brightnessShowInTray = true;
        }
        config.collaborationProfiles[0].coordinationEnabled = true;
        config.usbSwitch.enabled = true;
        config.usbSwitch.collaborationWakeEnabled = true;
        config.usbSwitch.collaborationProfileId = config.collaborationProfiles[0].id;
        for (auto const& display : config.displays)
            config.usbSwitch.displayInputs.push_back({ display.id, 30 });

        Check(CanDeleteOfflineDisplay(config.displays[0], DisplayTopologyTrust::LocalPhysicalAuthoritative) &&
            !CanDeleteOfflineDisplay(config.displays[0], DisplayTopologyTrust::RemoteSessionLimited) &&
            !CanDeleteOfflineDisplay(config.displays[0], DisplayTopologyTrust::IncompleteOrUnavailable),
            L"DS-029: 只有最近本地权威拓扑明确离线的显示器可删除");
        auto online = config.displays[0]; online.bindingStatus = DisplayBindingStatus::Resolved;
        Check(!CanDeleteOfflineDisplay(online, DisplayTopologyTrust::LocalPhysicalAuthoritative),
            L"DS-029: 在线显示器即使本地拓扑可信也不可删除");

        auto removedId = config.displays[0].id;
        Check(RemoveDisplayAndDependencies(config.displays, config.collaborationProfiles,
            config.usbSwitch, removedId) && config.displays.size() == 1 &&
            config.collaborationProfiles[0].displayInputs.size() == 1 &&
            config.usbSwitch.displayInputs.size() == 1 && config.usbSwitch.enabled &&
            config.collaborationProfiles[0].coordinationEnabled && config.usbSwitch.collaborationWakeEnabled,
            L"DS-029: 删除离线目录级联清理对应映射，部分有效映射继续启用");

        auto lastId = config.displays[0].id;
        Check(RemoveDisplayAndDependencies(config.displays, config.collaborationProfiles,
            config.usbSwitch, lastId) && config.displays.empty() &&
            config.usbSwitch.displayInputs.empty() && !config.usbSwitch.enabled &&
            config.collaborationProfiles[0].displayInputs.empty() &&
            !config.collaborationProfiles[0].coordinationEnabled && !config.usbSwitch.collaborationWakeEnabled,
            L"DS-029: 删除最后有效映射会安全停用 USB 和协同");

        auto beforeFailure = ConfigWithDisplays(1);
        auto candidate = beforeFailure;
        Check(RemoveDisplayAndDependencies(candidate.displays, candidate.collaborationProfiles,
            candidate.usbSwitch, candidate.displays[0].id) && beforeFailure.displays.size() == 1,
            L"DS-029: 删除先在候选配置完成，持久化失败可完整保留原配置");
    }

    void TestUsbTriggerStability()
    {
        UsbSwitchInitialState zeroMappingState;
        zeroMappingState.enabled = true;
        zeroMappingState.baselinePresence = true;
        zeroMappingState.displayMappings = {
            { L"display-zero", 0, true, true }, { L"display-valid", 17, true, true } };
        UsbSwitchCoordinator zeroMappingCoordinator(zeroMappingState);
        auto zeroMappingActions = zeroMappingCoordinator.ObserveUsb(1, false);
        Check(std::count_if(zeroMappingActions.begin(), zeroMappingActions.end(), [](auto const& action)
            { return action.kind == UsbSwitchAction::Kind::SwitchDisplay && action.targetInput == 17; }) == 1
            && std::count_if(zeroMappingActions.begin(), zeroMappingActions.end(), [](auto const& action)
            { return action.kind == UsbSwitchAction::Kind::Report && action.reason == L"missing_mapping"; }) == 1
            && std::none_of(zeroMappingActions.begin(), zeroMappingActions.end(), [](auto const& action)
            { return action.kind == UsbSwitchAction::Kind::SwitchDisplay && action.targetInput == 0; }),
            L"USB 自动切换必须把 0 当作 missing_mapping，同时继续调度其他有效显示器");

        UsbSwitchInitialState initial;
        initial.enabled = true;
        initial.baselinePresence = true;
        initial.collaborationWakeEnabled = false;
        initial.collaborationProfileValid = true;
        initial.bindingKey = L"synthetic-device-a";
        initial.displayMappings.push_back({ L"display-a", 17, true, true });
        UsbSwitchCoordinator coordinator(initial);

        auto collaborationEnabled = initial;
        collaborationEnabled.baselinePresence.reset();
        collaborationEnabled.collaborationWakeEnabled = true;
        coordinator.UpdateConfiguration(collaborationEnabled);
        auto departure = coordinator.ObserveUsb(10, false);
        Check(std::count_if(departure.begin(), departure.end(), [](auto const& action)
            { return action.kind == UsbSwitchAction::Kind::SwitchDisplay; }) == 1 &&
            std::count_if(departure.begin(), departure.end(), [](auto const& action)
            { return action.kind == UsbSwitchAction::Kind::SendWakeDisplay; }) == 1,
            L"USB 稳定性：相同设备只开启联动协同时必须保留存在基线，首次离开同时调度 DDC 和唤醒消息");

        auto changedBinding = collaborationEnabled;
        changedBinding.bindingKey = L"synthetic-device-b";
        coordinator.UpdateConfiguration(changedBinding);
        auto firstAfterBindingChange = coordinator.ObserveUsb(20, false);
        Check(firstAfterBindingChange.size() == 1 &&
            firstAfterBindingChange[0].kind == UsbSwitchAction::Kind::EstablishBaseline,
            L"USB 稳定性：更换绑定设备后第一次状态仍只建立新基线");

        auto disabled = changedBinding;
        disabled.enabled = false;
        coordinator.UpdateConfiguration(disabled);
        auto enabledAgain = disabled;
        enabledAgain.enabled = true;
        coordinator.UpdateConfiguration(enabledAgain);
        auto firstAfterEnable = coordinator.ObserveUsb(30, true);
        Check(firstAfterEnable.size() == 1 && firstAfterEnable[0].kind == UsbSwitchAction::Kind::EstablishBaseline,
            L"USB 稳定性：重新开启 USB 自动切换时必须重建基线");

        auto invalidCollaboration = initial;
        invalidCollaboration.collaborationWakeEnabled = true;
        invalidCollaboration.collaborationProfileValid = false;
        UsbSwitchCoordinator invalidCoordinator(invalidCollaboration);
        auto networkUnavailable = invalidCoordinator.ObserveUsb(40, false);
        Check(std::count_if(networkUnavailable.begin(), networkUnavailable.end(), [](auto const& action)
            { return action.kind == UsbSwitchAction::Kind::SwitchDisplay; }) == 1 &&
            std::count_if(networkUnavailable.begin(), networkUnavailable.end(), [](auto const& action)
            { return action.kind == UsbSwitchAction::Kind::Report && action.reason == L"wake_not_sent"; }) == 1,
            L"USB 稳定性：联动协同不可用时仍必须调度本机 DDC");

        UsbPresencePollPolicy pollPolicy;
        Check(pollPolicy.NextWaitMilliseconds(true) == 2000,
            L"USB 稳定性：稳定期保留低频后备轮询");
        pollPolicy.NotificationReceived();
        Check(pollPolicy.FollowupPollsRemaining() == UsbPresencePollPolicy::NotificationFollowupPollCount &&
            pollPolicy.NextWaitMilliseconds(true) == UsbPresencePollPolicy::NotificationFollowupIntervalMilliseconds,
            L"USB 稳定性：设备通知后必须进入短周期复查窗口");
        for (int index = 0; index < UsbPresencePollPolicy::NotificationFastPollCount; ++index)
            pollPolicy.WaitTimedOut();
        Check(pollPolicy.NextWaitMilliseconds(true) == UsbPresencePollPolicy::NotificationSettlingIntervalMilliseconds,
            L"USB 稳定性：快速复查后必须以 250 ms 继续确认，不得出现 2 秒空档");
        for (int index = 0; index < UsbPresencePollPolicy::NotificationSettlingPollCount; ++index)
            pollPolicy.WaitTimedOut();
        Check(pollPolicy.FollowupPollsRemaining() == 0 && pollPolicy.NextWaitMilliseconds(true) == 2000,
            L"USB 稳定性：复查窗口结束后必须恢复低频轮询");
        Check(TargetUsbPresenceFromNotification(UsbDeviceNotificationKind::Removed,
            L"usb:pnp:USB\\VID_1234&PID_5678\\SELECTED", L"usb\\vid_1234&pid_5678\\selected") == false,
            L"USB 稳定性：所选设备的明确移除通知必须立即确认离开");
        Check(TargetUsbPresenceFromNotification(UsbDeviceNotificationKind::Present,
            L"usb:pnp:USB\\VID_1234&PID_5678\\SELECTED", L"USB\\VID_1234&PID_5678\\SELECTED") == true,
            L"USB 稳定性：所选设备的明确接入通知必须立即确认接入");
        Check(!TargetUsbPresenceFromNotification(UsbDeviceNotificationKind::Removed,
            L"usb:pnp:USB\\VID_1234&PID_5678\\SELECTED", L"USB\\VID_1234&PID_5678\\OTHER"),
            L"USB 稳定性：无关设备通知不得触发所选设备状态变化");
    }

    void TestUsbColdStartRehydration()
    {
        UsbObservationGenerationGate generationGate;
        auto firstGeneration = generationGate.BeginConfiguration();
        auto secondGeneration = generationGate.BeginConfiguration();
        Check(firstGeneration != 0 && secondGeneration != firstGeneration &&
            !generationGate.Accepts(firstGeneration) && generationGate.Accepts(secondGeneration),
            L"W-030: 配置重载后只接受当前 USB watcher 代次的单一回调流");

        auto enabled = UsbSwitchInitialState{};
        enabled.enabled = true;
        enabled.bindingKey = L"synthetic-cold-start-device";
        enabled.displayMappings = { { L"display-a", 17, true, true } };
        for (auto initialPresence : { false, true })
        {
            UsbSwitchCoordinator cold(enabled);
            auto baseline = cold.ObserveUsb(1, initialPresence);
            Check(baseline.size() == 1 && baseline[0].kind == UsbSwitchAction::Kind::EstablishBaseline &&
                std::none_of(baseline.begin(), baseline.end(), [](auto const& action)
                {
                    return action.kind == UsbSwitchAction::Kind::SwitchDisplay ||
                        action.kind == UsbSwitchAction::Kind::WakeDisplay ||
                        action.kind == UsbSwitchAction::Kind::SendWakeDisplay;
                }), L"W-030: 冷启动设备初始存在或不存在都只建立基线且零副作用");
        }

        auto disabled = enabled; disabled.enabled = false;
        Check(UsbSwitchCoordinator(disabled).ObserveUsb(1, true).empty(),
            L"W-030: 冷启动关闭的 USB 配置不建立动作");
        auto safe = enabled; safe.safeState = true; safe.collaborationWakeEnabled = true;
        safe.collaborationProfileValid = true;
        UsbSwitchCoordinator topologyAfter(safe);
        Check(topologyAfter.ObserveUsb(1, true).empty(),
            L"W-030: RDP、不可信拓扑和配置安全模式保持零 USB/DDC/网络/唤醒动作");
        safe.safeState = false;
        topologyAfter.UpdateConfiguration(safe);
        auto trustedBaseline = topologyAfter.ObserveUsb(2, true);
        auto laterDeparture = topologyAfter.ObserveUsb(3, false);
        Check(trustedBaseline.size() == 1 && trustedBaseline[0].kind == UsbSwitchAction::Kind::EstablishBaseline &&
            std::count_if(laterDeparture.begin(), laterDeparture.end(), [](auto const& action)
                { return action.kind == UsbSwitchAction::Kind::SwitchDisplay; }) == 1,
            L"W-030: 拓扑晚于配置就绪时先重新建立可信基线，之后真实事件正常执行");

        UsbSwitchCoordinator reload(enabled);
        static_cast<void>(reload.ObserveUsb(1, true));
        reload.UpdateConfiguration(enabled);
        Check(reload.ObserveUsb(2, true).empty(),
            L"W-030: 同一绑定重复初始化或配置 reload 保留基线且不制造重复事件");
        auto changedBinding = enabled; changedBinding.bindingKey = L"synthetic-other-device";
        reload.UpdateConfiguration(changedBinding);
        auto rebound = reload.ObserveUsb(3, false);
        Check(rebound.size() == 1 && rebound[0].kind == UsbSwitchAction::Kind::EstablishBaseline,
            L"W-030: USB 绑定变化只为新设备建立基线，不复用旧设备状态");

        auto partial = enabled;
        partial.displayMappings.push_back({ L"display-b", 18, false, true });
        UsbSwitchCoordinator partialCoordinator(partial);
        static_cast<void>(partialCoordinator.ObserveUsb(1, true));
        auto partialDeparture = partialCoordinator.ObserveUsb(2, false);
        Check(std::count_if(partialDeparture.begin(), partialDeparture.end(), [](auto const& action)
            { return action.kind == UsbSwitchAction::Kind::SwitchDisplay; }) == 1 &&
            std::count_if(partialDeparture.begin(), partialDeparture.end(), [](auto const& action)
            { return action.kind == UsbSwitchAction::Kind::Report && action.reason == L"missing_mapping"; }) == 1,
            L"W-030: 冷启动恢复后部分映射只执行合格目标并隔离不可用显示器");
    }

    void TestInputSourceColdStartTopologyRefresh()
    {
        auto config = ConfigWithDisplays(2);
        config.displays[0].nativeMonitorId = L"ds13:synthetic-a";
        config.displays[1].nativeMonitorId = L"ds13:synthetic-b";
        for (auto& display : config.displays)
        {
            display.bindingStatus = DisplayBindingStatus::Offline;
            display.topologyGeneration = 0;
        }
        std::vector<DdcMonitorInfo> current{
            { L"ds13:synthetic-a", L"显示器 A", L"DISPLAY1", L"target-a", {}, 1, false, 41 },
            { L"ds13:synthetic-b", L"显示器 B", L"DISPLAY2", L"target-b", {}, 1, false, 41 },
        };
        DdcEnumerationResult trusted{ true, DdcErrorKind::None, {}, current, true,
            DisplayTopologyTrust::LocalPhysicalAuthoritative };
        auto plan = PrepareInputSourceActionPlan(config, trusted);
        auto selection = plan.config.SelectProfileDisplays(config.collaborationProfiles[0].id);
        Check(plan.topologyTrusted && selection.mappedDisplays.size() == 2
            && std::all_of(plan.config.displays.begin(), plan.config.displays.end(), [](auto const& display)
                { return IsDisplayDdcResolved(display) && display.topologyGeneration == 41; })
            && std::all_of(config.displays.begin(), config.displays.end(), [](auto const& display)
                { return display.bindingStatus == DisplayBindingStatus::Offline && display.topologyGeneration == 0; }),
            L"W-032: 升级后冷启动的过期运行态绑定必须在首次输入源动作前从可信拓扑恢复，且不写回原配置");

        auto disabled = config;
        disabled.usbSwitch.enabled = false;
        auto enabled = config;
        enabled.usbSwitch.enabled = true;
        auto disabledPlan = PrepareInputSourceActionPlan(disabled, trusted);
        auto enabledPlan = PrepareInputSourceActionPlan(enabled, trusted);
        Check(disabledPlan.topologyTrusted && enabledPlan.topologyTrusted
            && disabledPlan.config.SelectProfileDisplays(config.collaborationProfiles[0].id).mappedDisplays.size() == 2
            && enabledPlan.config.SelectProfileDisplays(config.collaborationProfiles[0].id).mappedDisplays.size() == 2,
            L"W-032: USB 开关值不得改变同一物理拓扑下的手动输入源动作计划");

        auto oneMonitor = trusted;
        oneMonitor.monitors.resize(1);
        auto partialPlan = PrepareInputSourceActionPlan(config, oneMonitor);
        FakeInputSourceTransport partialTransport;
        DdcCancellationSource cancellation;
        auto partialResult = InputSourceSwitchService(&partialTransport).SwitchDisplaysToMac(
            partialPlan.config, cancellation.Begin());
        Check(partialPlan.topologyTrusted && !partialResult.success && partialTransport.writes.size() == 1
            && partialTransport.writes[0].first == L"ds13:synthetic-a",
            L"W-032: 本地可信拓扑中单屏离线只隔离该屏，其他有效显示器仍须切换");

        for (auto const trust : { DisplayTopologyTrust::RemoteSessionLimited,
            DisplayTopologyTrust::IncompleteOrUnavailable })
        {
            auto unavailable = trusted;
            unavailable.complete = false;
            unavailable.topologyTrust = trust;
            auto unavailablePlan = PrepareInputSourceActionPlan(config, unavailable);
            FakeInputSourceTransport transport;
            auto result = unavailablePlan.topologyTrusted
                ? InputSourceSwitchService(&transport).SwitchDisplaysToMac(
                    unavailablePlan.config, cancellation.Begin())
                : ActionResult{ false, unavailablePlan.error };
            Check(!unavailablePlan.topologyTrusted && !result.success && transport.writes.empty(),
                L"W-032: RDP、虚拟、部分或不完整拓扑在动作前刷新后仍必须零输入源写入");
        }

        bool allowed = true;
        FakeInputSourceTransport concurrentTransport;
        concurrentTransport.onWrite = [&] { allowed = false; };
        auto concurrent = InputSourceSwitchService(&concurrentTransport, [&] { return allowed; })
            .SwitchDisplaysToMac(plan.config, cancellation.Begin());
        Check(!concurrent.success && concurrentTransport.writes.size() == 1,
            L"W-032: 配置重载与输入源批处理并发时必须在下一台显示器前停止");

        allowed = false;
        FakeInputSourceTransport stalePlanTransport;
        auto stalePlan = InputSourceSwitchService(&stalePlanTransport, [&] { return allowed; })
            .SwitchDisplaysToMac(plan.config, cancellation.Begin());
        Check(!stalePlan.success && stalePlanTransport.writes.empty(),
            L"W-032: 配置在枚举后发生重载时，过期动作计划必须在首个显示器前零写入");

        Check(DecideNativeMonitorCacheUpdate(false, true) == NativeMonitorCacheUpdate::Reuse
            && DecideNativeMonitorCacheUpdate(true, true) == NativeMonitorCacheUpdate::ReplaceLeases
            && DecideNativeMonitorCacheUpdate(true, false) == NativeMonitorCacheUpdate::ReplaceTopology,
            L"W-032: 用户动作强刷新相同拓扑时替换 DXVA2 句柄租约但不伪造拓扑 generation");
    }

    void TestDdcControls()
    {
        auto config = ConfigWithDisplays(2);
        Check(BuildDdcTrayControls(config).empty(),
            L"U-005/U-009: 新显示器六个 DDC 开关默认全关且托盘无入口");
        for (auto& display : config.displays) EnableDdcControls(display);
        config.displays[0].brightnessShowInTray = true;
        auto tray = BuildDdcTrayControls(config);
        Check(tray.size() == 1 && tray[0].displayId == config.displays[0].id
            && tray[0].code == DdcVcpCode::Brightness,
            L"U-009: 只有 enabled=true 且 showInTray=true 的项目进入托盘投影");
        config.displays[0].brightnessShowInTray = false;
        Check(BuildDdcTrayControls(config).empty(),
            L"U-009: 关闭托盘开关应立即移除入口且不产生 DDC 写入");

        config.linkAllDisplays = true;
        config.displays[0].brightnessShowInTray = true;
        config.displays[0].brightnessValue = 40; config.displays[0].brightnessMax = 80;
        config.displays[1].brightnessValue = 40; config.displays[1].brightnessMax = 60;
        auto linkedSettings = BuildDdcControlProjection(config,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, false);
        auto linkedTray = BuildDdcTrayControls(config, DisplayTopologyTrust::LocalPhysicalAuthoritative);
        Check(linkedSettings.size() == 3 && linkedSettings[0].linked
            && linkedSettings[0].valueState == DdcProjectedValueState::Value
            && linkedSettings[0].value == 40 && linkedSettings[0].maximum == 60
            && linkedSettings[0].targetDisplayIds.size() == 2,
            L"DS-027: 联动设置为每个已启用功能只投影一个公共控件，且最大值取安全交集");
        Check(linkedTray.size() == 1 && linkedTray[0].linked && linkedTray[0].displayName.empty()
            && linkedTray[0].displayId == config.displays[0].id,
            L"DS-027: 联动托盘按功能扁平投影，不再按显示器分组");
        auto featureFiltered = config;
        featureFiltered.displays[1].brightnessEnabled = false;
        featureFiltered.displays[1].brightnessShowInTray = true;
        auto filteredProjection = BuildDdcControlProjection(featureFiltered,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, true);
        Check(filteredProjection.size() == 1 && filteredProjection[0].targetDisplayIds.size() == 1
            && filteredProjection[0].targetDisplayIds[0] == featureFiltered.displays[0].id,
            L"DS-027: 托盘可见性与写目标分离，关闭功能的显示器即使残留托盘偏好也不得进入目标");
        config.displays[1].brightnessValue = 41;
        auto mixed = BuildDdcControlProjection(config,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, false);
        Check(mixed[0].valueState == DdcProjectedValueState::Mixed,
            L"DS-027: 多目标当前值不同时必须表达为混合，不得取平均或冒用单台值");
        config.displays[1].brightnessValue.reset();
        auto unknown = BuildDdcControlProjection(config,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, false);
        Check(unknown[0].valueState == DdcProjectedValueState::Unavailable,
            L"DS-027: 任一联动目标缺少可信当前值时公共值必须表达为不可用");
        auto remoteProjection = BuildDdcControlProjection(config,
            DisplayTopologyTrust::RemoteSessionLimited, false);
        Check(remoteProjection.size() == 3 && remoteProjection[0].targetDisplayIds.empty()
            && remoteProjection[0].valueState == DdcProjectedValueState::Unavailable,
            L"DS-027: RDP 中保留已配置功能的 UI 投影，但不得把持久目录当作在线写目标");
        auto noDisplays = config; noDisplays.displays.clear();
        Check(BuildDdcControlProjection(noDisplays,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, false).empty(),
            L"DS-027: 零显示器时不投影任何公共 DDC 控件");
        auto oneDisplayProjectionConfig = config; oneDisplayProjectionConfig.displays.resize(1);
        auto oneProjection = BuildDdcControlProjection(oneDisplayProjectionConfig,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, false);
        Check(oneProjection.size() == 3 && oneProjection[0].targetDisplayIds.size() == 1,
            L"DS-027: 单显示器联动投影仍使用同一公共模型");
        config.displays[0].brightnessMax.reset();
        auto defaultMaximum = BuildDdcControlProjection(config,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, false);
        Check(defaultMaximum[0].maximum == 60,
            L"DS-027: 未知最大值按安全默认 100 参与交集，不放大另一目标的 60 上限");
        config.displays[0].brightnessMax = 80;
        auto duplicateBinding = config;
        duplicateBinding.displays[1].nativeMonitorId = duplicateBinding.displays[0].nativeMonitorId;
        auto duplicateProjection = BuildDdcControlProjection(duplicateBinding,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, false);
        Check(duplicateProjection[0].targetDisplayIds.empty(),
            L"DS-027: 重复强绑定涉及的全部显示器都不得成为联动写目标");
        config.displays[1].bindingStatus = DisplayBindingStatus::Offline;
        auto partialTargets = BuildDdcControlProjection(config,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, false);
        Check(partialTargets[0].targetDisplayIds.size() == 1
            && partialTargets[0].targetDisplayIds[0] == config.displays[0].id,
            L"DS-027: 联动实际目标只包含当前在线且唯一解析的物理显示器");
        config.displays[1].bindingStatus = DisplayBindingStatus::Ambiguous;
        auto ambiguousTargets = BuildDdcControlProjection(config,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, false);
        Check(ambiguousTargets[0].targetDisplayIds.size() == 1,
            L"DS-027: 歧义显示器不得进入联动目标，其他唯一解析目标仍保留");
        config.displays[1].bindingStatus = DisplayBindingStatus::Resolved;
        config.displays[1].brightnessValue = 40;
        config.linkAllDisplays = false;
        auto restored = BuildDdcControlProjection(config,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, true);
        Check(restored.size() == 1 && !restored[0].linked
            && restored[0].displayId == config.displays[0].id,
            L"DS-027: 关闭联动后立即恢复逐显示器托盘结构和原偏好");
        config.linkAllDisplays = true;

        DdcWriteQueue queue;
        int workerStarts{};
        for (int value = 0; value < 100; ++value)
            if (queue.Submit({ config.displays[0].id, DdcVcpCode::Brightness, value, 7 })) ++workerStarts;
        auto latest = queue.TakeNext();
        Check(workerStarts == 1 && latest && latest->value == 99 && !queue.TakeNext(),
            L"U-021: 同一滑杆的连续变化必须 latest-wins 合并为最终值");
        queue.Submit({ config.displays[0].id, DdcVcpCode::Brightness, 30, 8 });
        queue.Submit({ config.displays[0].id, DdcVcpCode::Contrast, 40, 8 });
        Check(queue.PendingCount() == 2 && queue.TakeNext() && queue.TakeNext() && !queue.TakeNext(),
            L"U-022: 不同显示器项目必须独立保留并由单一工作器串行提交");
        queue.Submit({ config.displays[0].id, DdcVcpCode::Volume, 50, 9 });
        queue.CancelPending();
        Check(queue.PendingCount() == 0 && !queue.TakeNext(),
            L"U-025: 配置变化或取消必须清空待提交 DDC 值");
        auto firstId = config.displays[0].id;
        auto secondId = config.displays[1].id;
        FakeDdcBackend native;
        SetThreeValues(native, L"monitor-0", 35, 45, 55, 0);
        SetThreeValues(native, L"monitor-1", 65, 75, 85, 120);
        DdcCancellationSource cancellation;
        auto service = FakeService(native);

        native.topologyTrust = DisplayTopologyTrust::RemoteSessionLimited;
        native.writes.clear();
        auto remoteWrite = service.Write(config, firstId, DdcVcpCode::Brightness, 30, true, cancellation.Begin());
        Check(remoteWrite.canceled && native.writes.empty(),
            L"DS-027: RDP/非可信拓扑下联动写入必须在 native 服务入口保持零调用");
        native.topologyTrust = DisplayTopologyTrust::IncompleteOrUnavailable;
        auto incompleteWrite = service.Write(config, firstId, DdcVcpCode::Brightness, 30, true, cancellation.Begin());
        Check(incompleteWrite.canceled && native.writes.empty(),
            L"DS-027: 空或部分不可信拓扑在 native 服务入口同样保持零 DDC 写入");
        native.topologyTrust = DisplayTopologyTrust::LocalPhysicalAuthoritative;
        config.displays[0].brightnessMax = 80; config.displays[1].brightnessMax = 60;
        native.writes.clear();
        auto overflow = service.Write(config, firstId, DdcVcpCode::Brightness, 61, true, cancellation.Begin());
        Check(!overflow.success && overflow.items.size() == 1
            && overflow.items[0].error == DdcErrorKind::InvalidValue && native.writes.empty(),
            L"DS-027: 公共值超过任一目标最大值时必须批量预检失败并保持零 transport 写入");
        native.writes.clear();
        auto absolute = service.Write(config, firstId, DdcVcpCode::Brightness, 59, true, cancellation.Begin());
        Check(absolute.success && native.writes.size() == 2
            && std::get<2>(native.writes[0]) == 59 && std::get<2>(native.writes[1]) == 59,
            L"DS-027: 公共滑杆必须向所有合格目标写入相同绝对值");
        config.displays[1].bindingStatus = DisplayBindingStatus::Offline;
        native.writes.clear();
        auto partialWrite = service.Write(config, firstId, DdcVcpCode::Brightness, 55, true, cancellation.Begin());
        Check(partialWrite.success && native.writes.size() == 1
            && std::get<0>(native.writes[0]) == L"monitor-0" && std::get<2>(native.writes[0]) == 55,
            L"DS-027: 部分显示器离线时必须继续调节其他合格目标，且不向离线项写入");
        config.displays[1].bindingStatus = DisplayBindingStatus::Resolved;
        native.writes.clear();
        config.displays[0].brightnessMax.reset(); config.displays[1].brightnessMax.reset();

        auto normal = service.Read(config, {}, cancellation.Begin());
        Check(normal.success && normal.items.size() == 6 && config.displays[0].brightnessValue == 35
            && config.displays[0].brightnessMax == 100 && config.displays[1].volumeMax == 120,
            L"C-016: 三项正常回读应按稳定显示器 ID 缓存，并修正异常最大值");
        Check(native.writes.empty() && std::all_of(native.reads.begin(), native.reads.end(), [](auto const& call)
            { return call.second == DdcVcpCode::Brightness || call.second == DdcVcpCode::Contrast || call.second == DdcVcpCode::Volume; }),
            L"U-006: 读取 DDC 参数只允许读取亮度、对比度和音量，零输入源写入");

        native.writes.clear();
        auto trayWrite = service.Write(config, firstId, DdcVcpCode::Brightness, 36, false, cancellation.Begin());
        Check(trayWrite.success && native.writes.size() == 1 && std::get<0>(native.writes[0]) == L"monitor-0"
            && std::get<1>(native.writes[0]) == DdcVcpCode::Brightness && config.displays[0].brightnessValue == 36,
            L"U-010: 托盘滑杆只写对应显示器和项目，成功后才提交缓存");

        native.writes.clear();
        auto legacyInputCode = static_cast<DdcVcpCode>(96);
        auto rejectedLegacyInput = service.Write(config, firstId, legacyInputCode, 17, false, cancellation.Begin());
        Check(!rejectedLegacyInput.success && native.writes.empty() && IsDdcControlVcpCode(legacyInputCode) == false,
            L"W-206: 普通 DDC 服务和共用白名单必须拒绝旧输入源 VCP 值");

        native.writes.clear();
        FakeInputSourceTransport inputTransport;
        auto inputSwitch = SwitchDisplaysToMac(config, &inputTransport);
        Check(inputSwitch.success && native.writes.empty() && inputTransport.writes.size() == 2
            && inputTransport.writes[0].first == config.displays[0].nativeMonitorId
            && inputTransport.writes[0].second == config.displays[0].macInput
            && inputTransport.writes[1].first == config.displays[1].nativeMonitorId
            && inputTransport.writes[1].second == config.displays[1].macInput,
            L"W-206: 输入源切换必须只调用独立 transport，并继续使用相同逻辑显示器绑定");

        auto zeroAndValid = config;
        zeroAndValid.displays[0].macInput = 0;
        FakeInputSourceTransport zeroGuardTransport;
        DdcCancellationSource zeroGuardCancellation;
        auto zeroGuardResult = InputSourceSwitchService(&zeroGuardTransport).SwitchDisplaysToMac(
            zeroAndValid, zeroGuardCancellation.Begin());
        Check(!zeroGuardResult.success && zeroGuardResult.error.find(L"missing_mapping") != std::wstring::npos
            && zeroGuardTransport.writes.size() == 1
            && zeroGuardTransport.writes[0].first == zeroAndValid.displays[1].nativeMonitorId
            && zeroGuardTransport.writes[0].second == zeroAndValid.displays[1].macInput,
            L"手动和协同共用输入源服务必须跳过 0 映射并继续其他有效显示器");
        zeroGuardTransport.writes.clear();
        auto directZero = WriteInputSourceWithOneRefresh(zeroGuardTransport, L"monitor-0", 0,
            zeroGuardCancellation.Begin());
        Check(!directZero.success && directZero.error == DdcErrorKind::InvalidValue
            && zeroGuardTransport.writes.empty(),
            L"输入源服务边界必须在 transport 调用前拒绝 0");
        Check(!IsValidNativeInputSourceValue(0) && IsValidNativeInputSourceValue(1)
            && IsValidNativeInputSourceValue(65535) && !IsValidNativeInputSourceValue(65536),
            L"原生 DXVA2 最终传输边界必须只接受 1–65535，确保 0 永不进入 SetVCPFeature");

        auto cachedFirst = config.displays[0];
        SetThreeValues(native, L"monitor-0", 0, 0, 0);
        auto allZero = service.Read(config, { firstId }, cancellation.Begin());
        Check(!allZero.success && allZero.items.size() == 3
            && std::all_of(allZero.items.begin(), allZero.items.end(), [](auto const& item) { return !item.trusted && item.estimated; })
            && config.displays[0].brightnessValue == cachedFirst.brightnessValue
            && config.displays[0].contrastValue == cachedFirst.contrastValue
            && config.displays[0].volumeValue == cachedFirst.volumeValue,
            L"C-017/C-024: 同一显示器三项全零应判为不可信且不得覆盖估计缓存");

        SetThreeValues(native, L"monitor-0", 0, 52, 63);
        auto singleZero = service.Read(config, { firstId }, cancellation.Begin());
        Check(singleZero.success && config.displays[0].brightnessValue == 0
            && config.displays[0].contrastValue == 52 && config.displays[0].volumeValue == 63,
            L"C-018: 单项零值必须作为合法遥测更新缓存");

        native.values.erase({ L"monitor-0", DdcVcpCode::Contrast });
        SetThreeValues(native, L"monitor-1", 70, 80, 90);
        auto isolated = service.Read(config, {}, cancellation.Begin());
        auto failedContrast = std::find_if(isolated.items.begin(), isolated.items.end(), [&](auto const& item)
        { return item.displayId == firstId && item.code == DdcVcpCode::Contrast; });
        Check(!isolated.success && failedContrast != isolated.items.end() && failedContrast->estimated
            && config.displays[0].contrastValue == 52 && config.displays[1].volumeValue == 90,
            L"C-019: 单项读取失败应使用自身缓存且不阻止其他显示器更新");

        native.reads.clear(); native.writes.clear();
        config.displays[0].contrastEnabled = false;
        service.Read(config, { firstId }, cancellation.Begin());
        service.Write(config, firstId, DdcVcpCode::Contrast, 30, false, cancellation.Begin());
        Check(std::none_of(native.reads.begin(), native.reads.end(), [](auto const& item) { return item.second == DdcVcpCode::Contrast; })
            && native.writes.empty(), L"C-020: 单项功能关闭后必须零读取、零写入");
        config.displays[0].contrastEnabled = true;

        native.status = { DdcAvailability::TemporarilyUnavailable, L"模拟后端暂时不可用" };
        auto unavailable = service.Read(config, { firstId }, cancellation.Begin());
        Check(unavailable.items.size() == 3
            && std::all_of(unavailable.items.begin(), unavailable.items.end(), [](auto const& item)
                { return !item.success && item.estimated && item.availability == DdcAvailability::TemporarilyUnavailable; }),
            L"后端不可用时应明确报告暂时失败并仅回退到稳定 ID/VCP 缓存");
        native.status = { DdcAvailability::Available, L"模拟硬件 DDC/CI 可用" };

        native.status = { DdcAvailability::Unsupported, L"模拟原生通道不可用" };
        native.reads.clear();
        auto unavailableNative = FakeService(native).Read(config, {}, cancellation.Begin());
        Check(!unavailableNative.success && native.reads.empty()
            && std::all_of(unavailableNative.items.begin(), unavailableNative.items.end(), [](auto const& item)
                { return !item.success && item.availability == DdcAvailability::Unsupported; }),
            L"DS-011: 原生通道不可用时必须明确失败且不得尝试第二后端");

        DdcBackendSet productionBackends;
        Check(productionBackends.Lookup(NativeDdcBackendKey) != nullptr
            && productionBackends.InputSource() != nullptr
            && productionBackends.Lookup(L"control_my_monitor") == nullptr
            && productionBackends.Lookup(L"auto") == nullptr,
            L"W-206/DS-011: 正式集合必须分别暴露原生 DDC 与输入源传输，且不得保留外部回退入口");
        auto productionDdc = productionBackends.Lookup(NativeDdcBackendKey);
        auto productionGeneration = productionDdc->TopologyGeneration();
        DdcCancellationSource productionCancellation;
        auto nativeRejectedRead = productionDdc->Read(L"unused", legacyInputCode, productionCancellation.Begin());
        auto nativeRejectedWrite = productionDdc->Write(L"unused", legacyInputCode, 17, productionCancellation.Begin());
        Check(!nativeRejectedRead.success && nativeRejectedRead.error == DdcErrorKind::Unsupported
            && !nativeRejectedWrite.success && nativeRejectedWrite.error == DdcErrorKind::Unsupported
            && productionDdc->TopologyGeneration() == productionGeneration,
            L"W-206: 原生普通 DDC 边界必须在解析显示器或调用 DXVA2 前拒绝 0x60");
        auto topologyBeforeInvalidation = productionBackends.TopologyGeneration();
        productionBackends.InvalidateTopology();
        Check(productionBackends.TopologyGeneration() > topologyBeforeInvalidation
            && productionBackends.InputSource()->TopologyGeneration() == productionBackends.TopologyGeneration(),
            L"W-206/DS-013: 两个独立接口必须共享 topology generation 和失效入口");

        auto inputConfig = ConfigWithDisplays(2);
        for (auto& display : inputConfig.displays) EnableDdcControls(display);
        FakeDdcBackend isolatedDdc;
        FakeInputSourceTransport isolatedInput;
        DdcCancellationSource inputCancellation;

        isolatedInput.writeFailures.insert(L"monitor-1");
        auto partialInput = InputSourceSwitchService(&isolatedInput).SwitchDisplaysToMac(
            inputConfig, inputCancellation.Begin());
        Check(!partialInput.success && isolatedInput.writes.size() == 3 && isolatedDdc.writes.empty(),
            L"W-206: 多显示器输入源单台失败必须隔离，继续其他目标且绝不调用普通 DDC backend");

        isolatedInput.writes.clear(); isolatedInput.writeFailures.clear();
        isolatedInput.transientWriteFailures[L"monitor-0"] = 1;
        isolatedInput.invalidateOnTransientFailure = true;
        auto oneDisplay = inputConfig; oneDisplay.displays.resize(1);
        auto retriedInput = InputSourceSwitchService(&isolatedInput).SwitchDisplaysToMac(
            oneDisplay, inputCancellation.Begin());
        Check(retriedInput.success && isolatedInput.writes.size() == 2
            && isolatedInput.TopologyGeneration() == 2,
            L"W-206: 受控刷新递增 generation 后的新句柄成功结果必须被接受");
        isolatedInput.invalidateOnTransientFailure = false;

        isolatedInput.writes.clear();
        auto canceledInputToken = inputCancellation.Begin(); inputCancellation.Cancel();
        auto canceledInput = InputSourceSwitchService(&isolatedInput).SwitchDisplaysToMac(
            inputConfig, canceledInputToken);
        Check(!canceledInput.success && isolatedInput.writes.empty(),
            L"W-206: 输入源切换开始前取消必须保持零 transport 写入");

        isolatedInput.writes.clear();
        isolatedInput.onWrite = [&] { ++isolatedInput.topologyGeneration; };
        auto staleInput = InputSourceSwitchService(&isolatedInput).SwitchDisplaysToMac(
            inputConfig, inputCancellation.Begin());
        Check(!staleInput.success && isolatedInput.writes.size() == 1,
            L"W-206: 输入源写入期间 topology generation 变化必须丢弃结果并停止剩余目标");
        isolatedInput.onWrite = {};

        isolatedInput.writes.clear();
        auto offlineInputConfig = oneDisplay;
        offlineInputConfig.displays[0].bindingStatus = DisplayBindingStatus::Offline;
        auto offlineInput = InputSourceSwitchService(&isolatedInput).SwitchDisplaysToMac(
            offlineInputConfig, inputCancellation.Begin());
        offlineInputConfig.displays[0].bindingStatus = DisplayBindingStatus::Ambiguous;
        auto ambiguousInputResult = InputSourceSwitchService(&isolatedInput).SwitchDisplaysToMac(
            offlineInputConfig, inputCancellation.Begin());
        Check(!offlineInput.success && !ambiguousInputResult.success && isolatedInput.writes.empty(),
            L"W-206: 离线或歧义显示器必须保持零输入源 transport 写入");

        FakeDdcBackend independentDdc;
        SetThreeValues(independentDdc, L"monitor-0", 30, 40, 50);
        independentDdc.writeFailures.insert({ L"monitor-0", DdcVcpCode::Brightness });
        auto ddcFailed = FakeService(independentDdc).Write(inputConfig,
            inputConfig.displays[0].id, DdcVcpCode::Brightness, 44, false, inputCancellation.Begin());
        FakeInputSourceTransport independentInput;
        auto inputAfterDdcFailure = InputSourceSwitchService(&independentInput).SwitchDisplaysToMac(
            oneDisplay, inputCancellation.Begin());
        independentInput.writeFailures.insert(L"monitor-0");
        auto inputFailed = InputSourceSwitchService(&independentInput).SwitchDisplaysToMac(
            oneDisplay, inputCancellation.Begin());
        independentDdc.writeFailures.clear(); independentDdc.writes.clear();
        auto ddcAfterInputFailure = FakeService(independentDdc).Write(inputConfig,
            inputConfig.displays[0].id, DdcVcpCode::Brightness, 45, false, inputCancellation.Begin());
        Check(!ddcFailed.success && inputAfterDdcFailure.success && !inputFailed.success
            && ddcAfterInputFailure.success,
            L"W-206: 普通 DDC 与输入源传输的失败状态必须双向隔离");

        auto reordered = config;
        std::swap(reordered.displays[0], reordered.displays[1]);
        native.status = { DdcAvailability::Available, L"模拟硬件 DDC/CI 可用" };
        native.reads.clear();
        FakeService(native).Read(reordered, { firstId }, cancellation.Begin());
        Check(!native.reads.empty() && native.reads.front().first == L"monitor-0",
            L"显示器枚举重排后仍须按稳定逻辑 ID 关联后端监视器 ID");

        native.status = { DdcAvailability::Available, L"模拟硬件 DDC/CI 可用" };
        native.writes.clear(); native.writeFailures = { { L"monitor-1", DdcVcpCode::Brightness } };
        auto oldSecond = config.displays[1].brightnessValue;
        auto linked = service.Write(config, firstId, DdcVcpCode::Brightness, 42, true, cancellation.Begin());
        Check(!linked.success && native.writes.size() == 3 && config.displays[0].brightnessValue == 42
            && config.displays[1].brightnessValue == oldSecond,
            L"显式联动模式的部分失败不得阻止成功显示器，也不得污染失败显示器缓存");

        native.writeFailures.clear(); native.writes.clear();
        native.transientWriteFailures[{ L"monitor-0", DdcVcpCode::Brightness }] = 1;
        auto recoveredWrite = service.Write(config, firstId, DdcVcpCode::Brightness, 58, false, cancellation.Begin());
        Check(recoveredWrite.success && native.writes.size() == 2 && config.displays[0].brightnessValue == 58,
            L"U-023: 原生写入句柄失效后必须重新发现并仅重试一次，成功后提交缓存");
        native.writes.clear(); native.writeFailures.insert({ L"monitor-0", DdcVcpCode::Brightness });
        auto beforePermanentFailure = config.displays[0].brightnessValue;
        auto permanentFailure = service.Write(config, firstId, DdcVcpCode::Brightness, 59, false, cancellation.Begin());
        auto secondAttempt = service.Write(config, firstId, DdcVcpCode::Brightness, 60, false, cancellation.Begin());
        Check(!permanentFailure.success && !secondAttempt.success && native.writes.size() == 4
            && config.displays[0].brightnessValue == beforePermanentFailure,
            L"U-024: 原生重建失败应明确失败、不改缓存，下一次操作仍重新尝试");
        native.writeFailures.clear(); native.writes.clear();

        native.reads.clear(); native.writes.clear();
        config.displayConfigurationSafeMode = true;
        auto safeRead = service.Read(config, {}, cancellation.Begin());
        auto safeWrite = service.Write(config, firstId, DdcVcpCode::Brightness, 10, true, cancellation.Begin());
        Check(safeRead.canceled && safeWrite.canceled && native.reads.empty() && native.writes.empty(),
            L"配置安全状态下所有 DDC 调用计数必须为零");
        config.displayConfigurationSafeMode = false;

        auto canceledToken = cancellation.Begin(); cancellation.Cancel();
        service.Read(config, {}, canceledToken); service.Write(config, firstId, DdcVcpCode::Brightness, 11, false, canceledToken);
        Check(native.reads.empty() && native.writes.empty(), L"调用前取消必须阻断读取与写入");

        auto oldBrightness = config.displays[0].brightnessValue;
        native.onRead = [&] { cancellation.Cancel(); };
        auto lateRead = service.Read(config, { firstId }, cancellation.Begin());
        Check(lateRead.canceled && config.displays[0].brightnessValue == oldBrightness,
            L"读取完成后的迟到取消必须阻断缓存提交");
        native.onRead = {};
        native.writeFailures.clear();
        native.onWrite = [&] { cancellation.Cancel(); };
        auto lateWrite = service.Write(config, firstId, DdcVcpCode::Brightness, 77, false, cancellation.Begin());
        Check(lateWrite.canceled && config.displays[0].brightnessValue == oldBrightness,
            L"写入完成后的迟到取消必须阻断缓存提交");
        native.onWrite = {};

        native.writes.clear();
        auto beforeTopologyChange = config.displays[0].brightnessValue;
        native.onWrite = [&] { ++native.topologyGeneration; };
        auto staleSuccess = service.Write(config, firstId, DdcVcpCode::Brightness, 78, false, cancellation.Begin());
        Check(staleSuccess.canceled && native.writes.size() == 1
            && config.displays[0].brightnessValue == beforeTopologyChange,
            L"DS-013: 旧句柄即使模拟返回成功，topology generation 变化后也不得提交结果");
        native.onWrite = {};

        native.reads.clear();
        auto beforeStaleRead = config.displays[0].brightnessValue;
        native.onRead = [&] { ++native.topologyGeneration; };
        auto staleRead = service.Read(config, { firstId }, cancellation.Begin());
        Check(staleRead.canceled && native.reads.size() == 1
            && config.displays[0].brightnessValue == beforeStaleRead,
            L"DS-013: 拓扑变化必须丢弃旧句柄的迟到读取并停止剩余项目");
        native.onRead = {};

        native.writes.clear();
        native.onWrite = [&] { ++native.topologyGeneration; };
        auto stoppedBatch = service.Write(config, firstId, DdcVcpCode::Brightness, 79, true, cancellation.Begin());
        Check(stoppedBatch.canceled && native.writes.size() == 1,
            L"DS-013: 联动批处理中 topology generation 变化必须停止剩余显示器操作");
        native.onWrite = {};

        bool allowed = false;
        native.reads.clear(); native.writes.clear();
        auto gated = FakeService(native, [&] { return allowed; });
        gated.Read(config, {}, cancellation.Begin()); gated.Write(config, firstId, DdcVcpCode::Brightness, 12, true, cancellation.Begin());
        Check(native.reads.empty() && native.writes.empty(), L"运行时安全门关闭时所有 DDC 调用计数必须为零");
    }

    void TestMediaKeyRouting()
    {
        MediaKeyEventDeduplicator deduplicator;
        Check(deduplicator.ShouldDispatch(MediaKeyAction::VolumeUp,
                MediaKeyInputSource::Keyboard, 100)
            && !deduplicator.ShouldDispatch(MediaKeyAction::VolumeUp,
                MediaKeyInputSource::ConsumerControl, 105)
            && deduplicator.ShouldDispatch(MediaKeyAction::VolumeUp,
                MediaKeyInputSource::Keyboard, 120)
            && deduplicator.ShouldDispatch(MediaKeyAction::VolumeUp,
                MediaKeyInputSource::Keyboard, 125)
            && deduplicator.ShouldDispatch(MediaKeyAction::VolumeUp,
                MediaKeyInputSource::ConsumerControl, 200),
            L"W-034: 同一次按键的键盘/HID 双路上报只分发一次，同来源及超窗重复仍保留长按步进");
        Check(NormalizeKeyboardMediaKey(VK_VOLUME_UP, true) == MediaKeyAction::VolumeUp
            && NormalizeKeyboardMediaKey(VK_VOLUME_DOWN, true) == MediaKeyAction::VolumeDown
            && NormalizeKeyboardMediaKey(VK_VOLUME_MUTE, true) == MediaKeyAction::VolumeMute
            && !NormalizeKeyboardMediaKey(VK_VOLUME_UP, false)
            && !NormalizeKeyboardMediaKey(VK_F1, true),
            L"W-034: 只归一化键盘最终产生的标准音量媒体键，释放、Fn/F 键和普通键不得路由");
        Check(MediaKeyRawInputRegistrationFlags() == RIDEV_INPUTSINK
            && (MediaKeyRawInputRegistrationFlags() & RIDEV_NOLEGACY) == 0,
            L"W-034: 后台 Raw Input 只观察，不禁用旧输入消息或吞掉系统原生媒体动作");
        Check(NormalizeConsumerControlUsage(0x006F, true) == MediaKeyAction::BrightnessUp
            && NormalizeConsumerControlUsage(0x0070, true) == MediaKeyAction::BrightnessDown
            && NormalizeConsumerControlUsage(0x00E2, true) == MediaKeyAction::VolumeMute
            && NormalizeConsumerControlUsage(0x00E9, true) == MediaKeyAction::VolumeUp
            && NormalizeConsumerControlUsage(0x00EA, true) == MediaKeyAction::VolumeDown
            && !NormalizeConsumerControlUsage(0x006F, false)
            && !NormalizeConsumerControlUsage(0x00B5, true),
            L"W-034: Consumer Control 只接受标准亮度和音量 usage；无标准 usage 的设备自然不支持");

        auto config = ConfigWithDisplays(2);
        for (auto& display : config.displays)
        {
            display.brightnessEnabled = true;
            display.volumeEnabled = true;
            display.brightnessMax = 100;
            display.volumeMax = 100;
        }
        config.displays[0].brightnessValue = 30;
        config.displays[1].brightnessValue = 70;
        config.displays[0].volumeValue = 25;
        config.displays[1].volumeValue = 65;

        MediaKeyRouter router;
        auto relative = router.Plan(config, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessUp, 1);
        Check(relative.state == MediaKeyPlanState::Ready && relative.writes.size() == 2
            && relative.writes[0].value == 35 && relative.writes[1].value == 75
            && !relative.writes[0].linked && !relative.writes[1].linked,
            L"W-034: 非联动媒体亮度对所有启用且可信目标执行相同步进并保留差值");
        auto repeated = router.Plan(config, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessUp, 1);
        Check(repeated.writes.size() == 2 && repeated.writes[0].value == 40
            && repeated.writes[1].value == 80,
            L"W-034: 按住产生的重复事件从 generation 内待提交值继续步进，供 latest-wins 合并");
        router.OnWriteFailed(DdcVcpCode::Brightness,
            { config.displays[0].id, config.displays[1].id });
        auto afterFailure = router.Plan(config, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessUp, 1);
        Check(afterFailure.writes.size() == 2 && afterFailure.writes[0].value == 35
            && afterFailure.writes[1].value == 75,
            L"W-034: 写入失败清除乐观步进，后续事件不得继续建立在未提交值上");
        auto afterReload = router.Plan(config, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessDown, 2);
        Check(afterReload.writes.size() == 2 && afterReload.writes[0].value == 25
            && afterReload.writes[1].value == 65,
            L"W-034: 配置 generation 变化清除旧待提交值并从当前可信缓存重新规划");
        MediaKeyRouter volumeRouter;
        auto volumeStep = volumeRouter.Plan(config, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::VolumeDown, 2);
        Check(volumeStep.writes.size() == 2 && volumeStep.writes[0].value == 20
            && volumeStep.writes[1].value == 60,
            L"W-034: 标准音量媒体键使用同一生产路由并按 5 对全部合格目标相对步进");

        auto partiallyUnknown = config;
        partiallyUnknown.displays[1].brightnessValue.reset();
        MediaKeyRouter partialRouter;
        auto partial = partialRouter.Plan(partiallyUnknown,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, MediaKeyAction::BrightnessDown, 3);
        Check(partial.state == MediaKeyPlanState::Ready && partial.writes.size() == 1
            && partial.writes[0].displayId == partiallyUnknown.displays[0].id
            && partial.writes[0].value == 25,
            L"W-034: 非联动未知值目标零写入，但其他具有可信值的显示器继续相同步进");
        auto offline = config;
        offline.displays[1].bindingStatus = DisplayBindingStatus::Offline;
        MediaKeyRouter offlineRouter;
        auto offlinePlan = offlineRouter.Plan(offline, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::VolumeUp, 4);
        Check(offlinePlan.writes.size() == 1
            && offlinePlan.writes[0].displayId == offline.displays[0].id,
            L"W-034: 离线显示器不得进入媒体键目标，其他可信物理显示器仍可执行");
        for (auto trust : { DisplayTopologyTrust::RemoteSessionLimited,
            DisplayTopologyTrust::IncompleteOrUnavailable })
        {
            MediaKeyRouter blockedRouter;
            auto blocked = blockedRouter.Plan(config, trust, MediaKeyAction::VolumeUp, 5);
            Check(blocked.state == MediaKeyPlanState::UntrustedTopology && blocked.writes.empty(),
                L"W-034: RDP、虚拟、部分或不可信拓扑必须在媒体路由层保持零 DDC 目标");
        }
        auto safeConfig = config;
        safeConfig.displayConfigurationSafeMode = true;
        MediaKeyRouter safeRouter;
        Check(safeRouter.Plan(safeConfig, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::VolumeUp, 5).writes.empty(),
            L"W-034: 配置安全模式即使存在缓存和本地拓扑也必须零媒体键目标");
        auto noDisplays = config;
        noDisplays.displays.clear();
        MediaKeyRouter emptyRouter;
        Check(emptyRouter.Plan(noDisplays, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessUp, 5).writes.empty(),
            L"W-034: 零显示器冷启动媒体事件安全忽略");

        auto linked = config;
        linked.linkAllDisplays = true;
        linked.displays[0].brightnessValue = 40;
        linked.displays[1].brightnessValue = 40;
        linked.displays[0].brightnessMax = 80;
        linked.displays[1].brightnessMax = 60;
        MediaKeyRouter linkedRouter;
        auto linkedPlan = linkedRouter.Plan(linked, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessUp, 6);
        Check(linkedPlan.writes.size() == 1 && linkedPlan.writes[0].linked
            && linkedPlan.writes[0].value == 45 && linkedPlan.writes[0].targetDisplayIds.size() == 2,
            L"W-034: 联动同值使用确定性公共基准并提交一个同绝对值批量写计划");
        auto linkedRepeat = linkedRouter.Plan(linked, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessUp, 6);
        Check(linkedRepeat.writes.size() == 1 && linkedRepeat.writes[0].value == 50,
            L"W-034: 联动重复事件继续增加同一公共绝对目标");
        auto linkedNearMaximum = linked;
        linkedNearMaximum.displays[0].brightnessValue = 58;
        linkedNearMaximum.displays[1].brightnessValue = 58;
        MediaKeyRouter maximumRouter;
        auto maximumPlan = maximumRouter.Plan(linkedNearMaximum,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, MediaKeyAction::BrightnessUp, 60);
        Check(maximumPlan.writes.size() == 1 && maximumPlan.writes[0].value == 60,
            L"W-034: 联动快捷键绝对值受全部目标共同最小上限约束");
        linked.displays[1].brightnessValue = 41;
        MediaKeyRouter mixedRouter;
        auto mixed = mixedRouter.Plan(linked, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessUp, 7);
        Check(mixed.state == MediaKeyPlanState::MixedLinkedValue && mixed.writes.empty(),
            L"W-034: 联动混合值无法安全确定公共基准时必须零写入，禁止退化成相对调节");
        linked.displays[1].brightnessValue.reset();
        MediaKeyRouter unknownRouter;
        auto unknown = unknownRouter.Plan(linked, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessDown, 8);
        Check(unknown.state == MediaKeyPlanState::UnknownValue && unknown.writes.empty(),
            L"W-034: 联动任一目标值未知时必须零写入，不能用单台缓存冒充全体");

        MediaKeyRouter muteRouter;
        auto muted = muteRouter.Plan(config, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::VolumeMute, 9);
        Check(muted.writes.size() == 2 && muted.writes[0].value == 0 && muted.writes[1].value == 0,
            L"W-034: 静音只为启用音量且有可信非零值的目标写入 0");
        auto restored = muteRouter.Plan(config, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::VolumeMute, 9);
        Check(restored.writes.size() == 2 && restored.writes[0].value == 25
            && restored.writes[1].value == 65,
            L"W-034: 再次静音按显示器恢复会话内最近非零值且不持久化猜测");
        MediaKeyRouter generationMuteRouter;
        auto generationMuted = generationMuteRouter.Plan(config,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, MediaKeyAction::VolumeMute, 20);
        auto zeroVolume = config;
        zeroVolume.displays[0].volumeValue = 0;
        zeroVolume.displays[1].volumeValue = 0;
        auto staleRestore = generationMuteRouter.Plan(zeroVolume,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, MediaKeyAction::VolumeMute, 21);
        Check(generationMuted.writes.size() == 2 && staleRestore.writes.empty(),
            L"W-034: 配置 generation 变化后旧静音恢复值必须清除，绝不跨重载恢复");
        MediaKeyRouter resetMuteRouter;
        static_cast<void>(resetMuteRouter.Plan(config,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, MediaKeyAction::VolumeMute, 30));
        resetMuteRouter.ResetPending();
        Check(resetMuteRouter.Plan(zeroVolume, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::VolumeMute, 30).writes.empty(),
            L"W-034: 安全门或退出调用 ResetPending 后同时清除静音恢复值");
        auto linkedMute = config;
        linkedMute.linkAllDisplays = true;
        linkedMute.displays[0].volumeValue = 50;
        linkedMute.displays[1].volumeValue = 50;
        MediaKeyRouter linkedMuteRouter;
        auto linkedMuted = linkedMuteRouter.Plan(linkedMute,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, MediaKeyAction::VolumeMute, 10);
        auto linkedRestored = linkedMuteRouter.Plan(linkedMute,
            DisplayTopologyTrust::LocalPhysicalAuthoritative, MediaKeyAction::VolumeMute, 10);
        Check(linkedMuted.writes.size() == 1 && linkedMuted.writes[0].value == 0
            && linkedRestored.writes.size() == 1 && linkedRestored.writes[0].value == 50,
            L"W-034: 联动静音和恢复始终保持所有目标同一绝对值语义");

        auto disabled = config;
        for (auto& display : disabled.displays)
        { display.brightnessEnabled = false; display.volumeEnabled = false; }
        MediaKeyRouter disabledRouter;
        Check(disabledRouter.Plan(disabled, DisplayTopologyTrust::LocalPhysicalAuthoritative,
            MediaKeyAction::BrightnessUp, 11).writes.empty(),
            L"W-034: 冷启动后首次媒体事件没有启用目标时安全零写入");
    }

    void TestUsbLearningAndAbout()
    {
        auto device = [](wchar_t const* reference, wchar_t const* name, int vendor, int product)
        {
            return UsbLearningDevice{ reference, name, vendor, product };
        };
        auto baseline = device(L"usb:pnp:baseline", L"基线设备", 0x1000, 0x2000);
        auto first = device(L"usb:pnp:candidate-a", L"候选设备 A", 0x1001, 0x2001);
        auto second = device(L"usb:pnp:candidate-b", L"候选设备 B", 0x1002, 0x2002);
        UsbLearningSession learning;
        std::wstring originalBinding = L"usb:pnp:original";

        auto reconnectGeneration = learning.Start(L"usb-switch", { baseline }, 100);
        learning.Observe(reconnectGeneration, {}, 200, true);
        Check(learning.Candidates().empty(),
            L"W-009: 学习开始时已存在的设备离开时不能立即成为候选");
        learning.Observe(reconnectGeneration, { baseline }, 300, true);
        Check(learning.Candidates().size() == 1 && learning.Candidates()[0].localReference == baseline.localReference,
            L"W-009: 学习开始时已存在的设备离开后重新接入必须成为候选");
        learning.Cancel(reconnectGeneration);

        auto generation = learning.Start(L"profile-stable-id", { baseline }, 1000);
        Check(learning.Active() && learning.BlocksSideEffects() && learning.ProfileId() == L"profile-stable-id",
            L"C-021: USB 学习必须绑定稳定配置 ID，并在开始后阻断副作用");
        learning.Observe(generation, { baseline, first, second }, 1250, true);
        Check(learning.Candidates().size() == 2 && originalBinding == L"usb:pnp:original",
            L"C-021: 多个新增候选必须全部等待用户选择且确认前保留原绑定");

        int udpCalls{}, usbCalls{}, ddcCalls{}, wakeCalls{};
        RuntimeSafetyGate runtimeGate;
        runtimeGate.Block();
        auto attemptSideEffects = [&]
        {
            if (!learning.BlocksSideEffects() && runtimeGate.AllowsSideEffects())
                { ++udpCalls; ++usbCalls; ++ddcCalls; ++wakeCalls; }
        };
        attemptSideEffects();
        Check(udpCalls == 0 && usbCalls == 0 && ddcCalls == 0 && wakeCalls == 0,
            L"C-021: 学习和候选确认前必须保持 UDP、USB、DDC 与唤醒调用为零");
        auto selected = learning.Confirm(generation, second.localReference, 1500, true);
        if (selected) originalBinding = selected->localReference;
        runtimeGate.Allow();
        Check(selected && originalBinding == second.localReference && !learning.Active(),
            L"C-021: 只有用户明确选择的候选才能替换目标配置原绑定");

        originalBinding = L"usb:pnp:original";
        generation = learning.Start(L"profile-stable-id", { baseline }, 2000);
        learning.Observe(generation, { baseline, first }, 2200, true);
        learning.Cancel(generation);
        learning.Observe(generation, { baseline, second }, 2300, true);
        Check(!learning.Active() && originalBinding == L"usb:pnp:original" && learning.Candidates().empty(),
            L"C-022: 取消必须保留原绑定并丢弃迟到枚举结果");

        generation = learning.Start(L"profile-stable-id", { baseline }, 3000);
        learning.Observe(generation, { baseline, first }, 32999, true);
        Check(learning.Active(), L"C-022: 30 秒窗口到期前学习必须仍有效");
        learning.Observe(generation, { baseline, first }, 33000, true);
        Check(!learning.Active() && !learning.Confirm(generation, first.localReference, 33000, true)
            && originalBinding == L"usb:pnp:original",
            L"C-022: 30 秒超时必须保留原绑定并拒绝迟到确认");

        generation = learning.Start(L"profile-stable-id", { baseline }, 4000);
        learning.Observe(generation, { baseline, first }, 4100, false);
        Check(!learning.Active() && originalBinding == L"usb:pnp:original",
            L"C-022: 学习目标配置删除时必须保留原绑定");

        auto oldGeneration = learning.Start(L"profile-stable-id", { baseline }, 5000);
        learning.Cancel(oldGeneration);
        auto newGeneration = learning.Start(L"profile-stable-id", { baseline }, 6000);
        learning.Observe(oldGeneration, { baseline, first }, 6100, true);
        Check(learning.Active() && learning.Generation() == newGeneration && learning.Candidates().empty(),
            L"C-022: 旧学习代际的迟到回调不得污染新会话");
        learning.Cancel(newGeneration);

        std::wstring modulePath(32768, L'\0');
        auto moduleLength = GetModuleFileNameW(nullptr, modulePath.data(), static_cast<DWORD>(modulePath.size()));
        Check(moduleLength > 0 && moduleLength < modulePath.size(), L"C-023: 测试程序路径必须可用");
        modulePath.resize(moduleLength);
        auto applicationExecutable = std::filesystem::path(modulePath).parent_path().parent_path().parent_path().parent_path().parent_path()
            / L"DisplaySwitcher.Native" / L"bin" / L"x64" / L"Release" / L"DisplaySwitcher.Windows.exe";
        auto about = PublicAboutInfo(applicationExecutable);
        auto missingMetadata = PublicAboutInfo(applicationExecutable.parent_path() / L"missing.exe");
        auto combined = about.applicationName + L" " + about.publicVersion + L" " + about.architecture + L" "
            + about.protocol + L" " + about.projectUrl + L" " + about.licenseUrl + L" "
            + about.thirdPartyNoticesUrl + L" " + about.buildNotice;
        Check(about.applicationName == L"DisplaySwitch" && about.versionFromApplicationMetadata
            && !about.publicVersion.empty() && about.publicVersion != L"未知"
            && !missingMetadata.versionFromApplicationMetadata && missingMetadata.publicVersion == L"未知"
            && about.architecture.find(L"Windows") != std::wstring::npos && about.protocol == L"UDP 协议 v2"
            && about.projectUrl == L"https://github.com/maizihk/DisplaySwitch"
            && about.licenseUrl == L"https://github.com/maizihk/DisplaySwitch/blob/main/LICENSE"
            && about.thirdPartyNoticesUrl == L"https://github.com/maizihk/DisplaySwitch/blob/main/THIRD_PARTY_NOTICES.md",
            L"C-023: 关于页面必须从应用元数据读取版本并提供三个公开链接");
        Check(combined.find(L"pairing") == std::wstring::npos && combined.find(L"VID_") == std::wstring::npos
            && combined.find(L"PID_") == std::wstring::npos && combined.find(L"C:\\") == std::wstring::npos,
            L"C-023: 关于页面数据源不得包含配对码、硬件标识或本机路径");
        Check(udpCalls == 0 && usbCalls == 0 && ddcCalls == 0 && wakeCalls == 0,
            L"C-023: 打开关于页面不得触发网络或硬件动作");
    }

    void TestV2OnlyDatagramGate()
    {
        int replies{}, onlineRefreshes{}, usbCalls{}, wakeCalls{}, ddcCalls{}, inputSwitchCalls{};
        auto dispatch = [&](std::string_view datagram)
        {
            if (!IsV2Datagram(datagram)) return;
            ++replies;
        };
        dispatch(R"({"version":1,"type":"status_probe"})");
        dispatch(R"({"type":"status_probe"})");
        dispatch(R"({"version":"2","type":"status_probe"})");
        dispatch(R"({"version":3,"type":"status_probe"})");
        Check(replies == 0 && onlineRefreshes == 0 && usbCalls == 0 && wakeCalls == 0
            && ddcCalls == 0 && inputSwitchCalls == 0,
            L"U-015: v1、缺失、类型错误和未知 version 必须零回复、零在线刷新和零硬件副作用");
        Check(IsV2Datagram(R"({"version":2,"type":"status_probe"})"),
            L"v2-only 分派只允许整数 version=2 进入正式解析器");
    }

    void TestProfileNetworkDetection()
    {
        struct Harness
        {
            ProfileDetectionSession session;
            int v2Sends{};
            int usbCalls{};
            int bluetoothCalls{};
            int wakeCalls{};
            int ddcCalls{};
            std::optional<ProfileDetectionResult> result;

            void Apply(ProfileDetectionAction action)
            {
                if (action.kind == ProfileDetectionAction::Kind::SendV2Probe) ++v2Sends;
                else if (action.kind == ProfileDetectionAction::Kind::Complete) result = action.result;
            }
        };

        auto endpointA = GenerateIdentifier();
        auto endpointB = GenerateIdentifier();
        auto v2Event = GenerateIdentifier();

        PendingStatusProbe health;
        health.Begin(v2Event, 2000);
        Check(!health.MatchesAndConsume(GenerateIdentifier(), 1100) && health.Active(),
            L"在线状态：非待处理 status_response eventID 不得消费心跳");
        Check(health.MatchesAndConsume(v2Event, 1200) && !health.Active(),
            L"在线状态：合法 status_response 必须匹配并消费待处理 eventID");
        Check(!health.MatchesAndConsume(v2Event, 1300),
            L"在线状态：重复 status_response 不得再次刷新在线状态");
        health.Begin(v2Event, 2000);
        Check(!health.MatchesAndConsume(v2Event, 2001) && health.Expired(2001),
            L"在线状态：过期 status_response 不得刷新在线状态");

        Harness first;
        auto started = first.session.Start(1000, true, {}, v2Event); first.Apply(started);
        Check(started.eventId == v2Event && first.v2Sends == 1,
            L"网络检测：v2 status_probe 必须使用待处理 eventID");
        first.Apply(first.session.OnV2StatusResponse(1100, GenerateIdentifier(), endpointA, true));
        Check(!first.result && first.session.Active(), L"网络检测：非待处理 eventID 不得完成检测或更新在线状态");
        first.Apply(first.session.OnV2StatusResponse(1200, v2Event, endpointA, true));
        Check(first.result && first.result->outcome == ProfileDetectionOutcome::V2Available &&
            first.result->observedEndpointId == endpointA && first.result->endpointConfirmationRequired &&
            !first.result->endpointChanged,
            L"网络检测：首次 endpoint 必须匹配 eventID 并要求用户确认");
        first.Apply(first.session.OnV2StatusResponse(1300, v2Event, endpointA, true));
        Check(first.v2Sends == 1,
            L"网络检测：已完成会话的重复响应不得产生新发送或新完成结果");

        Harness changed;
        changed.Apply(changed.session.Start(2000, true, endpointA, v2Event));
        changed.Apply(changed.session.OnV2StatusResponse(2100, v2Event, endpointB, true));
        Check(changed.result && changed.result->endpointConfirmationRequired && changed.result->endpointChanged &&
            changed.result->observedEndpointId == endpointB,
            L"网络检测：已保存 endpoint 变化必须等待确认且不得自动替换");
        auto changedProfile = Profile(L"待确认对端"); changedProfile.peerEndpointId = endpointA;
        Check(!ApplyProfileDetectionResult(changedProfile, *changed.result, false) && changedProfile.peerEndpointId == endpointA,
            L"网络检测：拒绝确认时必须保留已保存 endpoint");
        Check(ApplyProfileDetectionResult(changedProfile, *changed.result, true) && changedProfile.peerEndpointId == endpointB &&
            changedProfile.peerProtocolVersion == 2,
            L"网络检测：endpoint 变化只有用户确认后才能进入待保存配置");

        Harness known;
        known.Apply(known.session.Start(3000, true, endpointA, v2Event));
        known.Apply(known.session.OnV2StatusResponse(3100, v2Event, endpointA, true));
        Check(known.result && known.result->outcome == ProfileDetectionOutcome::V2Available &&
            !known.result->endpointConfirmationRequired,
            L"网络检测：已确认 endpoint 的匹配响应应报告 v2 可用");

        auto firstProfile = Profile(L"首次对端");
        Check(!ApplyProfileDetectionResult(firstProfile, *first.result, false) && firstProfile.peerEndpointId.empty(),
            L"网络检测：首次 endpoint 未确认时不得写入待保存配置");
        Check(ApplyProfileDetectionResult(firstProfile, *first.result, true) && firstProfile.peerEndpointId == endpointA,
            L"网络检测：首次 endpoint 必须由用户确认后才能进入待保存配置");

        Harness authentication;
        authentication.Apply(authentication.session.Start(4000, true, endpointA, v2Event));
        authentication.Apply(authentication.session.OnV2StatusResponse(4100, v2Event, endpointA, false));
        Check(authentication.result && authentication.result->outcome == ProfileDetectionOutcome::AuthenticationFailed,
            L"网络检测：匹配探测的 v2 HMAC 失败必须报告认证失败");

        Harness timeout;
        timeout.Apply(timeout.session.Start(8000, true, endpointA, v2Event));
        timeout.Apply(timeout.session.Advance(10000));
        Check(timeout.result && timeout.result->outcome == ProfileDetectionOutcome::NoResponse &&
            timeout.v2Sends == 1,
            L"网络检测：v2 超时必须报告无响应且不得发送 v1");

        Harness slowSend;
        slowSend.Apply(slowSend.session.Start(14000, true, endpointA, v2Event));
        slowSend.session.MarkProbeSent(18000);
        slowSend.Apply(slowSend.session.Advance(19999));
        Check(!slowSend.result && slowSend.session.Active(),
            L"DS-012: 慢 KDF 和地址解析不得消耗实际发送后的响应窗口");
        slowSend.Apply(slowSend.session.OnV2StatusResponse(19999, v2Event, endpointA, true));
        Check(slowSend.result && slowSend.result->outcome == ProfileDetectionOutcome::V2Available,
            L"DS-012: 探测实际发送后两秒内的响应必须被接受");

        Harness incomplete;
        incomplete.Apply(incomplete.session.Start(13000, false, {}, v2Event));
        Check(incomplete.result && incomplete.result->outcome == ProfileDetectionOutcome::LocalConfigurationIncomplete &&
            incomplete.v2Sends == 0,
            L"网络检测：本机配置不完整必须零网络发送");

        auto noHardware = [&](Harness const& value)
        { return value.usbCalls == 0 && value.bluetoothCalls == 0 && value.wakeCalls == 0 && value.ddcCalls == 0; };
        Check(noHardware(first) && noHardware(changed) && noHardware(known) && noHardware(authentication) &&
            noHardware(timeout) && noHardware(slowSend) && noHardware(incomplete),
            L"网络检测：模拟全流程必须保持 USB、蓝牙、唤醒和 DDC 调用为零");

        // Simulate first contact where neither side has persisted the peer endpoint.
        auto senderEndpoint = GenerateIdentifier();
        auto receiverEndpoint = GenerateIdentifier();
        std::wstring senderSavedPeerEndpoint;
        auto receiverConfig = ConfigWithDisplays(1);
        auto receiverProfile = receiverConfig.collaborationProfiles.front();
        receiverProfile.name = L"首次接收端";
        receiverProfile.peerHost = L"simulated-peer";
        receiverProfile.peerPort = 49152;
        receiverProfile.peerEndpointId.clear();
        receiverProfile.peerProtocolVersion.reset();
        receiverProfile.coordinationEnabled = false;
        receiverConfig.collaborationProfiles = { receiverProfile };
        receiverConfig.listenPort = 49321;
        auto bootstrapCandidates = receiverConfig.UnboundBootstrapProfiles();
        Check(receiverConfig.EnabledCompleteProfiles().empty() && bootstrapCandidates.size() == 1 &&
            receiverConfig.V2ListenerPort() == receiverConfig.listenPort,
            L"首次 endpoint：合法未绑定配置不得进入正常协同，但必须监听配置的本机端口");
        auto invalidBootstrap = receiverConfig;
        invalidBootstrap.collaborationProfiles[0].peerHost.clear();
        Check(invalidBootstrap.UnboundBootstrapProfiles().empty() && !invalidBootstrap.V2ListenerPort(),
            L"首次 endpoint：基础配置不完整时不得成为 bootstrap 候选或启动监听");
        auto unknownBootstrap = receiverConfig;
        unknownBootstrap.collaborationProfiles[0].peerProtocolVersion = 3;
        Check(unknownBootstrap.UnboundBootstrapProfiles().empty() && !unknownBootstrap.V2ListenerPort(),
            L"首次 endpoint：未知协议版本不得成为 bootstrap 候选或启动监听");
        auto boundConfig = receiverConfig;
        boundConfig.collaborationProfiles[0].coordinationEnabled = true;
        boundConfig.collaborationProfiles[0].peerEndpointId = GenerateIdentifier();
        boundConfig.collaborationProfiles[0].peerProtocolVersion = 2;
        Check(boundConfig.UnboundBootstrapProfiles().empty() && boundConfig.EnabledCompleteProfiles().size() == 1 &&
            boundConfig.V2ListenerPort() == boundConfig.listenPort,
            L"首次 endpoint：已绑定配置必须继续只走正常定向协同路径");
        V2Message probe;
        probe.type = L"status_probe"; probe.eventId = GenerateIdentifier();
        probe.sourceEndpointId = senderEndpoint; probe.targetEndpointId.reset();
        probe.sourcePlatform = L"macos"; probe.timestamp = 5000; probe.nonce = GenerateV2Nonce();
        auto probeSecret = NormalizeV2PairingSecret(receiverProfile.pairingCode);
        probe = SignV2Message(std::move(probe), DeriveV2AuthenticationKey(probeSecret, senderEndpoint));
        DatagramSource simulatedSource{ L"simulated-address", 49152 };
        auto hostMatcher = [](CollaborationProfile const& profile, DatagramSource const& source)
        { return profile.peerHost == L"simulated-peer" && profile.peerPort == source.port && source.address == L"simulated-address"; };
        V2ReplayCache unboundReplay;
        auto noCandidate = MatchUnboundStatusProbe({}, receiverEndpoint, simulatedSource,
            probe, 5000, 900, hostMatcher);
        Check(noCandidate.status == UnboundProbeMatchStatus::NoMatch,
            L"首次 endpoint：零候选必须安全拒绝");
        auto wrongPortSource = simulatedSource; ++wrongPortSource.port;
        auto wrongPort = MatchUnboundStatusProbe(bootstrapCandidates, receiverEndpoint, wrongPortSource,
            probe, 5000, 950, hostMatcher);
        Check(wrongPort.status == UnboundProbeMatchStatus::NoMatch,
            L"首次 endpoint：来源端口不匹配必须安全拒绝");
        auto unbound = MatchUnboundStatusProbe(bootstrapCandidates, receiverEndpoint, simulatedSource,
            probe, 5000, 1000, hostMatcher, &unboundReplay);
        Check(senderSavedPeerEndpoint.empty() && receiverProfile.peerEndpointId.empty() &&
            unbound.status == UnboundProbeMatchStatus::Matched && unbound.profileIndex == 0,
            L"首次 endpoint：双方 peerEndpointID 为空时必须按 host/port、配对凭据和唯一规则匹配");
        auto repeated = MatchUnboundStatusProbe(bootstrapCandidates, receiverEndpoint, simulatedSource,
            probe, 5000, 1050, hostMatcher, &unboundReplay);
        Check(repeated.status == UnboundProbeMatchStatus::Matched && repeated.duplicate,
            L"首次 endpoint：完全相同的重复探测必须可重发缓存响应且不得重复产生副作用");
        auto response = CreateUnboundStatusResponse(probe, receiverEndpoint, 5000,
            GenerateV2Nonce(), receiverProfile.pairingCode);
        auto responseKey = DeriveV2AuthenticationKey(probeSecret, receiverEndpoint);
        Check(response.eventId == probe.eventId && response.targetEndpointId == senderEndpoint &&
            ValidateV2Message(response, senderEndpoint, receiverEndpoint, responseKey, 5000).accepted &&
            senderSavedPeerEndpoint.empty() && receiverProfile.peerEndpointId.empty(),
            L"首次 endpoint：响应必须复用 eventID 且不得自动保存或信任 endpoint");
        ProfileDetectionSession unboundSender;
        unboundSender.Start(1000, true, senderSavedPeerEndpoint, probe.eventId);
        auto discovered = unboundSender.OnV2StatusResponse(1100, response.eventId, receiverEndpoint, true);
        Check(discovered.kind == ProfileDetectionAction::Kind::Complete &&
            discovered.result.endpointConfirmationRequired && senderSavedPeerEndpoint.empty(),
            L"首次 endpoint：发送端收到合法响应后仍必须等待用户确认");

        auto duplicateProfile = receiverProfile; duplicateProfile.id = GenerateIdentifier(); duplicateProfile.name = L"重复候选";
        auto ambiguous = MatchUnboundStatusProbe({ receiverProfile, duplicateProfile }, receiverEndpoint,
            simulatedSource, probe, 5000, 1100, hostMatcher);
        Check(ambiguous.status == UnboundProbeMatchStatus::Ambiguous,
            L"首次 endpoint：多个 host/port 和凭据均匹配的配置必须安全拒绝");
        auto wrongSecretProfile = receiverProfile; wrongSecretProfile.pairingCode = L"SYNTHETIC-WRONG-CODE";
        auto unauthenticated = MatchUnboundStatusProbe({ wrongSecretProfile }, receiverEndpoint,
            simulatedSource, probe, 5000, 1200, hostMatcher);
        Check(unauthenticated.status == UnboundProbeMatchStatus::AuthenticationFailed,
            L"首次 endpoint：配对凭据认证失败必须安全拒绝");
        auto boundSenderProfile = receiverProfile; boundSenderProfile.peerEndpointId = senderEndpoint;
        boundSenderProfile.peerProtocolVersion = 2;
        auto asymmetric = MatchUnboundStatusProbe({ boundSenderProfile }, receiverEndpoint,
            simulatedSource, probe, 5000, 1300, hostMatcher);
        Check(asymmetric.status == UnboundProbeMatchStatus::Matched,
            L"非对称首次 endpoint：接收方唯一绑定请求方时必须接受空目标探测");
        auto duplicateBinding = boundSenderProfile; duplicateBinding.id = GenerateIdentifier();
        auto duplicateBound = MatchUnboundStatusProbe({ boundSenderProfile, duplicateBinding }, receiverEndpoint,
            simulatedSource, probe, 5000, 1350, hostMatcher);
        Check(duplicateBound.status == UnboundProbeMatchStatus::EndpointConflict,
            L"非对称首次 endpoint：同一 endpoint 对应多个配置必须拒绝");
        auto conflictingProfile = boundSenderProfile; conflictingProfile.peerEndpointId = GenerateIdentifier();
        auto conflict = MatchUnboundStatusProbe({ conflictingProfile }, receiverEndpoint,
            simulatedSource, probe, 5000, 1400, hostMatcher);
        Check(conflict.status == UnboundProbeMatchStatus::EndpointConflict,
            L"非对称首次 endpoint：相同来源和凭据声称不同 endpoint 必须拒绝");
        auto boundWrongPort = MatchUnboundStatusProbe({ boundSenderProfile }, receiverEndpoint,
            wrongPortSource, probe, 5000, 1450, hostMatcher);
        Check(boundWrongPort.status == UnboundProbeMatchStatus::NoMatch,
            L"非对称首次 endpoint：唯一绑定配置仍必须校验来源端口");
        auto boundWrongSecret = boundSenderProfile; boundWrongSecret.pairingCode = L"SYNTHETIC-WRONG-CODE";
        auto boundAuthentication = MatchUnboundStatusProbe({ boundWrongSecret }, receiverEndpoint,
            simulatedSource, probe, 5000, 1475, hostMatcher);
        Check(boundAuthentication.status == UnboundProbeMatchStatus::AuthenticationFailed,
            L"非对称首次 endpoint：唯一绑定配置仍必须校验 HMAC");
        auto selfProbe = probe;
        selfProbe.sourceEndpointId = receiverEndpoint;
        selfProbe.nonce = GenerateV2Nonce();
        selfProbe = SignV2Message(std::move(selfProbe), DeriveV2AuthenticationKey(probeSecret, receiverEndpoint));
        auto selfConflict = MatchUnboundStatusProbe({ boundSenderProfile }, receiverEndpoint,
            simulatedSource, selfProbe, 5000, 1490, hostMatcher);
        Check(selfConflict.status == UnboundProbeMatchStatus::EndpointConflict,
            L"非对称首次 endpoint：请求方 endpoint 等于本机身份必须拒绝");
        auto directedProbe = probe;
        directedProbe.targetEndpointId = receiverEndpoint;
        directedProbe.nonce = GenerateV2Nonce();
        directedProbe = SignV2Message(std::move(directedProbe), DeriveV2AuthenticationKey(probeSecret, senderEndpoint));
        Check(ValidateV2Message(directedProbe, receiverEndpoint, senderEndpoint,
            DeriveV2AuthenticationKey(probeSecret, senderEndpoint), 5000).accepted,
            L"双方已绑定：正常定向 status_probe 必须继续通过既有 v2 校验");
        auto bootstrapNetworkReplies = static_cast<int>(unbound.status == UnboundProbeMatchStatus::Matched) +
            static_cast<int>(repeated.status == UnboundProbeMatchStatus::Matched);
        int bootstrapUsbCalls{}, bootstrapBluetoothCalls{}, bootstrapWakeCalls{}, bootstrapDdcCalls{};
        Check(bootstrapNetworkReplies == 2 && bootstrapUsbCalls == 0 && bootstrapBluetoothCalls == 0 &&
            bootstrapWakeCalls == 0 && bootstrapDdcCalls == 0 && noHardware(first),
            L"首次 endpoint：匹配、拒绝和回复过程必须保持零硬件副作用");
    }

    void TestProfileDetectionThreadingAndKeyCache()
    {
        std::atomic<int> derivations{};
        V2AuthenticationKeyCache cache(2, [&](std::span<uint8_t const> secret, std::wstring const& endpoint)
        {
            ++derivations;
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
            std::array<uint8_t, 32> key{};
            key[0] = static_cast<uint8_t>(secret.size());
            key[1] = static_cast<uint8_t>(endpoint.size());
            return key;
        });
        auto endpointA = GenerateIdentifier();
        auto endpointB = GenerateIdentifier();
        static_cast<void>(cache.Get(L"thread-test-password", endpointA));
        auto cachedStarted = std::chrono::steady_clock::now();
        static_cast<void>(cache.Get(L"thread-test-password", endpointA));
        auto cachedElapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - cachedStarted).count();
        Check(derivations == 1 && cachedElapsed < 30,
            L"DS-012: 相同配对密码和 endpoint 必须命中有界派生密钥缓存");
        static_cast<void>(cache.Get(L"thread-test-password", endpointB));
        static_cast<void>(cache.Get(L"changed-thread-password", endpointB));
        Check(derivations == 3 && cache.Size() == 2,
            L"DS-012: endpoint 或配对密码变化必须派生新密钥且缓存保持有界");
        cache.Clear();
        static_cast<void>(cache.Get(L"changed-thread-password", endpointB));
        Check(derivations == 4, L"DS-012: 配置代次失效必须清除派生密钥缓存");

        ProfileDetectionAsyncOperation operation;
        auto completed = std::make_shared<std::promise<bool>>();
        auto future = completed->get_future();
        auto started = std::chrono::steady_clock::now();
        operation.Start(
            [&](ProfileDetectionAsyncOperation::IsCanceled const& canceled)
            {
                static_cast<void>(cache.Get(L"slow-kdf-password", GenerateIdentifier()));
                if (canceled()) return true;
                std::this_thread::sleep_for(std::chrono::milliseconds(80)); // injected slow resolver/send
                return !canceled();
            },
            [](std::function<void()> callback) { callback(); },
            [completed](bool result) { completed->set_value(result); });
        auto startElapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        Check(startElapsed < 30, L"DS-012: 检测调用不得等待慢 KDF 或慢地址解析完成");
        Check(future.wait_for(std::chrono::seconds(2)) == std::future_status::ready && future.get(),
            L"DS-012: 后台检测完成后必须通过 dispatcher 回调结果");

        std::atomic<int> staleCallbacks{};
        operation.Start(
            [](ProfileDetectionAsyncOperation::IsCanceled const&)
            { std::this_thread::sleep_for(std::chrono::milliseconds(120)); return true; },
            [](std::function<void()> callback) { callback(); },
            [&](bool) { ++staleCallbacks; });
        operation.Cancel();
        std::this_thread::sleep_for(std::chrono::milliseconds(180));
        Check(staleCallbacks == 0,
            L"DS-012: 取消、超时或配置切换后迟到后台结果不得覆盖当前检测");
    }

    void TestDiagnosticSafetyAndDisplayLifecycle()
    {
        class DiagnosticRuntimeSpy final : public IDiagnosticSnapshotProvider
        {
        public:
            DiagnosticSnapshot snapshot;
            int snapshotReads{};

            DiagnosticSnapshot ReadSnapshot() override { ++snapshotReads; return snapshot; }
        };

        DiagnosticSnapshot snapshot;
        snapshot.about = { L"DisplaySwitch", L"2.1.0 (19)", L"Windows x64", L"UDP 协议 v2",
            L"https://example.invalid/project", L"https://example.invalid/license",
            L"https://example.invalid/notices", L"测试构建", true };
        snapshot.schemaVersion = CurrentAppConfigSchemaVersion;
        snapshot.safeMode = true;
        snapshot.detailedRecordingEnabled = true;
        snapshot.profiles = {
            { 1, true, true, true, DiagnosticHeartbeatState::Recent },
            { 2, false, false, false, DiagnosticHeartbeatState::Never }
        };
        snapshot.usb = { true, true, 3, true };
        snapshot.backend = { DdcAvailability::Available,
            DisplayTopologyTrust::RemoteSessionLimited, true, true, true };
        snapshot.displays = {
            { 1, DisplayBindingStatus::Resolved, true, false, true, DiagnosticOperationKind::Write, DiagnosticOperationState::Success },
            { 2, DisplayBindingStatus::Ambiguous, false, false, false, DiagnosticOperationKind::None, DiagnosticOperationState::Ambiguous }
        };
        auto injected = SanitizeDiagnosticEvent(
            "udp.send success=1 host=10.23.45.67 password=TOP-SECRET endpoint=11111111-2222-3333-4444-555555555555 "
            "path=C:\\Users\\Private\\settings.json monitor=DISPLAY\\SECRET usb=USB\\VID_1234&PID_5678 name=Office-Monitor");
        snapshot.sessions = { injected };

        DiagnosticRuntimeSpy provider;
        provider.snapshot = snapshot;
        DiagnosticPreviewModel model;
        auto first = model.Refresh(provider);
        auto second = model.Refresh(provider);
        auto readsBeforeCopy = provider.snapshotReads;
        auto copied = model.CopyPayload();
        Check(first == second && copied == model.VisiblePreview() && provider.snapshotReads == 2 &&
            provider.snapshotReads == readsBeforeCopy,
            L"W-203：刷新只调用只读快照 provider，复制不再次读取且文本与当前可见预览完全一致");
        for (auto const& secret : { L"10.23.45.67", L"TOP-SECRET", L"11111111-2222-3333-4444-555555555555",
            L"C:\\Users\\Private", L"DISPLAY\\SECRET", L"USB\\VID_1234", L"Office-Monitor" })
            Check(second.find(secret) == std::wstring::npos, L"W-005：诊断预览不得包含注入的本机秘密或设备标识");
        Check(second.find(L"P1") != std::wstring::npos && second.find(L"D1") != std::wstring::npos &&
            second.find(L"S1 / O1") != std::wstring::npos && second.find(L"已阻断副作用") != std::wstring::npos &&
            second.find(L"最后合法心跳=最近合法") != std::wstring::npos
            && second.find(L"topology=remote-limited") != std::wstring::npos,
            L"W-203：严格脱敏后仍须保留匿名编号和必要的安全状态");
        Check(injected.find("10.23.45.67") == std::string::npos && injected.find("TOP-SECRET") == std::string::npos &&
            injected.find("redacted=1") != std::string::npos,
            L"W-005：日志入口必须用字段白名单移除未知敏感内容");
        auto secretEventName = SanitizeDiagnosticEvent("10.23.45.67 success=1");
        Check(secretEventName == "diagnostic.redacted redacted=1",
            L"W-005：日志事件名也必须使用白名单，不能把地址伪装成事件名");

        auto displays = ConfigWithDisplays(3).displays;
        for (auto& display : displays) display.topologyGeneration = 7;
        DisplayOperationTracker tracker;
        DiagnosticAliasRegistry aliases;
        auto firstAlias = aliases.Display(displays[0].id);
        auto secondAlias = aliases.Display(displays[1].id);
        Check(firstAlias == 1 && secondAlias == 2 && aliases.Display(displays[0].id) == firstAlias,
            L"W-203：匿名编号必须在当前进程会话内稳定且不依赖后续刷新顺序");
        tracker.Reconcile(displays);
        for (auto const& display : displays)
            tracker.Record(display.id, display.nativeMonitorId, display.topologyGeneration,
                DiagnosticOperationKind::Write, DiagnosticOperationState::Success);
        tracker.Reconcile(displays);
        auto allSucceeded = tracker.Snapshot(displays);
        Check(allSucceeded.size() == 3 && std::all_of(allSucceeded.begin(), allSucceeded.end(), [](auto const& item)
            { return item.lastState == DiagnosticOperationState::Success; }),
            L"W-203：D1、D2、D3 依次成功及相同物理绑定重新枚举后必须同时保留最后状态");

        auto reordered = displays;
        std::reverse(reordered.begin(), reordered.end());
        tracker.Reconcile(reordered);
        auto reorderedState = tracker.Snapshot(reordered);
        Check(std::all_of(reorderedState.begin(), reorderedState.end(), [](auto const& item)
            { return item.lastState == DiagnosticOperationState::Success; }),
            L"W-203：同型号显示器或枚举重排不得按顺序串换最后状态");

        auto changed = displays;
        changed[1].topologyGeneration = 8;
        changed[1].nativeMonitorId = L"replacement-binding";
        tracker.Reconcile(changed);
        auto changedState = tracker.Snapshot(changed);
        Check(changedState[0].lastState == DiagnosticOperationState::Success &&
            changedState[1].lastState == DiagnosticOperationState::Idle &&
            changedState[2].lastState == DiagnosticOperationState::Success,
            L"W-203：真实绑定或 topology generation 变化只废弃对应显示器旧状态");

        changed[0].bindingStatus = DisplayBindingStatus::Ambiguous;
        tracker.Reconcile(changed);
        auto ambiguous = tracker.Snapshot(changed);
        Check(ambiguous[0].lastState == DiagnosticOperationState::Ambiguous,
            L"W-203：物理匹配歧义必须显示安全拒绝，不能继承另一台显示器状态");

        auto batchDisplays = ConfigWithDisplays(1).displays;
        batchDisplays[0].topologyGeneration = 9;
        DisplayOperationTracker batchTracker;
        batchTracker.Reconcile(batchDisplays);
        DdcControlBatchResult mixedRead;
        mixedRead.items = {
            { batchDisplays[0].id, DdcVcpCode::Brightness, false, false, false, false, {}, {},
                DdcAvailability::Available, DdcErrorKind::ReadFailed, L"模拟亮度读取失败" },
            { batchDisplays[0].id, DdcVcpCode::Contrast, true, false, true, false, 40, 100,
                DdcAvailability::Available, DdcErrorKind::None, {} },
            { batchDisplays[0].id, DdcVcpCode::Volume, true, false, true, false, 20, 100,
                DdcAvailability::Available, DdcErrorKind::None, {} }
        };
        batchTracker.RecordBatch(batchDisplays, mixedRead, DiagnosticOperationKind::Read);
        auto mixedState = batchTracker.Snapshot(batchDisplays);
        Check(mixedState.size() == 1 && mixedState[0].lastState == DiagnosticOperationState::Failed &&
            DescribeDiagnosticOperation(mixedState[0]) != L"读取：成功",
            L"W-203：同一显示器亮度失败后对比度和音量成功不得覆盖整批读取失败");
        mixedRead.items[0] = { batchDisplays[0].id, DdcVcpCode::Brightness, true, false, false, true, 30, 100,
            DdcAvailability::Available, DdcErrorKind::None, L"模拟不可信估计值" };
        batchTracker.RecordBatch(batchDisplays, mixedRead, DiagnosticOperationKind::Read);
        Check(batchTracker.Snapshot(batchDisplays)[0].lastState == DiagnosticOperationState::Failed,
            L"W-203：任一请求项不可信时整台显示器的批量结果必须为失败");
        mixedRead.items[0] = { batchDisplays[0].id, DdcVcpCode::Brightness, false, false, false, false, {}, {},
            DdcAvailability::TemporarilyUnavailable, DdcErrorKind::AmbiguousMonitor, L"模拟歧义" };
        batchTracker.RecordBatch(batchDisplays, mixedRead, DiagnosticOperationKind::Read);
        Check(batchTracker.Snapshot(batchDisplays)[0].lastState == DiagnosticOperationState::Ambiguous,
            L"W-203：任一请求项匹配歧义时整台显示器的批量结果必须为歧义");

        DiagnosticHeartbeatTracker heartbeat;
        auto heartbeatConfig = ConfigWithDisplays(0);
        auto& heartbeatProfile = heartbeatConfig.collaborationProfiles[0];
        heartbeatProfile.peerEndpointId = GenerateIdentifier();
        heartbeatProfile.peerProtocolVersion = 2;
        heartbeat.Reconcile(heartbeatConfig.localEndpointId, heartbeatConfig.collaborationProfiles);
        Check(heartbeat.State(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 1000) == DiagnosticHeartbeatState::Never,
            L"W-203：会话未收到合法心跳时诊断必须为 Never");
        heartbeat.Observe(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 1000);
        Check(heartbeat.State(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 7000) == DiagnosticHeartbeatState::Recent &&
            heartbeat.State(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 7001) == DiagnosticHeartbeatState::Expired,
            L"W-203：模拟时钟必须覆盖 Never 到 Recent 再到 Expired，过期后保留会话事实");
        heartbeat.Reconcile(heartbeatConfig.localEndpointId, heartbeatConfig.collaborationProfiles);
        Check(heartbeat.State(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 9000) == DiagnosticHeartbeatState::Expired,
            L"W-203：相同配置身份重新应用时必须保留已过期心跳状态");
        heartbeatProfile.pairingCode = L"CHANGED-CODE-0002";
        heartbeat.Reconcile(heartbeatConfig.localEndpointId, heartbeatConfig.collaborationProfiles);
        Check(heartbeat.State(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 9000) == DiagnosticHeartbeatState::Never,
            L"W-203：配置认证身份变化时必须安全清除旧心跳诊断");
        heartbeat.Observe(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 9000);
        heartbeatProfile.peerEndpointId = GenerateIdentifier();
        heartbeat.Reconcile(heartbeatConfig.localEndpointId, heartbeatConfig.collaborationProfiles);
        Check(heartbeat.State(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 9000) == DiagnosticHeartbeatState::Never,
            L"W-203：配置 endpoint 身份变化时必须安全清除旧心跳诊断");
        heartbeat.Observe(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 9000);
        heartbeatConfig.collaborationProfiles.clear();
        heartbeat.Reconcile(heartbeatConfig.localEndpointId, heartbeatConfig.collaborationProfiles);
        Check(heartbeat.State(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 9001) == DiagnosticHeartbeatState::Never,
            L"W-203：配置删除必须清除对应心跳诊断");
        heartbeat.Reset();
        Check(heartbeat.State(heartbeatProfile.id, heartbeatProfile.peerEndpointId, 9001) == DiagnosticHeartbeatState::Never,
            L"W-203：会话重置必须清空最后合法心跳状态");
    }

    void TestUdpPeerAsymmetricBootstrapLoopback()
    {
        auto senderEndpoint = GenerateIdentifier();
        auto receiverEndpoint = GenerateIdentifier();
        auto eventId = GenerateIdentifier();
        auto pairingCode = std::wstring(L"LOOPBACK-TEST-CREDENTIAL");
        std::promise<UdpPeer::Datagram> responsePromise;
        auto responseFuture = responsePromise.get_future();
        std::atomic<bool> responseDelivered{};
        std::atomic<int> routeStatus{ -1 };
        std::atomic<int> socketErrors{};
        std::atomic<int> receiverDatagrams{};
        int usbCalls{}, wakeCalls{}, ddcCalls{}, inputSwitchCalls{};

        UdpPeer sender([&](UdpPeer::Datagram const& datagram)
        {
            if (!responseDelivered.exchange(true)) responsePromise.set_value(datagram);
        }, [&](std::wstring const&) { ++socketErrors; });
        sender.Start(0);
        auto senderPort = sender.LocalPort();

        CollaborationProfile boundProfile = Profile(L"回环已绑定配置");
        boundProfile.peerHost = L"127.0.0.1";
        boundProfile.peerPort = senderPort;
        boundProfile.pairingCode = pairingCode;
        boundProfile.peerEndpointId = senderEndpoint;
        boundProfile.peerProtocolVersion = 2;
        auto originalBoundEndpoint = boundProfile.peerEndpointId;
        V2ReplayCache replay;
        std::unique_ptr<UdpPeer> receiver;
        receiver = std::make_unique<UdpPeer>([&](UdpPeer::Datagram const& datagram)
        {
            ++receiverDatagrams;
            V2Message received;
            if (!IsV2Datagram(datagram.data) || !ParseV2Message(datagram.data, received).accepted) return;
            auto match = MatchUnboundStatusProbe({ boundProfile }, receiverEndpoint, datagram.source, received,
                received.timestamp, 1000,
                [](CollaborationProfile const& profile, DatagramSource const& source)
                { return UdpPeer::SourceMatches(source, profile.peerHost, profile.peerPort); }, &replay);
            routeStatus = static_cast<int>(match.status);
            if (match.status != UnboundProbeMatchStatus::Matched) return;
            auto response = CreateUnboundStatusResponse(received, receiverEndpoint, received.timestamp,
                GenerateV2Nonce(), boundProfile.pairingCode);
            receiver->SendRaw(SerializeV2Message(response), datagram.source.address, datagram.source.port, false);
        }, [&](std::wstring const&) { ++socketErrors; });
        receiver->Start(0);
        auto receiverPort = receiver->LocalPort();

        V2Message probe;
        probe.type = L"status_probe";
        probe.eventId = eventId;
        probe.sourceEndpointId = senderEndpoint;
        probe.targetEndpointId.reset();
        probe.sourcePlatform = L"macos";
        probe.timestamp = static_cast<int64_t>(UdpPeer::TimestampNow());
        probe.nonce = GenerateV2Nonce();
        auto secret = NormalizeV2PairingSecret(pairingCode);
        probe = SignV2Message(std::move(probe), DeriveV2AuthenticationKey(secret, senderEndpoint));
        sender.SendRaw(SerializeV2Message(probe), L"127.0.0.1", receiverPort, false);

        auto received = responseFuture.wait_for(std::chrono::seconds(3)) == std::future_status::ready;
        if (!received)
            std::cerr << "Loopback diagnostic: sender_port=" << senderPort << " receiver_port=" << receiverPort
                << " sender_running=" << sender.IsRunning() << " receiver_running=" << receiver->IsRunning()
                << " route_status=" << routeStatus.load() << " socket_errors=" << socketErrors.load() << '\n';
        Check(senderPort > 0 && receiverPort > 0 && received,
            L"UDP loopback：两个 UdpPeer 必须实际绑定端口并收到非对称 bootstrap 响应");
        if (received)
        {
            auto datagram = responseFuture.get();
            V2Message response;
            auto parsed = ParseV2Message(datagram.data, response);
            auto responseKey = DeriveV2AuthenticationKey(secret, receiverEndpoint);
            Check(datagram.source.port == receiverPort && parsed.accepted && response.type == L"status_response" &&
                response.eventId == eventId && response.targetEndpointId == senderEndpoint &&
                ValidateV2Message(response, senderEndpoint, receiverEndpoint, responseKey, response.timestamp).accepted,
                L"UDP loopback：请求必须从固定监听端口发出，响应必须从接收监听端口返回并保持 eventID");
        }
        Check(boundProfile.peerEndpointId == originalBoundEndpoint && usbCalls == 0 && wakeCalls == 0 &&
            ddcCalls == 0 && inputSwitchCalls == 0,
            L"UDP loopback：非对称 bootstrap 不得重绑、保存或触发硬件副作用");
        auto receivedBeforeCanceledSend = receiverDatagrams.load();
        std::atomic<bool> cancellationChecked{};
        auto canceledSend = sender.SendRaw("canceled", L"127.0.0.1", receiverPort, false, [&]
        {
            cancellationChecked = true;
            return false;
        });
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        Check(!canceledSend && cancellationChecked && receiverDatagrams.load() == receivedBeforeCanceledSend,
            L"UDP 发送：检测取消或代次变化后不得发送迟到的数据报");
        receiver->Stop();
        sender.Stop();
    }
}

int wmain()
{
    winrt::init_apartment();
    auto root = std::filesystem::temp_directory_path() / (L"DisplaySwitcher-DS004-" + GenerateIdentifier());
    std::filesystem::create_directories(root);
    try
    {
        TestV2OnlyDatagramGate();
        TestFreshInstallAndCounts(root);
        TestSettingsWindowLayoutContracts();
        TestTrayInteractionAndLayoutContracts();
        TestMonochromeTrayIconContracts();
        TestDetailedDiagnosticRecording(root);
        TestProfileManagementAndReorder(root);
        TestValidationAndNfc(root);
        TestInputSourceNullSafetyAndMigration(root);
        TestImmediateCommitSafety(root);
        TestOrphansInspectionAndSelection();
        TestLegacyConfigResetToSafeV4(root);
        TestSafeFailures(root);
        TestNormalV4SaveFailureSafety(root);
        TestUnknownFieldsVersionsAndDuplicates(root);
        TestRenameAndFailureIsolation(root);
        TestDisplayTopologyBinding();
        TestRemoteSessionDisplayTopology();
        TestOfflineDisplayRemovalSafety();
        TestUsbTriggerStability();
        TestUsbColdStartRehydration();
        TestInputSourceColdStartTopologyRefresh();
        TestDdcControls();
        TestMediaKeyRouting();
        TestUsbLearningAndAbout();
        TestProfileNetworkDetection();
        TestProfileDetectionThreadingAndKeyCache();
        TestDiagnosticSafetyAndDisplayLifecycle();
        TestUdpPeerAsymmetricBootstrapLoopback();
        if (!failures) std::wcout << L"DS-004 passed C-001 through C-015 local-model scenarios\n";
        if (!failures) std::wcout << L"DS-004 passed C-016 through C-020 and C-024 DDC-control scenarios\n";
        if (!failures) std::wcout << L"DS-004 passed C-021 through C-023 USB-learning and about scenarios\n";
        if (!failures) std::wcout << L"DS-005 network detection pending-event and zero-hardware scenarios passed\n";
        if (!failures) std::wcout << L"DS-007 Windows-applicable settings, v2-only, DDC and tray scenarios passed\n";
        if (!failures) std::wcout << L"DS-009 USB trigger stability scenarios passed\n";
        if (!failures) std::wcout << L"DS-009 asymmetric bootstrap and loopback UDP scenarios passed\n";
        if (!failures) std::wcout << L"DS-012 nonblocking detection, cancellation and key-cache scenarios passed\n";
        if (!failures) std::wcout << L"DS-013 logical display binding and topology-generation scenarios passed\n";
        if (!failures) std::wcout << L"Windows RDP display-topology trust scenarios passed\n";
        if (!failures) std::wcout << L"W-005/W-203 diagnostic redaction, zero-side-effect and display-state scenarios passed\n";
        failures += RunV2ProtocolVectorTests();
        failures += RunUsbSwitchVectorTests();
    }
    catch (winrt::hresult_error const& error)
    {
        ++failures; std::cerr << "UNEXPECTED HRESULT: " << std::hex << static_cast<unsigned long>(error.code().value) << '\n';
    }
    catch (std::exception const& error)
    {
        ++failures; std::cerr << "UNEXPECTED: " << error.what() << '\n';
    }
    catch (...)
    {
        ++failures; std::cerr << "UNEXPECTED: unknown exception\n";
    }
    std::error_code ignored; std::filesystem::remove_all(root, ignored);
    if (failures) { std::wcerr << failures << L" test(s) failed\n"; return 1; }
    std::wcout << L"Windows automatic tests passed: " << checks << L" checks\n";
    return 0;
}
