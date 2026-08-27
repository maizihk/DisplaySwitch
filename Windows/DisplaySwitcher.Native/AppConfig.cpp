#include "pch.h"
#include "AppConfig.h"

using namespace winrt;
using namespace Windows::Data::Json;

namespace
{
    constexpr int CurrentConfigVersion = 2;

    std::wstring String(JsonObject const& object, wchar_t const* name, std::wstring const& fallback)
    {
        return object.GetNamedString(name, fallback).c_str();
    }

    int Number(JsonObject const& object, wchar_t const* name, int fallback)
    {
        return static_cast<int>(object.GetNamedNumber(name, fallback));
    }

    std::wstring Normalized(std::wstring value)
    {
        std::transform(value.begin(), value.end(), value.begin(), towlower);
        return value;
    }

    bool HasLegacyDisplay(JsonObject const& object, wchar_t const* path, wchar_t const* nativeId, wchar_t const* input)
    {
        return !String(object, path, {}).empty() || !String(object, nativeId, {}).empty() || Number(object, input, -1) >= 0;
    }

    DisplaySwitcher::Native::DisplayConfig ReadLegacyDisplay(
        JsonObject const& object,
        wchar_t const* name,
        wchar_t const* path,
        wchar_t const* nativeId,
        wchar_t const* input)
    {
        auto display = DisplaySwitcher::Native::CreateDisplayConfig(name);
        display.controlMonitorPath = String(object, path, {});
        display.nativeMonitorId = String(object, nativeId, {});
        display.macInput = Number(object, input, -1);
        return display;
    }

    void ValidateDisplayIds(std::vector<DisplaySwitcher::Native::DisplayConfig> const& displays)
    {
        std::set<std::wstring> ids;
        for (auto const& display : displays)
        {
            auto id = Normalized(display.id);
            if (!DisplaySwitcher::Native::IsValidDisplayId(id) || !ids.insert(id).second)
                throw std::runtime_error("invalid or duplicate display id");
        }
    }
}

namespace DisplaySwitcher::Native
{
    bool AppConfig::HasUsbDeviceConfiguration() const noexcept
    {
        return usbVendorId >= 0 && usbVendorId <= 0xFFFF && usbProductId >= 0 && usbProductId <= 0xFFFF;
    }

    bool AppConfig::HasDisplayConfiguration() const noexcept
    {
        if (displayConfigurationSafeMode || displays.empty()) return false;

        std::set<std::wstring> displayIds;
        std::set<std::wstring> hardwareIds;
        for (auto const& display : displays)
        {
            if (!IsValidDisplayId(display.id) || display.macInput < 0 || display.macInput > 0xFFFF)
                return false;
            if (!displayIds.insert(Normalized(display.id)).second) return false;

            std::wstring hardwareId;
            if (displayControlBackend == L"native_ddc") hardwareId = display.nativeMonitorId;
            else if (displayControlBackend == L"control_my_monitor") hardwareId = display.controlMonitorPath;
            else return false;
            if (hardwareId.empty() || !hardwareIds.insert(Normalized(hardwareId)).second) return false;
        }
        return displayControlBackend != L"control_my_monitor" || !controlMyMonitorPath.empty();
    }

