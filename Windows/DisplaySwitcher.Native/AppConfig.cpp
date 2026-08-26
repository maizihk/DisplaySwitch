#include "pch.h"
#include "AppConfig.h"

using namespace winrt;
using namespace Windows::Data::Json;

namespace
{
    std::wstring String(JsonObject const& object, wchar_t const* name, std::wstring const& fallback)
    {
        return object.GetNamedString(name, fallback).c_str();
    }

    int Number(JsonObject const& object, wchar_t const* name, int fallback)
    {
        return static_cast<int>(object.GetNamedNumber(name, fallback));
    }
}

namespace DisplaySwitcher::Native
{
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
        AppConfig config;
        try
        {
            auto path = ConfigPath();
            std::ifstream stream(path, std::ios::binary);
            if (!stream) return config;
            std::string json((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
            auto object = JsonObject::Parse(to_hstring(json));
            config.coordinationEnabled = object.GetNamedBoolean(L"CoordinationEnabled", config.coordinationEnabled);
            config.usbAutomationEnabled = object.GetNamedBoolean(L"UsbAutomationEnabled", config.coordinationEnabled);
            config.peerHost = String(object, L"PeerHost", config.peerHost);
            config.port = Number(object, L"Port", config.port);
            config.pairingCode = String(object, L"PairingCode", config.pairingCode);
            config.usbVendorId = Number(object, L"UsbVendorId", config.usbVendorId);
            config.usbProductId = Number(object, L"UsbProductId", config.usbProductId);
            config.usbName = String(object, L"UsbName", config.usbName);
            config.controlMyMonitorPath = String(object, L"ControlMyMonitorPath", config.controlMyMonitorPath);
            config.redmiMonitorPath = String(object, L"RedmiMonitorPath", config.redmiMonitorPath);
            config.redmiMacInput = Number(object, L"RedmiMacInput", config.redmiMacInput);
            config.dellMonitorPath = String(object, L"DellMonitorPath", config.dellMonitorPath);
            config.dellMacInput = Number(object, L"DellMacInput", config.dellMacInput);
            config.startWithWindows = object.GetNamedBoolean(L"StartWithWindows", config.startWithWindows);
        }
        catch (...) {}
        return config;
    }

    void AppConfig::Save() const
    {
        JsonObject object;
        object.Insert(L"UsbAutomationEnabled", JsonValue::CreateBooleanValue(usbAutomationEnabled));
        object.Insert(L"CoordinationEnabled", JsonValue::CreateBooleanValue(coordinationEnabled));
        object.Insert(L"PeerHost", JsonValue::CreateStringValue(peerHost));
        object.Insert(L"Port", JsonValue::CreateNumberValue(port));
        object.Insert(L"PairingCode", JsonValue::CreateStringValue(pairingCode));
        object.Insert(L"UsbVendorId", JsonValue::CreateNumberValue(usbVendorId));
        object.Insert(L"UsbProductId", JsonValue::CreateNumberValue(usbProductId));
        object.Insert(L"UsbName", JsonValue::CreateStringValue(usbName));
        object.Insert(L"ControlMyMonitorPath", JsonValue::CreateStringValue(controlMyMonitorPath));
        object.Insert(L"RedmiMonitorPath", JsonValue::CreateStringValue(redmiMonitorPath));
        object.Insert(L"RedmiMacInput", JsonValue::CreateNumberValue(redmiMacInput));
        object.Insert(L"DellMonitorPath", JsonValue::CreateStringValue(dellMonitorPath));
        object.Insert(L"DellMacInput", JsonValue::CreateNumberValue(dellMacInput));
        object.Insert(L"StartWithWindows", JsonValue::CreateBooleanValue(startWithWindows));

        auto path = ConfigPath();
        std::filesystem::create_directories(path.parent_path());
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        if (!stream) throw std::runtime_error("cannot open settings file");
        auto text = to_string(object.Stringify());
        stream.write(text.data(), static_cast<std::streamsize>(text.size()));
        if (!stream) throw std::runtime_error("cannot save settings file");
    }
}
