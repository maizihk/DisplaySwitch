#include "pch.h"
#include "AppConfig.h"

#include <algorithm>
#include <limits>

#pragma comment(lib, "Normaliz.lib")

using namespace winrt;
using namespace Windows::Data::Json;

namespace
{
    constexpr int CurrentConfigVersion = 5;

    std::wstring Trim(std::wstring value)
    {
        auto whitespace = [](wchar_t c) { return iswspace(c) != 0; };
        value.erase(value.begin(), std::find_if_not(value.begin(), value.end(), whitespace));
        value.erase(std::find_if_not(value.rbegin(), value.rend(), whitespace).base(), value.end());
        return value;
    }

    std::wstring Lower(std::wstring value)
    {
        std::transform(value.begin(), value.end(), value.begin(), towlower);
        return value;
    }

    bool EqualInsensitive(std::wstring const& a, std::wstring const& b) noexcept
    {
        return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
    }

    bool VisibleText(std::wstring const& value, size_t minimum, size_t maximum)
    {
        auto text = Trim(value);
        return text.size() >= minimum && text.size() <= maximum &&
            std::none_of(text.begin(), text.end(), [](wchar_t c) { return iswcntrl(c) != 0; });
    }

    std::wstring NormalizeNfcValue(std::wstring const& value)
    {
        if (value.empty()) return {};
        auto required = NormalizeString(NormalizationC, value.c_str(), static_cast<int>(value.size()), nullptr, 0);
        if (required < 0) required = -required;
        if (required == 0) throw hresult_error(HRESULT_FROM_WIN32(GetLastError()));
        std::wstring result(static_cast<size_t>(required + 4), L'\0');
        auto written = NormalizeString(NormalizationC, value.c_str(), static_cast<int>(value.size()), result.data(), static_cast<int>(result.size()));
        if (written <= 0)
            throw hresult_error(HRESULT_FROM_WIN32(GetLastError()));
        result.resize(static_cast<size_t>(written));
        return result;
    }

