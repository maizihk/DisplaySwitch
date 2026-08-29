#include "../DisplaySwitcher.Native/pch.h"
#include "../DisplaySwitcher.Native/AppConfig.h"
#include "../DisplaySwitcher.Native/AboutInfo.h"
#include "../DisplaySwitcher.Native/DdcBackends.h"
#include "../DisplaySwitcher.Native/DdcControl.h"
#include "../DisplaySwitcher.Native/DisplayModel.h"
#include "../DisplaySwitcher.Native/ProfileDetection.h"
#include "../DisplaySwitcher.Native/UnboundProbeRouter.h"
#include "../DisplaySwitcher.Native/UsbLearning.h"
#include "../DisplaySwitcher.Native/UsbPresencePollPolicy.h"
#include "../DisplaySwitcher.Native/UsbSwitchCoordinator.h"
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

    struct FakeDdcBackend final : IDdcBackend
    {
        std::wstring key{ L"native_ddc" };
        DdcBackendStatus status{ DdcAvailability::Available, L"模拟硬件 DDC/CI 可用" };
        std::map<std::pair<std::wstring, DdcVcpCode>, DdcValueResult> values;
        std::set<std::pair<std::wstring, DdcVcpCode>> writeFailures;
        std::map<std::pair<std::wstring, DdcVcpCode>, int> transientWriteFailures;
        std::vector<std::pair<std::wstring, DdcVcpCode>> reads;
        std::vector<std::tuple<std::wstring, DdcVcpCode, int>> writes;
        std::function<void()> onRead;
        std::function<void()> onWrite;

        std::wstring Key() const override { return key; }
        std::wstring DisplayName() const override { return L"模拟硬件 DDC/CI"; }
        DdcBackendStatus Status() const override { return status; }
        DdcEnumerationResult Enumerate(DdcCancellationToken const&) override
        { return { true, DdcErrorKind::None, {}, {}, true }; }
        DdcCapabilities Capabilities(std::wstring const&, DdcCancellationToken const&) override
        {
            return { status, false, {}, {} };
        }
        DdcValueResult Read(std::wstring const& monitorId, DdcVcpCode code,
            DdcCancellationToken const& cancellation) override
        {
            reads.emplace_back(monitorId, code);
            if (onRead) onRead();
            if (cancellation.IsCanceled()) return { false, 0, 0, DdcErrorKind::Canceled, L"已取消" };
            auto found = values.find({ monitorId, code });
            return found == values.end() ? DdcValueResult{ false, 0, 0, DdcErrorKind::ReadFailed, L"模拟读取失败" } : found->second;
        }
        DdcWriteResult Write(std::wstring const& monitorId, DdcVcpCode code, int value,
            DdcCancellationToken const& cancellation) override
        {
            writes.emplace_back(monitorId, code, value);
            if (onWrite) onWrite();
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"已取消" };
            auto transient = transientWriteFailures.find({ monitorId, code });
            if (transient != transientWriteFailures.end() && transient->second-- > 0)
                return { false, DdcErrorKind::WriteFailed, L"模拟句柄失效" };
            if (writeFailures.contains({ monitorId, code })) return { false, DdcErrorKind::WriteFailed, L"模拟写入失败" };
            return { true, DdcErrorKind::None, {} };
        }
    };

    void EnableDdcControls(DisplayConfig& display)
    {
        display.readEnabled = true;
        display.brightnessEnabled = true;
        display.contrastEnabled = true;
        display.volumeEnabled = true;
        display.backend = L"native_ddc";
    }

    DdcControlService FakeService(FakeDdcBackend& native, FakeDdcBackend* fallback = nullptr,
        std::function<bool()> allowed = {})
    {
        auto nativeBackend = &native;
        return DdcControlService([nativeBackend, fallback](std::wstring const& key) -> IDdcBackend*
        {
            if (_wcsicmp(key.c_str(), nativeBackend->key.c_str()) == 0) return nativeBackend;
            if (fallback && _wcsicmp(key.c_str(), fallback->key.c_str()) == 0) return fallback;
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
        auto first = AppConfig::LoadFromPath(freshPath);
        auto second = AppConfig::LoadFromPath(freshPath);
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
        WriteObject(path, object);
        Check(!AppConfig::LoadFromPath(path).displayConfigurationSafeMode, L"U-006: v5 未知字段应忽略");

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

        auto reconciled = ReconcileDisplayConfigurations({ first, second }, duplicated, true);
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
            { { L"device-b", L"相同型号", L"DISPLAY9" } }, false };
        auto partial = ReconcileDisplayConfigurations(reconciled.displays, partialSnapshot.monitors,
            partialSnapshot.IsTrustedNonEmptySnapshot());
        Check(!partial.changed && partial.removed == 0 && partial.displays.size() == 2
            && preservedProfile.displayInputs.size() == 2 && preservedUsb.displayInputs.size() == 2,
            L"W-009: 部分失败的枚举必须原样保留显示器、USB 映射和协同映射");

        DdcEnumerationResult sleepingSnapshot{ true, DdcErrorKind::None, {}, {}, true };
        auto sleeping = ReconcileDisplayConfigurations(partial.displays, sleepingSnapshot.monitors,
            sleepingSnapshot.IsTrustedNonEmptySnapshot());
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
              { L"device-a", L"相同型号", L"DISPLAY1" } }, true);
        auto recoveredFirst = std::find_if(recovered.displays.begin(), recovered.displays.end(), [&](auto const& display)
            { return display.id == firstLogicalId; });
        Check(!recovered.changed && recovered.removed == 0 && recovered.displays.size() == 2
            && recoveredFirst != recovered.displays.end() && recoveredFirst->name == L"工作主屏"
            && recoveredFirst->localInput == 27 && recoveredFirst->brightnessEnabled
            && recoveredFirst->contrastEnabled && recoveredFirst->volumeEnabled,
            L"W-009: 显示器休眠恢复并重排后必须按稳定 ID 恢复原用户设置");

        auto disconnected = ReconcileDisplayConfigurations(reconciled.displays,
            { { L"device-b", L"相同型号", L"DISPLAY9" } }, true);
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
            { { L"device-a", L"另一型号", L"DISPLAY4" }, { L"device-b", L"相同型号", L"DISPLAY9" } }, true);
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

    void TestUsbTriggerStability()
    {
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
        for (int index = 0; index < UsbPresencePollPolicy::NotificationFollowupPollCount; ++index)
            pollPolicy.WaitTimedOut();
        Check(pollPolicy.FollowupPollsRemaining() == 0 && pollPolicy.NextWaitMilliseconds(true) == 2000,
            L"USB 稳定性：复查窗口结束后必须恢复低频轮询");
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

        FakeDdcBackend fallback; fallback.key = L"control_my_monitor";
        config.displayControlBackend = L"auto";
        config.controlMyMonitorPath = L"simulated-cmm.exe";
        SetThreeValues(fallback, L"path-monitor-1", 21, 22, 23);
        SetThreeValues(fallback, L"path-monitor-0", 11, 12, 13);
        native.status = { DdcAvailability::Unsupported, L"模拟原生通道不可用" };
        native.reads.clear(); fallback.reads.clear();
        auto mixed = FakeService(native, &fallback).Read(config, {}, cancellation.Begin());
        Check(!mixed.success && native.reads.empty() && fallback.reads.empty()
            && std::all_of(mixed.items.begin(), mixed.items.end(), [](auto const& item) { return !item.success; }),
            L"W-009: 原生通道不可用时必须明确失败，绝不调用 ControlMyMonitor");

        auto reordered = config;
        std::swap(reordered.displays[0], reordered.displays[1]);
        native.status = { DdcAvailability::Available, L"模拟硬件 DDC/CI 可用" };
        native.reads.clear(); fallback.reads.clear();
        FakeService(native, &fallback).Read(reordered, { firstId }, cancellation.Begin());
        Check(!native.reads.empty() && fallback.reads.empty() && native.reads.front().first == L"monitor-0",
            L"显示器枚举重排后仍须按稳定逻辑 ID 关联后端监视器 ID");

        config.displayControlBackend = L"native_ddc";
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

        bool allowed = false;
        native.reads.clear(); native.writes.clear();
        auto gated = FakeService(native, nullptr, [&] { return allowed; });
        gated.Read(config, {}, cancellation.Begin()); gated.Write(config, firstId, DdcVcpCode::Brightness, 12, true, cancellation.Begin());
        Check(native.reads.empty() && native.writes.empty(), L"运行时安全门关闭时所有 DDC 调用计数必须为零");
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

        Harness incomplete;
        incomplete.Apply(incomplete.session.Start(13000, false, {}, v2Event));
        Check(incomplete.result && incomplete.result->outcome == ProfileDetectionOutcome::LocalConfigurationIncomplete &&
            incomplete.v2Sends == 0,
            L"网络检测：本机配置不完整必须零网络发送");

        auto noHardware = [&](Harness const& value)
        { return value.usbCalls == 0 && value.bluetoothCalls == 0 && value.wakeCalls == 0 && value.ddcCalls == 0; };
        Check(noHardware(first) && noHardware(changed) && noHardware(known) && noHardware(authentication) &&
            noHardware(timeout) && noHardware(incomplete),
            L"网络检测：模拟全流程必须保持 USB、蓝牙、唤醒和 DDC 调用为零");

        // Simulate first contact where neither side has persisted the peer endpoint.
        auto senderEndpoint = GenerateIdentifier();
        auto receiverEndpoint = GenerateIdentifier();
        std::wstring senderSavedPeerEndpoint;
        auto receiverProfile = Profile(L"首次接收端", true);
        receiverProfile.peerHost = L"simulated-peer";
        receiverProfile.peerPort = 49152;
        receiverProfile.peerEndpointId.clear();
        receiverProfile.peerProtocolVersion.reset();
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
        auto unbound = MatchUnboundStatusProbe({ receiverProfile }, receiverEndpoint, simulatedSource,
            probe, 5000, 1000, hostMatcher, &unboundReplay);
        Check(senderSavedPeerEndpoint.empty() && receiverProfile.peerEndpointId.empty() &&
            unbound.status == UnboundProbeMatchStatus::Matched && unbound.profileIndex == 0,
            L"首次 endpoint：双方 peerEndpointID 为空时必须按 host/port、配对凭据和唯一规则匹配");
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
        auto conflictingProfile = receiverProfile; conflictingProfile.peerEndpointId = senderEndpoint;
        auto conflict = MatchUnboundStatusProbe({ receiverProfile, conflictingProfile }, receiverEndpoint,
            simulatedSource, probe, 5000, 1300, hostMatcher);
        Check(conflict.status == UnboundProbeMatchStatus::EndpointConflict,
            L"首次 endpoint：本机已有相同 endpoint 绑定时必须拒绝空目标探测");
        Check(noHardware(first) && first.usbCalls == 0 && first.bluetoothCalls == 0 &&
            first.wakeCalls == 0 && first.ddcCalls == 0,
            L"首次 endpoint：匹配、拒绝和回复过程必须保持零硬件副作用");
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
        TestProfileManagementAndReorder(root);
        TestValidationAndNfc(root);
        TestImmediateCommitSafety(root);
        TestOrphansInspectionAndSelection();
        TestLegacyConfigResetToSafeV4(root);
        TestSafeFailures(root);
        TestNormalV4SaveFailureSafety(root);
        TestUnknownFieldsVersionsAndDuplicates(root);
        TestRenameAndFailureIsolation(root);
        TestNativeDisplayCollection();
        TestUsbTriggerStability();
        TestDdcControls();
        TestUsbLearningAndAbout();
        TestProfileNetworkDetection();
        if (!failures) std::wcout << L"DS-004 passed C-001 through C-015 local-model scenarios\n";
        if (!failures) std::wcout << L"DS-004 passed C-016 through C-020 and C-024 DDC-control scenarios\n";
        if (!failures) std::wcout << L"DS-004 passed C-021 through C-023 USB-learning and about scenarios\n";
        if (!failures) std::wcout << L"DS-005 network detection pending-event and zero-hardware scenarios passed\n";
        if (!failures) std::wcout << L"DS-007 Windows-applicable settings, v2-only, DDC and tray scenarios passed\n";
        if (!failures) std::wcout << L"DS-009 USB trigger stability scenarios passed\n";
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
    std::wcout << L"Windows automatic tests passed\n";
    return 0;
}
