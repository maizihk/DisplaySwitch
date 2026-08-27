#include "../DisplaySwitcher.Native/pch.h"
#include "../DisplaySwitcher.Native/AppConfig.h"
#include "../DisplaySwitcher.Native/DisplayModel.h"
#include <iostream>

using namespace DisplaySwitcher::Native;
using namespace winrt::Windows::Data::Json;

int RunStateMachineVectorTests();

namespace
{
    int failures{};
    int checks{};

    void Check(bool condition, wchar_t const* message)
    {
        ++checks;
        if (condition) return;
        ++failures;
        std::wcerr << L"FAIL check " << checks << L": " << message << L'\n';
    }

    DisplayConfig Display(std::wstring const& name, std::wstring const& monitor, int peerInput)
    {
        auto display = CreateDisplayConfig(name);
        display.nativeMonitorId = monitor;
        display.controlMonitorPath = L"path-" + monitor;
        display.macInput = peerInput;
        display.localInput.reset();
        display.readEnabled = true;
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
        config.displayControlBackend = L"native_ddc";
        for (size_t index = 0; index < count; ++index)
            config.displays.push_back(Display(L"显示器 " + std::to_wstring(index + 1), L"monitor-" + std::to_wstring(index), 16 + static_cast<int>(index)));
        auto profile = Profile(L"工作电脑");
        for (auto const& display : config.displays) profile.displayInputs.push_back({ display.id, display.macInput });
        config.collaborationProfiles.push_back(std::move(profile));
        return config;
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
        auto first = AppConfig::LoadFromPath(freshPath);
        auto second = AppConfig::LoadFromPath(freshPath);
        Check(IsValidDisplayId(first.localEndpointId) && first.localEndpointId == second.localEndpointId,
            L"C-001: localEndpointID 应随机生成、持久保存且重启稳定");
        Check(first.collaborationProfiles.size() == 1 && first.collaborationProfiles[0].name == L"配置 1"
            && !first.collaborationProfiles[0].coordinationEnabled, L"C-001: 全新安装应只有一个关闭的空配置");
        Check(first.displays.empty() && !first.HasUsbDeviceConfiguration() && !first.HasDisplayConfiguration(),
            L"C-001: 全新安装不得具备硬件动作条件");

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

    void TestProfileManagementAndReorder(std::filesystem::path const& root)
    {
        auto config = ConfigWithDisplays(3);
        auto originalId = config.collaborationProfiles[0].id;
        auto second = Profile(L"游戏主机", true);
        auto third = Profile(L"备用电脑", true);
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
        Check(loaded.ReadonlyEnabledProfiles().size() == 2 && !loaded.coordinationEnabled,
            L"C-006: 多个配置可同时开启，但 v1 兼容桥不得选择列表第一项");
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

    void TestWindowsV2Migration(std::filesystem::path const& root)
    {
        auto path = root / L"v2.json";
        auto id1 = GenerateIdentifier(); auto id2 = GenerateIdentifier();
        auto text = std::string("{\"schemaVersion\":2,\"CoordinationEnabled\":true,\"PeerHost\":\"peer.example\",\"Port\":49731,\"UsbVendorId\":4660,\"UsbProductId\":22136,\"UsbName\":\"Test USB\",")
            + "\"PairingCode\":\"TEST-CODE-0001\",\"DisplayControlBackend\":\"native_ddc\",\"Displays\":["
            + "{\"Id\":\"" + winrt::to_string(id1) + "\",\"Name\":\"A\",\"NativeMonitorId\":\"monitor-a\",\"ControlMonitorPath\":\"\",\"MacInput\":16},"
            + "{\"Id\":\"" + winrt::to_string(id2) + "\",\"Name\":\"B\",\"NativeMonitorId\":\"monitor-b\",\"ControlMonitorPath\":\"\",\"MacInput\":17}]}";
        WriteBytes(path, text);
        auto migrated = AppConfig::LoadFromPath(path);
        Check(migrated.displays.size() == 2 && !migrated.displays[0].localInput && !migrated.displays[1].localInput,
            L"C-009: Windows v2 迁移时 localInput 必须保持 null");
        Check(migrated.collaborationProfiles.size() == 1 && migrated.collaborationProfiles[0].name == L"Mac"
            && migrated.PeerInputForDisplay(migrated.collaborationProfiles[0].id, id2) == 17,
            L"C-009: MacInput 应迁移到旧对端配置映射");
        Check(migrated.collaborationProfiles[0].triggerDevices.size() == 1
            && migrated.collaborationProfiles[0].triggerDevices[0].kind == L"usb",
            L"C-009: 旧 USB 触发设置应迁移为配置内本机引用");
        Check(std::filesystem::exists(path.wstring() + L".v2.backup") && ReadBytes(path.wstring() + L".v2.backup") == text,
            L"C-009: 迁移应保留原 v2 文件备份");
        auto endpoint = migrated.localEndpointId;
        Check(AppConfig::LoadFromPath(path).localEndpointId == endpoint, L"迁移生成的 endpointID 应持久稳定");
    }

    void TestSafeFailures(std::filesystem::path const& root)
    {
        auto malformedPath = root / L"malformed.json";
        WriteBytes(malformedPath, "{not-json");
        auto malformed = AppConfig::LoadFromPath(malformedPath);
        auto restarted = AppConfig::LoadFromPath(malformedPath);
        Check(malformed.displayConfigurationSafeMode && restarted.displayConfigurationSafeMode
            && !malformed.usbAutomationEnabled && !malformed.coordinationEnabled,
            L"C-010: 读取失败后应跨重启保持安全状态");
        Check(ReadBytes(malformedPath) == "{not-json", L"C-010: 读取失败不得覆盖原数据");

        auto readOnlyPath = root / L"readonly-v2.json";
        auto id = GenerateIdentifier();
        auto legacy = std::string("{\"schemaVersion\":2,\"UsbAutomationEnabled\":true,\"DisplayControlBackend\":\"native_ddc\",\"Displays\":[{\"Id\":\"")
            + winrt::to_string(id) + "\",\"Name\":\"A\",\"NativeMonitorId\":\"monitor-a\",\"ControlMonitorPath\":\"\",\"MacInput\":16}]}";
        WriteBytes(readOnlyPath, legacy);
        Check(SetFileAttributesW(readOnlyPath.c_str(), FILE_ATTRIBUTE_READONLY) != FALSE, L"测试夹具应能设为只读");
        auto failed = AppConfig::LoadFromPath(readOnlyPath);
        Check(failed.displayConfigurationSafeMode && !failed.HasDisplayConfiguration() && ReadBytes(readOnlyPath) == legacy,
            L"C-010: 迁移写入失败应保留原数据并阻断硬件/网络条件");
        Check(AppConfig::LoadFromPath(readOnlyPath).displayConfigurationSafeMode,
            L"C-010: 迁移失败安全状态应跨重启持续");
        SetFileAttributesW(readOnlyPath.c_str(), FILE_ATTRIBUTE_NORMAL);
    }

    void TestUnknownFieldsVersionsAndDuplicates(std::filesystem::path const& root)
    {
        auto path = root / L"strict.json";
        auto config = ConfigWithDisplays(1); config.SaveToPath(path);
        auto object = ReadObject(path);
        object.Insert(L"FutureField", JsonValue::CreateStringValue(L"ignored"));
        WriteObject(path, object);
        Check(!AppConfig::LoadFromPath(path).displayConfigurationSafeMode, L"C-011: v3 未知字段应忽略");

        object = ReadObject(path); object.Insert(L"schemaVersion", JsonValue::CreateNumberValue(99)); WriteObject(path, object);
        Check(AppConfig::LoadFromPath(path).displayConfigurationSafeMode, L"C-012: 未知 schemaVersion 应安全拒绝");

        auto duplicatePath = root / L"duplicate.json"; config.SaveToPath(duplicatePath);
        object = ReadObject(duplicatePath); auto profiles = object.GetNamedArray(L"CollaborationProfiles"); profiles.Append(profiles.GetAt(0));
        WriteObject(duplicatePath, object);
        Check(AppConfig::LoadFromPath(duplicatePath).displayConfigurationSafeMode, L"C-012: 重复 UUID 应安全拒绝");

        auto fractionalPath = root / L"fractional.json"; config.SaveToPath(fractionalPath);
        object = ReadObject(fractionalPath); object.Insert(L"ListenPort", JsonValue::CreateNumberValue(49731.5)); WriteObject(fractionalPath, object);
        Check(AppConfig::LoadFromPath(fractionalPath).displayConfigurationSafeMode, L"非法数值范围或非整数应安全拒绝");
    }

    void TestRenameAndFailureIsolation(std::filesystem::path const& root)
    {
        auto config = ConfigWithDisplays(3);
        auto id = config.collaborationProfiles[0].id;
        auto mappedId = config.displays[1].id;
        config.collaborationProfiles[0].coordinationEnabled = true;
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
}

int wmain()
{
    winrt::init_apartment();
    auto root = std::filesystem::temp_directory_path() / (L"DisplaySwitcher-DS004-" + GenerateIdentifier());
    std::filesystem::create_directories(root);
    try
    {
        TestFreshInstallAndCounts(root);
        TestProfileManagementAndReorder(root);
        TestValidationAndNfc(root);
        TestOrphansInspectionAndSelection();
        TestWindowsV2Migration(root);
        TestSafeFailures(root);
        TestUnknownFieldsVersionsAndDuplicates(root);
        TestRenameAndFailureIsolation(root);
        if (!failures) std::wcout << L"DS-004 passed C-001 through C-015 local-model scenarios\n";
        failures += RunStateMachineVectorTests();
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
    std::wcout << L"Windows automatic tests passed\n";
    return 0;
}