    int Utf8Bytes(std::wstring const& value)
    {
        if (value.empty()) return 0;
        auto result = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.c_str(), static_cast<int>(value.size()),
            nullptr, 0, nullptr, nullptr);
        if (result <= 0) throw std::runtime_error("invalid unicode");
        return result;
    }

    bool ValidPairing(std::wstring const& value)
    {
        if (value.empty()) return true;
        auto bytes = Utf8Bytes(NormalizeNfcValue(value));
        return bytes >= 8 && bytes <= 128;
    }

    JsonValueType Type(JsonObject const& object, wchar_t const* name) { return object.GetNamedValue(name).ValueType(); }

    std::wstring RequiredString(JsonObject const& object, wchar_t const* name)
    {
        if (!object.HasKey(name) || Type(object, name) != JsonValueType::String) throw std::runtime_error("invalid string");
        return object.GetNamedString(name).c_str();
    }

    std::wstring OptionalString(JsonObject const& object, wchar_t const* name, std::wstring const& fallback = {})
    {
        if (!object.HasKey(name)) return fallback;
        if (Type(object, name) != JsonValueType::String) throw std::runtime_error("invalid string");
        return object.GetNamedString(name).c_str();
    }

    int CheckedInteger(double value, int minimum, int maximum)
    {
        if (!std::isfinite(value) || std::floor(value) != value || value < minimum || value > maximum)
            throw std::runtime_error("invalid integer");
        return static_cast<int>(value);
    }

    int RequiredInteger(JsonObject const& object, wchar_t const* name, int minimum, int maximum)
    {
        if (!object.HasKey(name) || Type(object, name) != JsonValueType::Number) throw std::runtime_error("invalid integer");
        return CheckedInteger(object.GetNamedNumber(name), minimum, maximum);
    }

    int OptionalInteger(JsonObject const& object, wchar_t const* name, int fallback, int minimum, int maximum)
    {
        return object.HasKey(name) ? RequiredInteger(object, name, minimum, maximum) : fallback;
    }

    std::optional<int> NullableInteger(JsonObject const& object, wchar_t const* name, int minimum, int maximum, bool required)
    {
        if (!object.HasKey(name))
        {
            if (required) throw std::runtime_error("missing nullable integer");
            return std::nullopt;
        }
        if (Type(object, name) == JsonValueType::Null) return std::nullopt;
        return RequiredInteger(object, name, minimum, maximum);
    }

    bool RequiredBoolean(JsonObject const& object, wchar_t const* name)
    {
        if (!object.HasKey(name) || Type(object, name) != JsonValueType::Boolean) throw std::runtime_error("invalid boolean");
        return object.GetNamedBoolean(name);
    }

    bool OptionalBoolean(JsonObject const& object, wchar_t const* name, bool fallback)
    {
        if (!object.HasKey(name)) return fallback;
        return RequiredBoolean(object, name);
    }

    JsonArray RequiredArray(JsonObject const& object, wchar_t const* name)
    {
        if (!object.HasKey(name) || Type(object, name) != JsonValueType::Array) throw std::runtime_error("invalid array");
        return object.GetNamedArray(name);
    }

    int SchemaVersion(JsonObject const& object)
    {
        if (object.HasKey(L"schemaVersion")) return RequiredInteger(object, L"schemaVersion", 1, INT_MAX);
        if (object.HasKey(L"SchemaVersion")) return RequiredInteger(object, L"SchemaVersion", 1, INT_MAX);
        return object.HasKey(L"Displays") ? 2 : 1;
    }

    std::filesystem::path MarkerPath(std::filesystem::path const& path) { auto value = path; value += L".safety"; return value; }
    std::filesystem::path BackupPath(std::filesystem::path const& path) { auto value = path; value += L".pre-v5.backup"; return value; }

    bool SetMarker(std::filesystem::path const& path) noexcept
    {
        try
        {
            std::filesystem::create_directories(path.parent_path());
            std::ofstream stream(MarkerPath(path), std::ios::binary | std::ios::trunc);
            if (!stream) return false;
            stream << "configuration_requires_user_review\n";
            stream.flush();
            return static_cast<bool>(stream);
        }
        catch (...) { return false; }
    }

    void ClearMarker(std::filesystem::path const& path)
    {
        std::error_code ignored;
        std::filesystem::remove(MarkerPath(path), ignored);
    }

    DisplaySwitcher::Native::DisplayConfig ReadV4Display(JsonObject const& object)
    {
        DisplaySwitcher::Native::DisplayConfig display;
        display.id = RequiredString(object, L"Id");
        display.name = RequiredString(object, L"Name");
        display.backend.clear();
        display.localInput.reset();
        display.readEnabled = RequiredBoolean(object, L"ReadEnabled");
        display.brightnessEnabled = RequiredBoolean(object, L"BrightnessEnabled");
        display.brightnessShowInTray = RequiredBoolean(object, L"BrightnessShowInTray");
        display.contrastEnabled = RequiredBoolean(object, L"ContrastEnabled");
        display.contrastShowInTray = RequiredBoolean(object, L"ContrastShowInTray");
        display.volumeEnabled = RequiredBoolean(object, L"VolumeEnabled");
        display.volumeShowInTray = RequiredBoolean(object, L"VolumeShowInTray");
        display.nativeMonitorId = OptionalString(object, L"NativeMonitorId");
        display.controlMonitorPath = OptionalString(object, L"ControlMonitorPath");
        display.macInput = -1;
        display.brightnessValue = NullableInteger(object, L"Brightness", 0, 65535, false);
        display.contrastValue = NullableInteger(object, L"Contrast", 0, 65535, false);
        display.volumeValue = NullableInteger(object, L"Volume", 0, 65535, false);
        display.brightnessMax = NullableInteger(object, L"BrightnessMax", 1, 65535, false);
        display.contrastMax = NullableInteger(object, L"ContrastMax", 1, 65535, false);
        display.volumeMax = NullableInteger(object, L"VolumeMax", 1, 65535, false);
        return display;
    }

    DisplaySwitcher::Native::CollaborationProfile ReadProfile(JsonObject const& object, bool readLegacyTriggers)
    {
        DisplaySwitcher::Native::CollaborationProfile profile;
        profile.id = RequiredString(object, L"Id");
        profile.name = RequiredString(object, L"Name");
        profile.peerHost = RequiredString(object, L"PeerHost");
        profile.peerPort = RequiredInteger(object, L"PeerPort", 1, 65535);
        profile.pairingCode = RequiredString(object, L"PairingCode");
        if (Type(object, L"PeerEndpointID") != JsonValueType::Null) profile.peerEndpointId = RequiredString(object, L"PeerEndpointID");
        profile.peerProtocolVersion = NullableInteger(object, L"PeerProtocolVersion", 2, 2, true);
        profile.coordinationEnabled = RequiredBoolean(object, L"CoordinationEnabled");
        for (auto const& value : RequiredArray(object, L"DisplayInputs"))
        {
            auto item = value.GetObject();
            profile.displayInputs.push_back({ RequiredString(item, L"DisplayId"), RequiredInteger(item, L"PeerInput", 0, 65535) });
        }
        if (readLegacyTriggers)
            for (auto const& value : RequiredArray(object, L"TriggerDevices"))
            {
                auto item = value.GetObject();
                profile.triggerDevices.push_back({ RequiredString(item, L"Kind"), RequiredString(item, L"LocalReference"), RequiredString(item, L"DisplayName") });
            }
        return profile;
    }

    void EnsureDefaultProfile(DisplaySwitcher::Native::AppConfig& config)
    {
        if (!config.collaborationProfiles.empty()) return;
        DisplaySwitcher::Native::CollaborationProfile profile;
        profile.id = DisplaySwitcher::Native::GenerateIdentifier();
        profile.name = L"配置 1";
        config.collaborationProfiles.push_back(std::move(profile));
    }

    void ValidateDisplays(std::vector<DisplaySwitcher::Native::DisplayConfig> const& displays)
    {
        std::set<std::wstring> ids;
        for (auto const& display : displays)
        {
            if (!DisplaySwitcher::Native::IsValidDisplayId(display.id) || !ids.insert(Lower(display.id)).second)
                throw std::runtime_error("invalid or duplicate display id");
            if (!VisibleText(display.name, 1, 64)) throw std::runtime_error("invalid display name");
            if ((!display.brightnessEnabled && display.brightnessShowInTray) ||
                (!display.contrastEnabled && display.contrastShowInTray) ||
                (!display.volumeEnabled && display.volumeShowInTray))
                throw std::runtime_error("disabled display feature cannot be shown in tray");
            if (display.localInput && (*display.localInput < 0 || *display.localInput > 65535)) throw std::runtime_error("invalid local input");
        }
    }

    void ValidateProfiles(std::vector<DisplaySwitcher::Native::CollaborationProfile> const& profiles)
    {
        if (profiles.empty()) throw std::runtime_error("profile required");
        std::set<std::wstring> ids;
        std::vector<std::wstring> names;
        for (auto const& profile : profiles)
        {
            if (!DisplaySwitcher::Native::IsValidDisplayId(profile.id) || !ids.insert(Lower(profile.id)).second)
                throw std::runtime_error("invalid or duplicate profile id");
            auto name = Trim(profile.name);
            if (!VisibleText(name, 1, 32) || std::any_of(names.begin(), names.end(), [&](auto const& existing) { return EqualInsensitive(existing, name); }))
                throw std::runtime_error("invalid or duplicate profile name");
            names.push_back(name);
            if (profile.peerHost.size() > 253 || std::any_of(profile.peerHost.begin(), profile.peerHost.end(), [](wchar_t c) { return iswcntrl(c) != 0; }))
                throw std::runtime_error("invalid peer host");
            if (profile.peerPort < 1 || profile.peerPort > 65535 || !ValidPairing(profile.pairingCode))
                throw std::runtime_error("invalid profile fields");
            if (!profile.peerEndpointId.empty() && !DisplaySwitcher::Native::IsValidDisplayId(profile.peerEndpointId))
                throw std::runtime_error("invalid peer endpoint");
            if (profile.peerProtocolVersion && *profile.peerProtocolVersion != 2)
                throw std::runtime_error("invalid peer protocol version");
            std::set<std::wstring> mappingIds;
            for (auto const& mapping : profile.displayInputs)
                if (!DisplaySwitcher::Native::IsValidDisplayId(mapping.displayId) || !mappingIds.insert(Lower(mapping.displayId)).second
                    || mapping.peerInput < 0 || mapping.peerInput > 65535)
                    throw std::runtime_error("invalid display mapping");
            for (auto const& trigger : profile.triggerDevices)
                if ((trigger.kind != L"usb" && trigger.kind != L"bluetooth") || trigger.localReference.empty())
                    throw std::runtime_error("invalid trigger device");
        }
    }

    void ValidateConfig(DisplaySwitcher::Native::AppConfig const& config)
    {
        if (!DisplaySwitcher::Native::IsValidDisplayId(config.localEndpointId) || !VisibleText(config.localDeviceName, 1, 32)
            || config.listenPort < 1 || config.listenPort > 65535) throw std::runtime_error("invalid top-level fields");
        if (config.displayControlBackend != L"auto" && config.displayControlBackend != L"native_ddc" &&
            config.displayControlBackend != L"control_my_monitor") throw std::runtime_error("invalid control channel");
        ValidateDisplays(config.displays);
        ValidateProfiles(config.collaborationProfiles);
        std::set<std::wstring> usbDisplayIds;
        bool hasUsbMapping{};
        for (auto const& mapping : config.usbSwitch.displayInputs)
        {
            if (!DisplaySwitcher::Native::IsValidDisplayId(mapping.displayId) ||
                !usbDisplayIds.insert(Lower(mapping.displayId)).second ||
                (mapping.targetInput && (*mapping.targetInput < 0 || *mapping.targetInput > 65535)))
                throw std::runtime_error("invalid usb display mapping");
            if (mapping.targetInput && DisplaySwitcher::Native::FindDisplayById(config.displays, mapping.displayId)) hasUsbMapping = true;
        }
        if (config.usbSwitch.enabled &&
            (config.usbSwitch.deviceLocalReference.empty() || config.usbSwitch.vendorId < 0 ||
             config.usbSwitch.vendorId > 65535 || config.usbSwitch.productId < 0 ||
             config.usbSwitch.productId > 65535 || !hasUsbMapping))
            throw std::runtime_error("enabled usb switch is incomplete");
        if (config.usbSwitch.collaborationWakeEnabled)
        {
            auto profile = config.FindCollaborationProfile(config.usbSwitch.collaborationProfileId);
            if (!profile || !profile->coordinationEnabled || !config.InspectProfile(profile->id).complete)
                throw std::runtime_error("invalid usb collaboration profile");
        }
        for (auto const& profile : config.collaborationProfiles)
            if (profile.coordinationEnabled && (profile.peerProtocolVersion != 2
                || !DisplaySwitcher::Native::IsValidDisplayId(profile.peerEndpointId)
                || !config.InspectProfile(profile.id).complete
                || !config.IsProfileDisplayMappingComplete(profile.id)))
                throw std::runtime_error("enabled collaboration profile is incomplete");
    }

    DisplaySwitcher::Native::AppConfig ReadCompleteV4Config(JsonObject const& object)
    {
        if (SchemaVersion(object) != 4) throw std::runtime_error("invalid settings schema");
        DisplaySwitcher::Native::AppConfig config;
        config.localEndpointId = RequiredString(object, L"LocalEndpointId");
        config.localDeviceName = RequiredString(object, L"LocalDeviceName");
        config.listenPort = RequiredInteger(object, L"ListenPort", 1, 65535);
        static_cast<void>(RequiredBoolean(object, L"UsbAutomationEnabled"));
        static_cast<void>(RequiredBoolean(object, L"UsbSwitchDisplaysOnArrival"));
        static_cast<void>(RequiredInteger(object, L"UsbVendorId", -1, 65535));
        static_cast<void>(RequiredInteger(object, L"UsbProductId", -1, 65535));
        static_cast<void>(RequiredString(object, L"UsbName"));
        config.displayControlBackend = RequiredString(object, L"ControlChannel");
        config.controlMyMonitorPath = RequiredString(object, L"ControlMyMonitorPath");
        config.linkAllDisplays = RequiredBoolean(object, L"LinkAllDisplays");
        config.startWithWindows = RequiredBoolean(object, L"StartWithWindows");
        for (auto const& value : RequiredArray(object, L"Displays")) config.displays.push_back(ReadV4Display(value.GetObject()));
        for (auto const& value : RequiredArray(object, L"CollaborationProfiles")) config.collaborationProfiles.push_back(ReadProfile(value.GetObject(), true));
        for (auto& profile : config.collaborationProfiles) profile.triggerDevices.clear();
        ValidateConfig(config);
        return config;
    }

    DisplaySwitcher::Native::AppConfig ReadCompleteV5Config(JsonObject const& object)
    {
        if (SchemaVersion(object) != CurrentConfigVersion) throw std::runtime_error("invalid settings schema");
        DisplaySwitcher::Native::AppConfig config;
        config.localEndpointId = RequiredString(object, L"LocalEndpointId");
        config.localDeviceName = RequiredString(object, L"LocalDeviceName");
        config.listenPort = RequiredInteger(object, L"ListenPort", 1, 65535);
        config.displayControlBackend = RequiredString(object, L"ControlChannel");
        config.controlMyMonitorPath = RequiredString(object, L"ControlMyMonitorPath");
        config.linkAllDisplays = RequiredBoolean(object, L"LinkAllDisplays");
        config.startWithWindows = RequiredBoolean(object, L"StartWithWindows");
        for (auto const& value : RequiredArray(object, L"Displays")) config.displays.push_back(ReadV4Display(value.GetObject()));
        for (auto const& value : RequiredArray(object, L"CollaborationProfiles")) config.collaborationProfiles.push_back(ReadProfile(value.GetObject(), false));
        auto usb = object.GetNamedObject(L"UsbSwitch");
        config.usbSwitch.enabled = RequiredBoolean(usb, L"Enabled");
        config.usbSwitch.collaborationWakeEnabled = RequiredBoolean(usb, L"CollaborationWakeEnabled");
        if (usb.GetNamedValue(L"CollaborationProfileId").ValueType() != JsonValueType::Null)
            config.usbSwitch.collaborationProfileId = RequiredString(usb, L"CollaborationProfileId");
        if (usb.GetNamedValue(L"TriggerDevice").ValueType() != JsonValueType::Null)
        {
            auto device = usb.GetNamedObject(L"TriggerDevice");
            config.usbSwitch.deviceLocalReference = RequiredString(device, L"LocalReference");
            config.usbSwitch.deviceName = RequiredString(device, L"DisplayName");
            config.usbSwitch.vendorId = RequiredInteger(device, L"VendorId", 0, 65535);
            config.usbSwitch.productId = RequiredInteger(device, L"ProductId", 0, 65535);
        }
        for (auto const& value : RequiredArray(usb, L"DisplayInputs"))
        {
            auto mapping = value.GetObject();
            config.usbSwitch.displayInputs.push_back({ RequiredString(mapping, L"DisplayId"),
                NullableInteger(mapping, L"TargetInput", 0, 65535, true) });
        }
        ValidateConfig(config);
        return config;
    }

    void EnterSafeMode(DisplaySwitcher::Native::AppConfig& config)
    {
        config.displayConfigurationSafeMode = true;
        config.usbSwitch.enabled = false;
        config.usbSwitch.collaborationWakeEnabled = false;
        for (auto& profile : config.collaborationProfiles) profile.coordinationEnabled = false;
    }

    DisplaySwitcher::Native::AppConfig NewConfig()
    {
        DisplaySwitcher::Native::AppConfig config;
        config.localEndpointId = DisplaySwitcher::Native::GenerateIdentifier();
        config.displayControlBackend = L"auto";
        config.linkAllDisplays = false;
        EnsureDefaultProfile(config);
        return config;
    }

    JsonObject Serialize(DisplaySwitcher::Native::AppConfig const& source)
    {
        auto config = source;
        if (config.localEndpointId.empty()) config.localEndpointId = DisplaySwitcher::Native::GenerateIdentifier();
        config.localDeviceName = Trim(config.localDeviceName);
        EnsureDefaultProfile(config);
        for (auto& display : config.displays)
        {
            display.name = Trim(display.name);
            display.backend.clear();
            if (!display.brightnessEnabled) display.brightnessShowInTray = false;
            if (!display.contrastEnabled) display.contrastShowInTray = false;
            if (!display.volumeEnabled) display.volumeShowInTray = false;
        }
        for (auto& profile : config.collaborationProfiles)
        {
            profile.name = Trim(profile.name); profile.peerHost = Trim(profile.peerHost);
            profile.pairingCode = NormalizeNfcValue(profile.pairingCode);
        }
        ValidateConfig(config);
        JsonObject object;
        object.Insert(L"schemaVersion", JsonValue::CreateNumberValue(CurrentConfigVersion));
        object.Insert(L"LocalEndpointId", JsonValue::CreateStringValue(config.localEndpointId));
        object.Insert(L"LocalDeviceName", JsonValue::CreateStringValue(config.localDeviceName));
        object.Insert(L"ListenPort", JsonValue::CreateNumberValue(config.listenPort));
        JsonObject usb;
        usb.Insert(L"Enabled", JsonValue::CreateBooleanValue(config.usbSwitch.enabled));
        usb.Insert(L"CollaborationWakeEnabled", JsonValue::CreateBooleanValue(config.usbSwitch.collaborationWakeEnabled));
        usb.Insert(L"CollaborationProfileId", config.usbSwitch.collaborationProfileId.empty() ? JsonValue::CreateNullValue() :
            JsonValue::CreateStringValue(config.usbSwitch.collaborationProfileId));
        if (config.usbSwitch.deviceLocalReference.empty()) usb.Insert(L"TriggerDevice", JsonValue::CreateNullValue());
        else
        {
            JsonObject device;
            device.Insert(L"LocalReference", JsonValue::CreateStringValue(config.usbSwitch.deviceLocalReference));
            device.Insert(L"DisplayName", JsonValue::CreateStringValue(config.usbSwitch.deviceName));
            device.Insert(L"VendorId", JsonValue::CreateNumberValue(config.usbSwitch.vendorId));
            device.Insert(L"ProductId", JsonValue::CreateNumberValue(config.usbSwitch.productId));
            usb.Insert(L"TriggerDevice", device);
        }
        JsonArray usbMappings;
        for (auto const& mapping : config.usbSwitch.displayInputs)
        {
            JsonObject item;
            item.Insert(L"DisplayId", JsonValue::CreateStringValue(mapping.displayId));
            item.Insert(L"TargetInput", mapping.targetInput ? JsonValue::CreateNumberValue(*mapping.targetInput) : JsonValue::CreateNullValue());
            usbMappings.Append(item);
        }
        usb.Insert(L"DisplayInputs", usbMappings);
        object.Insert(L"UsbSwitch", usb);
        object.Insert(L"ControlChannel", JsonValue::CreateStringValue(config.displayControlBackend));
        object.Insert(L"ControlMyMonitorPath", JsonValue::CreateStringValue(config.controlMyMonitorPath));
        object.Insert(L"LinkAllDisplays", JsonValue::CreateBooleanValue(config.linkAllDisplays));
        object.Insert(L"StartWithWindows", JsonValue::CreateBooleanValue(config.startWithWindows));

        JsonArray displayArray;
        for (auto const& display : config.displays)
        {
            JsonObject item;
            item.Insert(L"Id", JsonValue::CreateStringValue(display.id)); item.Insert(L"Name", JsonValue::CreateStringValue(display.name));
            item.Insert(L"ReadEnabled", JsonValue::CreateBooleanValue(display.readEnabled));
            item.Insert(L"BrightnessEnabled", JsonValue::CreateBooleanValue(display.brightnessEnabled));
            item.Insert(L"BrightnessShowInTray", JsonValue::CreateBooleanValue(display.brightnessShowInTray));
            item.Insert(L"ContrastEnabled", JsonValue::CreateBooleanValue(display.contrastEnabled));
            item.Insert(L"ContrastShowInTray", JsonValue::CreateBooleanValue(display.contrastShowInTray));
            item.Insert(L"VolumeEnabled", JsonValue::CreateBooleanValue(display.volumeEnabled));
            item.Insert(L"VolumeShowInTray", JsonValue::CreateBooleanValue(display.volumeShowInTray));
            item.Insert(L"NativeMonitorId", JsonValue::CreateStringValue(display.nativeMonitorId));
            item.Insert(L"ControlMonitorPath", JsonValue::CreateStringValue(display.controlMonitorPath));
            item.Insert(L"Brightness", display.brightnessValue ? JsonValue::CreateNumberValue(*display.brightnessValue) : JsonValue::CreateNullValue());
            item.Insert(L"Contrast", display.contrastValue ? JsonValue::CreateNumberValue(*display.contrastValue) : JsonValue::CreateNullValue());
            item.Insert(L"Volume", display.volumeValue ? JsonValue::CreateNumberValue(*display.volumeValue) : JsonValue::CreateNullValue());
            item.Insert(L"BrightnessMax", display.brightnessMax ? JsonValue::CreateNumberValue(*display.brightnessMax) : JsonValue::CreateNullValue());
            item.Insert(L"ContrastMax", display.contrastMax ? JsonValue::CreateNumberValue(*display.contrastMax) : JsonValue::CreateNullValue());
            item.Insert(L"VolumeMax", display.volumeMax ? JsonValue::CreateNumberValue(*display.volumeMax) : JsonValue::CreateNullValue());
            displayArray.Append(item);
        }
        object.Insert(L"Displays", displayArray);

        JsonArray profileArray;
        for (auto const& profile : config.collaborationProfiles)
        {
            JsonObject item;
            item.Insert(L"Id", JsonValue::CreateStringValue(profile.id)); item.Insert(L"Name", JsonValue::CreateStringValue(profile.name));
            item.Insert(L"PeerHost", JsonValue::CreateStringValue(profile.peerHost)); item.Insert(L"PeerPort", JsonValue::CreateNumberValue(profile.peerPort));
            item.Insert(L"PairingCode", JsonValue::CreateStringValue(profile.pairingCode));
            item.Insert(L"PeerEndpointID", profile.peerEndpointId.empty() ? JsonValue::CreateNullValue() : JsonValue::CreateStringValue(profile.peerEndpointId));
            item.Insert(L"PeerProtocolVersion", profile.peerProtocolVersion ? JsonValue::CreateNumberValue(*profile.peerProtocolVersion) : JsonValue::CreateNullValue());
            item.Insert(L"CoordinationEnabled", JsonValue::CreateBooleanValue(profile.coordinationEnabled));
            JsonArray mappings;
            for (auto const& mapping : profile.displayInputs)
            {
                JsonObject mappingObject; mappingObject.Insert(L"DisplayId", JsonValue::CreateStringValue(mapping.displayId));
                mappingObject.Insert(L"PeerInput", JsonValue::CreateNumberValue(mapping.peerInput)); mappings.Append(mappingObject);
            }
            item.Insert(L"DisplayInputs", mappings);
            profileArray.Append(item);
        }
        object.Insert(L"CollaborationProfiles", profileArray);
        return object;
    }

    void WriteAtomic(DisplaySwitcher::Native::AppConfig const& config, std::filesystem::path const& path, bool clearMarker,
        DisplaySwitcher::Native::AppConfigSaveFaultForTesting fault = DisplaySwitcher::Native::AppConfigSaveFaultForTesting::None)
    {
        std::filesystem::path temporary;
        try
        {
            auto object = Serialize(config);
            std::filesystem::create_directories(path.parent_path());
            temporary = path; temporary += L"." + DisplaySwitcher::Native::GenerateIdentifier() + L".tmp";
            auto text = to_string(object.Stringify());
            std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
            if (!stream) throw std::runtime_error("cannot open temporary settings file");
            if (fault == DisplaySwitcher::Native::AppConfigSaveFaultForTesting::TemporaryWrite)
                throw std::runtime_error("injected temporary settings write failure");
            stream.write(text.data(), static_cast<std::streamsize>(text.size())); stream.flush();
            if (!stream) throw std::runtime_error("cannot save temporary settings file");
            stream.close();
            std::ifstream verify(temporary, std::ios::binary);
            std::string verifyText((std::istreambuf_iterator<char>(verify)), std::istreambuf_iterator<char>());
            auto verifyObject = JsonObject::Parse(to_hstring(verifyText));
            if (fault == DisplaySwitcher::Native::AppConfigSaveFaultForTesting::ReadbackMismatch)
            {
                auto profiles = verifyObject.GetNamedArray(L"CollaborationProfiles");
                auto profile = profiles.GetObjectAt(0);
                auto mappings = profile.GetNamedArray(L"DisplayInputs");
                auto mapping = mappings.GetObjectAt(0);
                auto current = RequiredInteger(mapping, L"PeerInput", 0, 65535);
                mapping.Insert(L"PeerInput", JsonValue::CreateNumberValue(current == 65535 ? 65534 : current + 1));
            }
            auto readback = ReadCompleteV5Config(verifyObject);
            auto normalizedReadback = Serialize(readback);
            if (normalizedReadback.Stringify() != object.Stringify())
                throw std::runtime_error("settings readback mismatch");
            verify.close();
            if (fault == DisplaySwitcher::Native::AppConfigSaveFaultForTesting::AtomicReplace)
                throw std::runtime_error("injected atomic settings replace failure");
            if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                throw std::system_error(static_cast<int>(GetLastError()), std::system_category(), "cannot replace settings file");
            if (clearMarker) ClearMarker(path);
        }
        catch (...)
        {
            auto failure = std::current_exception();
            std::error_code ignored;
            if (!temporary.empty()) std::filesystem::remove(temporary, ignored);
            if (!SetMarker(path)) throw std::runtime_error("settings save failed and safety marker could not be persisted");
            std::rethrow_exception(failure);
        }
    }
}

