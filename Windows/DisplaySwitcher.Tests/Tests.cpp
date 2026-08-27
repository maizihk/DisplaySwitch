#include "../DisplaySwitcher.Native/pch.h"
#include "../DisplaySwitcher.Native/AppConfig.h"
#include "../DisplaySwitcher.Native/DisplayModel.h"
#include <iostream>

using namespace DisplaySwitcher::Native;

namespace
{
    int failures{};
    int checks{};

    void Check(bool condition, wchar_t const* message)
    {
        ++checks;
        if (condition) return;
        ++failures;
        std::cerr << "FAIL check " << checks << '\n';
        static_cast<void>(message);
    }

    DisplayConfig ConfiguredDisplay(std::wstring const& name, std::wstring const& monitor, int input)
    {
        auto display = CreateDisplayConfig(name);
        display.nativeMonitorId = monitor;
        display.controlMonitorPath = L"path-" + monitor;
        display.macInput = input;
        return display;
    }

    void TestArbitraryDisplayCounts(std::filesystem::path const& root)
    {
        for (size_t count : { size_t{ 0 }, size_t{ 1 }, size_t{ 2 }, size_t{ 3 }, size_t{ 4 } })
        {
            AppConfig config;
            config.displayControlBackend = L"native_ddc";
            for (size_t index = 0; index < count; ++index)
                config.displays.push_back(ConfiguredDisplay(L"显示器 " + std::to_wstring(index + 1), L"monitor-" + std::to_wstring(index), 16 + static_cast<int>(index)));
            auto path = root / (L"count-" + std::to_wstring(count) + L".json");
            config.SaveToPath(path);
            auto loaded = AppConfig::LoadFromPath(path);
            Check(loaded.displays.size() == count, L"任意数量显示器应完整保存和加载");
            Check(loaded.HasDisplayConfiguration() == (count > 0), L"空集合应保持安全，非空完整集合应可用");
        }
    }

    void TestStableUuidAndEnumerationOrder()
    {
        std::vector<DisplayConfig> displays{
            ConfiguredDisplay(L"A", L"monitor-a", 16),
            ConfiguredDisplay(L"B", L"monitor-b", 17),
            ConfiguredDisplay(L"C", L"monitor-c", 18),
        };
        auto wanted = displays[1].id;
        std::reverse(displays.begin(), displays.end());
        auto found = FindDisplayById(displays, wanted);
        Check(found && displays[*found].name == L"B", L"显示器 UUID 不应受用户排序影响");

        std::vector<DdcMonitorInfo> monitors{
            { L"hardware-c", L"C", L"DISPLAY3" },
            { L"hardware-a", L"A", L"DISPLAY1" },
            { L"hardware-b", L"B", L"DISPLAY2" },
        };
        auto hardware = FindDdcMonitorById(monitors, L"HARDWARE-B");
        Check(hardware && monitors[*hardware].displayName == L"B", L"DDC 匹配不应依赖枚举顺序或大小写");
    }

    void TestLegacyMigration(std::filesystem::path const& root)
    {
        auto path = root / L"legacy.json";
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        stream << R"({"CoordinationEnabled":false,"DisplayControlBackend":"native_ddc","RedmiNativeMonitorId":"monitor-a","RedmiMacInput":16,"DellNativeMonitorId":"monitor-b","DellMacInput":17})";
        stream.close();

        auto first = AppConfig::LoadFromPath(path);
        Check(first.displays.size() == 2, L"旧双显示器配置应迁移成两个集合项");
        Check(first.displays.size() == 2 && first.displays[0].nativeMonitorId == L"monitor-a" && first.displays[1].macInput == 17,
            L"迁移应保留旧硬件标识和输入源");
        auto firstIds = std::vector<std::wstring>{ first.displays[0].id, first.displays[1].id };
        auto second = AppConfig::LoadFromPath(path);
        Check(second.displays.size() == 2 && second.displays[0].id == firstIds[0] && second.displays[1].id == firstIds[1],
            L"迁移生成的 UUID 应持久化并在再次加载时稳定");
        std::ifstream migrated(path, std::ios::binary);
        std::string text((std::istreambuf_iterator<char>(migrated)), std::istreambuf_iterator<char>());
        Check(text.find("\"schemaVersion\":2") != std::string::npos && text.find("\"Displays\"") != std::string::npos &&
            text.find("RedmiMacInput") == std::string::npos,
            L"迁移应原子写入新集合结构并移除旧固定字段");
    }

