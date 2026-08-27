#include "pch.h"
#include "AppConfig.h"

#include <algorithm>
#include <limits>

#pragma comment(lib, "Normaliz.lib")

using namespace winrt;
using namespace Windows::Data::Json;

namespace
{
    constexpr int CurrentConfigVersion = 3;

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
    std::filesystem::path BackupPath(std::filesystem::path const& path) { auto value = path; value += L".v2.backup"; return value; }

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

    DisplaySwitcher::Native::DisplayConfig ReadV3Display(JsonObject const& object)
    {
        DisplaySwitcher::Native::DisplayConfig display;
        display.id = RequiredString(object, L"Id");
        display.name = RequiredString(object, L"Name");
        display.localInput = NullableInteger(object, L"LocalInput", 0, 65535, true);
        display.readEnabled = RequiredBoolean(object, L"ReadEnabled");
        display.brightnessEnabled = RequiredBoolean(object, L"BrightnessEnabled");
        display.contrastEnabled = RequiredBoolean(object, L"ContrastEnabled");
        display.volumeEnabled = RequiredBoolean(object, L"VolumeEnabled");
        display.nativeMonitorId = OptionalString(object, L"NativeMonitorId");
        display.controlMonitorPath = OptionalString(object, L"ControlMonitorPath");
        display.macInput = OptionalInteger(object, L"MacInput", -1, -1, 65535);
        display.brightnessValue = NullableInteger(object, L"Brightness", 0, 65535, false);
        display.contrastValue = NullableInteger(object, L"Contrast", 0, 65535, false);
        display.volumeValue = NullableInteger(object, L"Volume", 0, 65535, false);
        display.brightnessMax = NullableInteger(object, L"BrightnessMax", 1, 65535, false);
        display.contrastMax = NullableInteger(object, L"ContrastMax", 1, 65535, false);
        display.volumeMax = NullableInteger(object, L"VolumeMax", 1, 65535, false);
        return display;
    }

    DisplaySwitcher::Native::DisplayConfig ReadV2Display(JsonObject const& object)
    {
        DisplaySwitcher::Native::DisplayConfig display;
        display.id = RequiredString(object, L"Id");
        display.name = RequiredString(object, L"Name");
        display.nativeMonitorId = OptionalString(object, L"NativeMonitorId");
        display.controlMonitorPath = OptionalString(object, L"ControlMonitorPath");
        display.macInput = RequiredInteger(object, L"MacInput", -1, 65535);
        display.localInput.reset();
        display.readEnabled = display.brightnessEnabled = display.contrastEnabled = display.volumeEnabled = true;
        return display;
    }

    DisplaySwitcher::Native::DisplayConfig ReadLegacyDisplay(JsonObject const& object, wchar_t const* name,
        wchar_t const* path, wchar_t const* nativeId, wchar_t const* input)
    {
        auto display = DisplaySwitcher::Native::CreateDisplayConfig(name);
        display.controlMonitorPath = OptionalString(object, path);
        display.nativeMonitorId = OptionalString(object, nativeId);
        display.macInput = OptionalInteger(object, input, -1, -1, 65535);
        display.localInput.reset();
        display.readEnabled = true;
        return display;
    }

    bool HasLegacyDisplay(JsonObject const& object, wchar_t const* path, wchar_t const* nativeId, wchar_t const* input)
    {
        return !OptionalString(object, path).empty() || !OptionalString(object, nativeId).empty()
            || OptionalInteger(object, input, -1, -1, 65535) >= 0;
    }

    DisplaySwitcher::Native::CollaborationProfile ReadProfile(JsonObject const& object)
    {
        DisplaySwitcher::Native::CollaborationProfile profile;
        profile.id = RequiredString(object, L"Id");
        profile.name = RequiredString(object, L"Name");
        profile.peerHost = RequiredString(object, L"PeerHost");
        profile.peerPort = RequiredInteger(object, L"PeerPort", 1, 65535);
        profile.pairingCode = RequiredString(object, L"PairingCode");
        if (Type(object, L"PeerEndpointID") != JsonValueType::Null) profile.peerEndpointId = RequiredString(object, L"PeerEndpointID");
        profile.peerProtocolVersion = NullableInteger(object, L"PeerProtocolVersion", 1, 2, true);
        profile.coordinationEnabled = RequiredBoolean(object, L"CoordinationEnabled");
        for (auto const& value : RequiredArray(object, L"DisplayInputs"))
        {
            auto item = value.GetObject();
            profile.displayInputs.push_back({ RequiredString(item, L"DisplayId"), RequiredInteger(item, L"PeerInput", 0, 65535) });
        }
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
            if (profile.peerProtocolVersion && *profile.peerProtocolVersion != 1 && *profile.peerProtocolVersion != 2)
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
        ValidateDisplays(config.displays);
        ValidateProfiles(config.collaborationProfiles);
    }