namespace DisplaySwitcher::Native
{
    bool AppConfig::HasUsbDeviceConfiguration() const noexcept
    {
        return !displayConfigurationSafeMode && !usbSwitch.deviceLocalReference.empty() &&
            usbSwitch.vendorId >= 0 && usbSwitch.vendorId <= 0xFFFF &&
            usbSwitch.productId >= 0 && usbSwitch.productId <= 0xFFFF;
    }

    bool AppConfig::HasDisplayConfiguration(std::wstring const& profileId) const noexcept
    {
        if (displayConfigurationSafeMode || displays.empty()) return false;
        std::set<std::wstring> ids, hardwareIds;
        for (auto const& display : displays)
        {
            if (!IsValidDisplayId(display.id) || !VisibleText(display.name, 1, 64) || !ids.insert(Lower(display.id)).second) return false;
            std::wstring hardwareId;
            auto backend = displayControlBackend == L"auto" ? L"native_ddc" : displayControlBackend;
            if (backend == L"native_ddc") hardwareId = display.nativeMonitorId;
            else if (backend == L"control_my_monitor") hardwareId = display.controlMonitorPath;
            else return false;
            if (hardwareId.empty()) return false;
            hardwareId = backend + L":" + hardwareId;
            if (!hardwareIds.insert(Lower(hardwareId)).second) return false;
        }
        if (displayControlBackend == L"control_my_monitor" && controlMyMonitorPath.empty()) return false;
        return profileId.empty() || IsProfileDisplayMappingComplete(profileId);
    }