    std::filesystem::path AppConfig::ConfigPath()
    {
        PWSTR roaming{};
        check_hresult(SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_DEFAULT, nullptr, &roaming));
        std::filesystem::path path(roaming);
        CoTaskMemFree(roaming);
        return path / L"DisplaySwitcher" / L"settings.json";
    }

    AppConfig AppConfig::Load()
    {
        return LoadFromPath(ConfigPath());
    }

    AppConfig AppConfig::LoadFromPath(std::filesystem::path const& path)
    {
        AppConfig defaults;
        std::ifstream stream(path, std::ios::binary);
        if (!stream) return defaults;

        try
        {
            std::string json((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
            stream.close();
            auto object = JsonObject::Parse(to_hstring(json));
            auto schemaVersion = Number(object, L"schemaVersion", object.HasKey(L"Displays") ? CurrentConfigVersion : 1);
            if (schemaVersion < 1 || schemaVersion > CurrentConfigVersion)
                throw std::runtime_error("unsupported settings schema");
            auto config = defaults;
            auto hasUsbAutomationSetting = object.HasKey(L"UsbAutomationEnabled");
            auto hasDisplayBackendSetting = object.HasKey(L"DisplayControlBackend");
            config.coordinationEnabled = object.GetNamedBoolean(L"CoordinationEnabled", config.coordinationEnabled);
            config.usbAutomationEnabled = object.GetNamedBoolean(L"UsbAutomationEnabled", config.usbAutomationEnabled);
            config.peerHost = String(object, L"PeerHost", config.peerHost);
            config.port = Number(object, L"Port", config.port);
            config.pairingCode = String(object, L"PairingCode", config.pairingCode);
            config.usbVendorId = Number(object, L"UsbVendorId", config.usbVendorId);
            config.usbProductId = Number(object, L"UsbProductId", config.usbProductId);
            config.usbName = String(object, L"UsbName", config.usbName);
            config.displayControlBackend = String(object, L"DisplayControlBackend", config.displayControlBackend);
            config.controlMyMonitorPath = String(object, L"ControlMyMonitorPath", config.controlMyMonitorPath);
            config.startWithWindows = object.GetNamedBoolean(L"StartWithWindows", config.startWithWindows);

            bool migrated = false;
            if (object.HasKey(L"Displays"))
            {
                for (auto const& value : object.GetNamedArray(L"Displays"))
                {
                    auto item = value.GetObject();
                    DisplayConfig display;
                    display.id = String(item, L"Id", {});
                    display.name = String(item, L"Name", {});
                    display.nativeMonitorId = String(item, L"NativeMonitorId", {});
                    display.controlMonitorPath = String(item, L"ControlMonitorPath", {});
                    display.macInput = Number(item, L"MacInput", -1);
                    config.displays.push_back(std::move(display));
                }
                ValidateDisplayIds(config.displays);
            }
            else
            {
                if (HasLegacyDisplay(object, L"RedmiMonitorPath", L"RedmiNativeMonitorId", L"RedmiMacInput"))
                    config.displays.push_back(ReadLegacyDisplay(object, L"显示器 1", L"RedmiMonitorPath", L"RedmiNativeMonitorId", L"RedmiMacInput"));
                if (HasLegacyDisplay(object, L"DellMonitorPath", L"DellNativeMonitorId", L"DellMacInput"))
                    config.displays.push_back(ReadLegacyDisplay(object, L"显示器 2", L"DellMonitorPath", L"DellNativeMonitorId", L"DellMacInput"));
                migrated = !config.displays.empty();
            }

            // The retired C# build did not persist these two fields. Migrate only a complete existing
            // configuration; a missing file or an incomplete JSON object remains safely unconfigured.
            if (!hasDisplayBackendSetting && !config.controlMyMonitorPath.empty() && config.displays.size() == 2 &&
                std::all_of(config.displays.begin(), config.displays.end(), [](auto const& display)
                {
                    return !display.controlMonitorPath.empty() && display.macInput >= 0;
                }))
                config.displayControlBackend = L"control_my_monitor";
            if (!hasUsbAutomationSetting && config.coordinationEnabled &&
                config.HasUsbDeviceConfiguration() && config.HasDisplayConfiguration())
                config.usbAutomationEnabled = true;

            if (migrated)
            {
                try { config.SaveToPath(path); }
                catch (...)
                {
                    config.displayConfigurationSafeMode = true;
                    config.usbAutomationEnabled = false;
                }
            }
            return config;
        }
        catch (...)
        {
            defaults.displayConfigurationSafeMode = true;
            defaults.usbAutomationEnabled = false;
            return defaults;
        }
    }

    void AppConfig::Save() const
    {
        SaveToPath(ConfigPath());
    }

    void AppConfig::SaveToPath(std::filesystem::path const& path) const
    {
        ValidateDisplayIds(displays);

        JsonObject object;
        object.Insert(L"schemaVersion", JsonValue::CreateNumberValue(CurrentConfigVersion));
        object.Insert(L"UsbAutomationEnabled", JsonValue::CreateBooleanValue(usbAutomationEnabled));
        object.Insert(L"CoordinationEnabled", JsonValue::CreateBooleanValue(coordinationEnabled));
        object.Insert(L"PeerHost", JsonValue::CreateStringValue(peerHost));
        object.Insert(L"Port", JsonValue::CreateNumberValue(port));
        object.Insert(L"PairingCode", JsonValue::CreateStringValue(pairingCode));
        object.Insert(L"UsbVendorId", JsonValue::CreateNumberValue(usbVendorId));
        object.Insert(L"UsbProductId", JsonValue::CreateNumberValue(usbProductId));
        object.Insert(L"UsbName", JsonValue::CreateStringValue(usbName));
        object.Insert(L"DisplayControlBackend", JsonValue::CreateStringValue(displayControlBackend));
        object.Insert(L"ControlMyMonitorPath", JsonValue::CreateStringValue(controlMyMonitorPath));
        JsonArray displayArray;
        for (auto const& display : displays)
        {
            JsonObject item;
            item.Insert(L"Id", JsonValue::CreateStringValue(display.id));
            item.Insert(L"Name", JsonValue::CreateStringValue(display.name));
            item.Insert(L"NativeMonitorId", JsonValue::CreateStringValue(display.nativeMonitorId));
            item.Insert(L"ControlMonitorPath", JsonValue::CreateStringValue(display.controlMonitorPath));
            item.Insert(L"MacInput", JsonValue::CreateNumberValue(display.macInput));
            displayArray.Append(item);
        }
        object.Insert(L"Displays", displayArray);
        object.Insert(L"StartWithWindows", JsonValue::CreateBooleanValue(startWithWindows));

        std::filesystem::create_directories(path.parent_path());
        auto temporary = path;
        temporary += L"." + CreateDisplayConfig().id + L".tmp";
        try
        {
            std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
            if (!stream) throw std::runtime_error("cannot open temporary settings file");
            auto text = to_string(object.Stringify());
            stream.write(text.data(), static_cast<std::streamsize>(text.size()));
            stream.flush();
            if (!stream) throw std::runtime_error("cannot save temporary settings file");
            stream.close();
            if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                throw winrt::hresult_error(HRESULT_FROM_WIN32(GetLastError()));
        }
        catch (...)
        {
            std::error_code ignored;
            std::filesystem::remove(temporary, ignored);
            throw;
        }
    }
}