    void LegacyBridge(DisplaySwitcher::Native::AppConfig& config)
    {
        config.peerHost.clear(); config.pairingCode.clear(); config.peerPort = config.port = 49731; config.coordinationEnabled = false;
        for (auto& display : config.displays) display.macInput = -1;
        if (config.collaborationProfiles.size() != 1) return;
        auto const& profile = config.collaborationProfiles.front();
        config.peerHost = profile.peerHost; config.pairingCode = profile.pairingCode;
        config.peerPort = config.port = profile.peerPort; config.coordinationEnabled = profile.coordinationEnabled;
        for (auto& display : config.displays)
            for (auto const& mapping : profile.displayInputs)
                if (EqualInsensitive(display.id, mapping.displayId)) { display.macInput = mapping.peerInput; break; }
    }

    DisplaySwitcher::Native::AppConfig ReadCompleteV3Config(JsonObject const& object)
    {
        if (SchemaVersion(object) != CurrentConfigVersion) throw std::runtime_error("invalid settings schema");
        DisplaySwitcher::Native::AppConfig config;
        config.localEndpointId = RequiredString(object, L"LocalEndpointId");
        config.localDeviceName = RequiredString(object, L"LocalDeviceName");
        config.listenPort = RequiredInteger(object, L"ListenPort", 1, 65535);
        config.usbAutomationEnabled = RequiredBoolean(object, L"UsbAutomationEnabled");
        config.usbVendorId = RequiredInteger(object, L"UsbVendorId", -1, 65535);
        config.usbProductId = RequiredInteger(object, L"UsbProductId", -1, 65535);
        config.usbName = RequiredString(object, L"UsbName");
        config.displayControlBackend = RequiredString(object, L"DisplayControlBackend");
        config.controlMyMonitorPath = RequiredString(object, L"ControlMyMonitorPath");
        config.startWithWindows = RequiredBoolean(object, L"StartWithWindows");
        config.coordinationEnabled = RequiredBoolean(object, L"CoordinationEnabled");
        config.peerHost = RequiredString(object, L"PeerHost");
        config.port = config.peerPort = RequiredInteger(object, L"Port", 1, 65535);
        config.pairingCode = RequiredString(object, L"PairingCode");
        for (auto const& value : RequiredArray(object, L"Displays")) config.displays.push_back(ReadV3Display(value.GetObject()));
        for (auto const& value : RequiredArray(object, L"CollaborationProfiles")) config.collaborationProfiles.push_back(ReadProfile(value.GetObject()));
        ValidateConfig(config);
        LegacyBridge(config);
        return config;
    }

    void EnterSafeMode(DisplaySwitcher::Native::AppConfig& config)
    {
        config.displayConfigurationSafeMode = true;
        config.usbAutomationEnabled = false;
        config.coordinationEnabled = false;
        for (auto& profile : config.collaborationProfiles) profile.coordinationEnabled = false;
    }

    DisplaySwitcher::Native::AppConfig NewConfig()
    {
        DisplaySwitcher::Native::AppConfig config;
        config.localEndpointId = DisplaySwitcher::Native::GenerateIdentifier();
        EnsureDefaultProfile(config);
        return config;
    }