    bool AppConfig::HasCollaborationProfile(std::wstring const& id) const noexcept { return FindCollaborationProfile(id) != nullptr; }

    CollaborationProfile const* AppConfig::FindCollaborationProfile(std::wstring const& id) const noexcept
    {
        for (auto const& profile : collaborationProfiles) if (EqualInsensitive(profile.id, id)) return &profile;
        return nullptr;
    }

    CollaborationProfile* AppConfig::FindCollaborationProfile(std::wstring const& id) noexcept
    {
        for (auto& profile : collaborationProfiles) if (EqualInsensitive(profile.id, id)) return &profile;
        return nullptr;
    }

    std::vector<CollaborationProfile> AppConfig::ReadonlyEnabledProfiles() const
    {
        std::vector<CollaborationProfile> result;
        for (auto const& profile : collaborationProfiles) if (profile.coordinationEnabled) result.push_back(profile);
        return result;
    }

    std::vector<CollaborationProfile> AppConfig::EnabledCompleteProfiles() const
    {
        std::vector<CollaborationProfile> result;
        for (auto const& profile : collaborationProfiles)
            if (profile.coordinationEnabled && InspectProfile(profile.id).complete &&
                profile.peerProtocolVersion == 2 && IsValidDisplayId(profile.peerEndpointId) &&
                !EqualInsensitive(profile.peerEndpointId, localEndpointId)) result.push_back(profile);
        return result;
    }