    void TestNewAndReconnectedDisplay()
    {
        auto existing = ConfiguredDisplay(L"已有", L"stable-monitor", 16);
        auto added = CreateDisplayConfig(L"新增");
        Check(added.macInput == -1 && added.nativeMonitorId.empty() && added.controlMonitorPath.empty(),
            L"新增显示器不得继承旧显示器的输入源或硬件路径");
        Check(added.id != existing.id && IsValidDisplayId(added.id), L"新增显示器应获得独立有效 UUID");

        std::vector<DdcMonitorInfo> disconnected{ { L"another-monitor", L"另一台", L"DISPLAY1" } };
        Check(!FindDdcMonitorById(disconnected, existing.nativeMonitorId), L"移除的显示器应报告未连接");
        Check(existing.nativeMonitorId == L"stable-monitor", L"显示器移除时配置中的稳定硬件标识应保留");
        disconnected.push_back({ L"stable-monitor", L"重新接入", L"DISPLAY9" });
        auto reconnected = FindDdcMonitorById(disconnected, existing.nativeMonitorId);
        Check(reconnected && disconnected[*reconnected].displayName == L"重新接入", L"重新接入后应按稳定硬件标识恢复匹配");
    }

    void TestFailureIsolation()
    {
        std::vector<DisplayConfig> displays{
            ConfiguredDisplay(L"A", L"monitor-a", 16),
            ConfiguredDisplay(L"B", L"monitor-b", 17),
            ConfiguredDisplay(L"C", L"monitor-c", 18),
        };
        std::atomic<int> invoked{};
        auto result = ExecuteDisplayActions(displays, [&](DisplayConfig const& display)
        {
            ++invoked;
            if (display.name == L"B") return ActionResult{ false, L"模拟失败" };
            return ActionResult{ true, {} };
        });
        Check(invoked == 3, L"单台显示器失败不得阻止其他显示器执行");
        Check(!result.success && result.error.find(L"B") != std::wstring::npos, L"执行结果应汇总失败显示器");
    }

    void TestMalformedConfigurationIsSafe(std::filesystem::path const& root)
    {
        auto path = root / L"malformed.json";
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        stream << "{not-json";
        stream.close();
        auto loaded = AppConfig::LoadFromPath(path);
        Check(loaded.displayConfigurationSafeMode, L"损坏配置应进入安全状态");
        Check(!loaded.usbAutomationEnabled && !loaded.HasDisplayConfiguration(), L"损坏配置不得执行自动硬件操作");
        std::ifstream preserved(path, std::ios::binary);
        std::string text((std::istreambuf_iterator<char>(preserved)), std::istreambuf_iterator<char>());
        Check(text == "{not-json", L"迁移或解析失败时应保留原文件");
    }

    void TestMigrationWriteFailureIsSafe(std::filesystem::path const& root)
    {
        auto path = root / L"readonly-legacy.json";
        std::string legacy = R"({"UsbAutomationEnabled":true,"DisplayControlBackend":"native_ddc","RedmiNativeMonitorId":"monitor-a","RedmiMacInput":16,"DellNativeMonitorId":"monitor-b","DellMacInput":17})";
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        stream << legacy;
        stream.close();
        Check(SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_READONLY) != FALSE, L"测试应能将旧配置设为只读");
        auto loaded = AppConfig::LoadFromPath(path);
        Check(loaded.displayConfigurationSafeMode && !loaded.usbAutomationEnabled && !loaded.HasDisplayConfiguration(),
            L"旧配置迁移写入失败时应停用自动硬件操作");
        std::ifstream preserved(path, std::ios::binary);
        std::string text((std::istreambuf_iterator<char>(preserved)), std::istreambuf_iterator<char>());
        Check(text == legacy, L"旧配置迁移写入失败时应完整保留原文件");
        SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL);
    }
}

int wmain()
{
    winrt::init_apartment();
    auto root = std::filesystem::temp_directory_path() / (L"DisplaySwitcher-W002-" + CreateDisplayConfig().id);
    std::filesystem::create_directories(root);
    try
    {
        TestArbitraryDisplayCounts(root);
        TestStableUuidAndEnumerationOrder();
        TestLegacyMigration(root);
        TestNewAndReconnectedDisplay();
        TestFailureIsolation();
        TestMalformedConfigurationIsSafe(root);
        TestMigrationWriteFailureIsSafe(root);
    }
    catch (std::exception const& error)
    {
        ++failures;
        std::cerr << "UNEXPECTED: " << error.what() << '\n';
    }
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
    if (failures)
    {
        std::wcerr << failures << L" test(s) failed\n";
        return 1;
    }
    std::wcout << L"W-002 tests passed\n";
    return 0;
}