    JsonObject Serialize(DisplaySwitcher::Native::AppConfig const& source)
    {
        auto config = source;
        if (config.localEndpointId.empty()) config.localEndpointId = DisplaySwitcher::Native::GenerateIdentifier();
        config.localDeviceName = Trim(config.localDeviceName);
        EnsureDefaultProfile(config);
        for (auto& display : config.displays) display.name = Trim(display.name);
        for (auto& profile : config.collaborationProfiles)
        {
            profile.name = Trim(profile.name); profile.peerHost = Trim(profile.peerHost);
            profile.pairingCode = NormalizeNfcValue(profile.pairingCode);
        }
        ValidateConfig(config);
        LegacyBridge(config);

        JsonObject object;
        object.Insert(L"schemaVersion", JsonValue::CreateNumberValue(CurrentConfigVersion));
        object.Insert(L"LocalEndpointId", JsonValue::CreateStringValue(config.localEndpointId));
        object.Insert(L"LocalDeviceName", JsonValue::CreateStringValue(config.localDeviceName));
        object.Insert(L"ListenPort", JsonValue::CreateNumberValue(config.listenPort));
        object.Insert(L"UsbAutomationEnabled", JsonValue::CreateBooleanValue(config.usbAutomationEnabled));
        object.Insert(L"UsbVendorId", JsonValue::CreateNumberValue(config.usbVendorId));
        object.Insert(L"UsbProductId", JsonValue::CreateNumberValue(config.usbProductId));
        object.Insert(L"UsbName", JsonValue::CreateStringValue(config.usbName));
        object.Insert(L"DisplayControlBackend", JsonValue::CreateStringValue(config.displayControlBackend));
        object.Insert(L"ControlMyMonitorPath", JsonValue::CreateStringValue(config.controlMyMonitorPath));
        object.Insert(L"StartWithWindows", JsonValue::CreateBooleanValue(config.startWithWindows));
        object.Insert(L"CoordinationEnabled", JsonValue::CreateBooleanValue(config.coordinationEnabled));
        object.Insert(L"PeerHost", JsonValue::CreateStringValue(config.peerHost));
        object.Insert(L"Port", JsonValue::CreateNumberValue(config.port));
        object.Insert(L"PairingCode", JsonValue::CreateStringValue(config.pairingCode));

        JsonArray displayArray;
        for (auto const& display : config.displays)
        {
            JsonObject item;
            item.Insert(L"Id", JsonValue::CreateStringValue(display.id)); item.Insert(L"Name", JsonValue::CreateStringValue(display.name));
            item.Insert(L"LocalInput", display.localInput ? JsonValue::CreateNumberValue(*display.localInput) : JsonValue::CreateNullValue());
            item.Insert(L"ReadEnabled", JsonValue::CreateBooleanValue(display.readEnabled));
            item.Insert(L"BrightnessEnabled", JsonValue::CreateBooleanValue(display.brightnessEnabled));
            item.Insert(L"ContrastEnabled", JsonValue::CreateBooleanValue(display.contrastEnabled));
            item.Insert(L"VolumeEnabled", JsonValue::CreateBooleanValue(display.volumeEnabled));
            item.Insert(L"NativeMonitorId", JsonValue::CreateStringValue(display.nativeMonitorId));
            item.Insert(L"ControlMonitorPath", JsonValue::CreateStringValue(display.controlMonitorPath));
            item.Insert(L"MacInput", JsonValue::CreateNumberValue(display.macInput));
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
            JsonArray triggers;
            for (auto const& trigger : profile.triggerDevices)
            {
                JsonObject triggerObject; triggerObject.Insert(L"Kind", JsonValue::CreateStringValue(trigger.kind));
                triggerObject.Insert(L"LocalReference", JsonValue::CreateStringValue(trigger.localReference));
                triggerObject.Insert(L"DisplayName", JsonValue::CreateStringValue(trigger.displayName)); triggers.Append(triggerObject);
            }
            item.Insert(L"TriggerDevices", triggers); profileArray.Append(item);
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
            auto readback = ReadCompleteV3Config(verifyObject);
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
        return !displayConfigurationSafeMode && usbVendorId >= 0 && usbVendorId <= 0xFFFF
            && usbProductId >= 0 && usbProductId <= 0xFFFF;
    }

    bool AppConfig::HasDisplayConfiguration(std::wstring const& profileId) const noexcept
    {
        if (displayConfigurationSafeMode || displays.empty()) return false;
        std::set<std::wstring> ids, hardwareIds;
        for (auto const& display : displays)
        {
            if (!IsValidDisplayId(display.id) || !VisibleText(display.name, 1, 64) || !ids.insert(Lower(display.id)).second) return false;
            if (profileId.empty() && (display.macInput < 0 || display.macInput > 65535)) return false;
            std::wstring hardwareId;
            if (displayControlBackend == L"native_ddc") hardwareId = display.nativeMonitorId;
            else if (displayControlBackend == L"control_my_monitor") hardwareId = display.controlMonitorPath;
            else return false;
            if (hardwareId.empty() || !hardwareIds.insert(Lower(hardwareId)).second) return false;
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
            if (profile.coordinationEnabled && InspectProfile(profile.id).complete) result.push_back(profile);
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
        if (observedProtocolVersion && *observedProtocolVersion != 1 && *observedProtocolVersion != 2)
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
            if (schema > CurrentConfigVersion) throw std::runtime_error("unsupported settings schema");

            AppConfig config;
            config.localEndpointId = schema == CurrentConfigVersion ? RequiredString(object, L"LocalEndpointId") : GenerateIdentifier();
            config.localDeviceName = schema == CurrentConfigVersion ? RequiredString(object, L"LocalDeviceName") : L"本机";
            config.listenPort = schema == CurrentConfigVersion ? RequiredInteger(object, L"ListenPort", 1, 65535)
                : OptionalInteger(object, L"Port", 49731, 1, 65535);
            config.usbAutomationEnabled = OptionalBoolean(object, L"UsbAutomationEnabled", false);
            config.usbVendorId = OptionalInteger(object, L"UsbVendorId", -1, -1, 65535);
            config.usbProductId = OptionalInteger(object, L"UsbProductId", -1, -1, 65535);
            config.usbName = OptionalString(object, L"UsbName");
            config.displayControlBackend = OptionalString(object, L"DisplayControlBackend");
            config.controlMyMonitorPath = OptionalString(object, L"ControlMyMonitorPath");
            config.startWithWindows = OptionalBoolean(object, L"StartWithWindows", false);

            if (schema == CurrentConfigVersion)
            {
                for (auto const& value : RequiredArray(object, L"Displays")) config.displays.push_back(ReadV3Display(value.GetObject()));
                for (auto const& value : RequiredArray(object, L"CollaborationProfiles")) config.collaborationProfiles.push_back(ReadProfile(value.GetObject()));
            }
            else
            {
                if (object.HasKey(L"Displays"))
                    for (auto const& value : RequiredArray(object, L"Displays")) config.displays.push_back(ReadV2Display(value.GetObject()));
                else
                {
                    if (HasLegacyDisplay(object, L"RedmiMonitorPath", L"RedmiNativeMonitorId", L"RedmiMacInput"))
                        config.displays.push_back(ReadLegacyDisplay(object, L"显示器 1", L"RedmiMonitorPath", L"RedmiNativeMonitorId", L"RedmiMacInput"));
                    if (HasLegacyDisplay(object, L"DellMonitorPath", L"DellNativeMonitorId", L"DellMacInput"))
                        config.displays.push_back(ReadLegacyDisplay(object, L"显示器 2", L"DellMonitorPath", L"DellNativeMonitorId", L"DellMacInput"));
                }
                CollaborationProfile profile;
                profile.id = GenerateIdentifier(); profile.name = L"Mac";
                profile.peerHost = OptionalString(object, L"PeerHost");
                profile.peerPort = OptionalInteger(object, L"Port", 49731, 1, 65535);
                profile.pairingCode = NormalizeNfcValue(OptionalString(object, L"PairingCode"));
                profile.coordinationEnabled = OptionalBoolean(object, L"CoordinationEnabled", false);
                for (auto const& display : config.displays) if (display.macInput >= 0) profile.displayInputs.push_back({ display.id, display.macInput });
                if (config.usbVendorId >= 0 && config.usbProductId >= 0)
                {
                    wchar_t reference[32]{};
                    swprintf_s(reference, L"usb:%04X:%04X", config.usbVendorId, config.usbProductId);
                    profile.triggerDevices.push_back({ L"usb", reference, config.usbName.empty() ? L"USB 触发设备" : config.usbName });
                }
                if (config.displays.empty() && profile.peerHost.empty() && profile.pairingCode.empty()) profile.name = L"配置 1";
                config.collaborationProfiles.push_back(std::move(profile));
            }

            ValidateConfig(config);
            LegacyBridge(config);
            if (schema < CurrentConfigVersion)
            {
                auto backup = BackupPath(path);
                if (!std::filesystem::exists(backup) && !CopyFileW(path.c_str(), backup.c_str(), TRUE))
                    throw hresult_error(HRESULT_FROM_WIN32(GetLastError()));
                WriteAtomic(config, path, false);
            }
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