    std::vector<std::wstring> AppConfig::OrderedDisplayIds() const
    {
        std::vector<std::wstring> result;
        for (auto const& display : displays) result.push_back(display.id);
        return result;
    }

    bool AppConfig::IsProfileDisplayMappingComplete(std::wstring const& profileId) const noexcept
    {
        if (!FindCollaborationProfile(profileId) || displays.empty()) return false;
        for (auto const& display : displays) if (PeerInputForDisplay(profileId, display.id, -1) < 0) return false;
        return true;
    }

    int AppConfig::PeerInputForDisplay(std::wstring const& profileId, std::wstring const& displayId, int fallback) const noexcept
    {
        auto profile = FindCollaborationProfile(profileId);
        if (!profile) return fallback;
        for (auto const& mapping : profile->displayInputs)
            if (EqualInsensitive(mapping.displayId, displayId)) return mapping.peerInput;
        return fallback;
    }

    std::optional<int> AppConfig::UsbInputForDisplay(std::wstring const& displayId) const noexcept
    {
        for (auto const& mapping : usbSwitch.displayInputs)
            if (EqualInsensitive(mapping.displayId, displayId)) return mapping.targetInput;
        return std::nullopt;
    }

    ProfileInspectionResult AppConfig::InspectProfile(std::wstring const& profileId,
        std::wstring const& observedEndpointId, std::optional<int> observedProtocolVersion) const
    {
        ProfileInspectionResult result;
        auto profile = FindCollaborationProfile(profileId);
        if (!profile) { result.problems.push_back(L"配置不存在"); return result; }
        if (!VisibleText(profile->name, 1, 32)) result.problems.push_back(L"名称无效");
        if (profile->peerHost.empty()) result.problems.push_back(L"未填写对端主机");
        if (profile->peerPort < 1 || profile->peerPort > 65535) result.problems.push_back(L"端口无效");
        if (!IsValidPairingCode(profile->pairingCode)) result.problems.push_back(L"配对码无效");
        if (profile->displayInputs.empty()) result.problems.push_back(L"未配置显示器输入映射");
        for (auto const& mapping : profile->displayInputs)
            if (!FindDisplayById(displays, mapping.displayId)) result.problems.push_back(L"显示器映射已不可用");
        if (!observedEndpointId.empty())
        {
            if (!IsValidDisplayId(observedEndpointId)) result.problems.push_back(L"检测到的 endpointID 无效");
            else if (!profile->peerEndpointId.empty() && !EqualInsensitive(profile->peerEndpointId, observedEndpointId))
                result.endpointConfirmationRequired = true;
        }
        if (observedProtocolVersion && *observedProtocolVersion != 2)
            result.problems.push_back(L"检测到未知协议版本");
        result.complete = result.problems.empty() && !result.endpointConfirmationRequired;
        return result;
    }

    ProfileDisplaySelection AppConfig::SelectProfileDisplays(std::wstring const& profileId) const
    {
        ProfileDisplaySelection result;
        if (displayConfigurationSafeMode || !FindCollaborationProfile(profileId)) return result;
        for (auto const& display : displays)
        {
            auto input = PeerInputForDisplay(profileId, display.id, -1);
            if (input < 0) result.missingDisplayIds.push_back(display.id);
            else { auto selected = display; selected.macInput = input; result.mappedDisplays.push_back(std::move(selected)); }
        }
        return result;
    }

    bool AppConfig::IsValidPairingCode(std::wstring const& code, bool requireNormalized)
    {
        if (code.empty()) return false;
        auto normalized = NormalizeNfcValue(code);
        return (!requireNormalized || normalized == code) && ValidPairing(normalized);
    }

    std::wstring AppConfig::NormalizeNfc(std::wstring const& text) { return NormalizeNfcValue(text); }
    bool AppConfig::IsValidConfigurationPath(std::wstring const& path) noexcept { return !path.empty(); }

    std::filesystem::path AppConfig::ConfigPath()
    {
        PWSTR roaming{};
        check_hresult(SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_DEFAULT, nullptr, &roaming));
        std::filesystem::path path(roaming); CoTaskMemFree(roaming);
        return path / L"DisplaySwitcher" / L"settings.json";
    }

    AppConfig AppConfig::Load() { return LoadFromPath(ConfigPath()); }

    AppConfig AppConfig::LoadFromPath(std::filesystem::path const& path)
    {
        auto defaults = NewConfig();
        if (!std::filesystem::exists(path))
        {
            try { WriteAtomic(defaults, path, true); }
            catch (...) { EnterSafeMode(defaults); SetMarker(path); }
            return defaults;
        }

        auto markerPresent = std::filesystem::exists(MarkerPath(path));
        try
        {
            std::ifstream stream(path, std::ios::binary);
            if (!stream) throw std::runtime_error("cannot read settings");
            std::string text((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
            stream.close();
            auto object = JsonObject::Parse(to_hstring(text));
            auto schema = SchemaVersion(object);
            if (schema == 4)
            {
                auto migrated = ReadCompleteV4Config(object);
                migrated.usbSwitch = {};
                try
                {
                    auto backup = BackupPath(path);
                    for (unsigned suffix = 1; std::filesystem::exists(backup); ++suffix)
                        backup = std::filesystem::path(BackupPath(path).wstring() + L"." + std::to_wstring(suffix));
                    if (!CopyFileW(path.c_str(), backup.c_str(), TRUE))
                        throw hresult_error(HRESULT_FROM_WIN32(GetLastError()));
                    WriteAtomic(migrated, path, true);
                    return migrated;
                }
                catch (...)
                {
                    SetMarker(path); EnterSafeMode(migrated); return migrated;
                }
            }

            if (schema != CurrentConfigVersion) throw std::runtime_error("unsupported settings schema");

            auto config = ReadCompleteV5Config(object);
            if (markerPresent) EnterSafeMode(config);
            return config;
        }
        catch (std::exception const& error)
        {
            static_cast<void>(error);
            SetMarker(path); EnterSafeMode(defaults); return defaults;
        }
        catch (...)
        {
            SetMarker(path); EnterSafeMode(defaults); return defaults;
        }
    }

    void AppConfig::EnterSafeState() noexcept { EnterSafeMode(*this); }
    void AppConfig::Save() const { SaveToPath(ConfigPath()); }
    void AppConfig::SaveToPath(std::filesystem::path const& path, AppConfigSaveFaultForTesting fault) const
    {
        WriteAtomic(*this, path, true, fault);
    }
}
