#include "pch.h"
#include "DdcBackends.h"
#include "Diagnostics.h"
#include <devpkey.h>

namespace DisplaySwitcher::Native
{
    bool IsRemoteDisplaySession(DisplaySessionProbe const& probe) noexcept
    {
        if (probe.remoteSessionMetric) return true;
        return probe.currentSessionId && probe.glassSessionId
            && *probe.currentSessionId != *probe.glassSessionId;
    }

    bool IsRemoteOrMirroringDisplayDevice(uint32_t stateFlags) noexcept
    {
        return (stateFlags & (DISPLAY_DEVICE_REMOTE | DISPLAY_DEVICE_MIRRORING_DRIVER)) != 0;
    }

    DisplayTopologyTrust ClassifyDisplayTopology(bool remoteSession, uint32_t queryError,
        bool partialFailure, size_t localPhysicalTargetCount) noexcept
    {
        if (remoteSession || queryError == ERROR_ACCESS_DENIED)
            return DisplayTopologyTrust::RemoteSessionLimited;
        if (queryError != ERROR_SUCCESS || partialFailure || localPhysicalTargetCount == 0)
            return DisplayTopologyTrust::IncompleteOrUnavailable;
        return DisplayTopologyTrust::LocalPhysicalAuthoritative;
    }
}

namespace
{
    using namespace DisplaySwitcher::Native;

    constexpr GUID MonitorInterfaceClass{
        0xe6f07b5f, 0xee97, 0x4a90, { 0xb0, 0x76, 0x33, 0xf5, 0x7b, 0xf4, 0xea, 0xa7 } };
    constexpr DEVPROPKEY DeviceContainerIdKey{
        { 0x8c7ed206, 0x3f8a, 0x4827, { 0xb3, 0xab, 0xae, 0x9e, 0x1f, 0xae, 0xfc, 0x6c } }, 2 };

    bool EqualInsensitive(std::wstring const& left, std::wstring const& right) noexcept
    {
        return _wcsicmp(left.c_str(), right.c_str()) == 0;
    }

    std::wstring LuidText(LUID const& luid)
    {
        wchar_t value[32]{};
        swprintf_s(value, L"%08x%08x", static_cast<unsigned>(luid.HighPart), luid.LowPart);
        return value;
    }

    bool EmptyGuid(GUID const& value) noexcept
    {
        static constexpr GUID empty{};
        return InlineIsEqualGUID(value, empty) != FALSE;
    }

    std::wstring Sha256Token(std::vector<BYTE> const& bytes)
    {
        BCRYPT_ALG_HANDLE algorithm{};
        BCRYPT_HASH_HANDLE hash{};
        DWORD objectLength{}, resultLength{};
        std::vector<BYTE> object;
        std::vector<BYTE> digest(32);
        if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return {};
        auto close = [&]
        {
            if (hash) BCryptDestroyHash(hash);
            if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
        };
        if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectLength),
            sizeof(objectLength), &resultLength, 0) < 0)
        {
            close(); return {};
        }
        object.resize(objectLength);
        if (BCryptCreateHash(algorithm, &hash, object.data(), objectLength, nullptr, 0, 0) < 0
            || (!bytes.empty() && BCryptHashData(hash, const_cast<PUCHAR>(bytes.data()),
                static_cast<ULONG>(bytes.size()), 0) < 0)
            || BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) < 0)
        {
            close(); return {};
        }
        close();
        constexpr wchar_t hex[] = L"0123456789abcdef";
        std::wstring result = L"ds13:";
        result.reserve(result.size() + digest.size() * 2);
        for (auto byte : digest)
        {
            result.push_back(hex[byte >> 4]);
            result.push_back(hex[byte & 0x0f]);
        }
        return result;
    }

    void AppendBytes(std::vector<BYTE>& target, void const* data, size_t size)
    {
        auto first = static_cast<BYTE const*>(data);
        target.insert(target.end(), first, first + size);
    }

    struct InterfaceIdentity
    {
        std::wstring strongId;
        std::vector<std::wstring> legacyIds;
    };

    InterfaceIdentity ReadInterfaceIdentity(std::wstring const& monitorDevicePath)
    {
        InterfaceIdentity result;
        auto set = SetupDiGetClassDevsW(&MonitorInterfaceClass, nullptr, nullptr,
            DIGCF_DEVICEINTERFACE | DIGCF_PRESENT);
        if (set == INVALID_HANDLE_VALUE) return result;

        for (DWORD index = 0;; ++index)
        {
            SP_DEVICE_INTERFACE_DATA interfaceData{ sizeof(interfaceData) };
            if (!SetupDiEnumDeviceInterfaces(set, nullptr, &MonitorInterfaceClass, index, &interfaceData))
            {
                if (GetLastError() == ERROR_NO_MORE_ITEMS) break;
                continue;
            }
            DWORD required{};
            SetupDiGetDeviceInterfaceDetailW(set, &interfaceData, nullptr, 0, &required, nullptr);
            if (!required) continue;
            std::vector<BYTE> detailBytes(required);
            auto detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(detailBytes.data());
            detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
            SP_DEVINFO_DATA deviceInfo{ sizeof(deviceInfo) };
            if (!SetupDiGetDeviceInterfaceDetailW(set, &interfaceData, detail, required, nullptr, &deviceInfo)) continue;
            if (!EqualInsensitive(detail->DevicePath, monitorDevicePath)) continue;

            result.legacyIds.push_back(detail->DevicePath);
            wchar_t instanceId[MAX_DEVICE_ID_LEN]{};
            if (CM_Get_Device_IDW(deviceInfo.DevInst, instanceId, ARRAYSIZE(instanceId), 0) == CR_SUCCESS)
                result.legacyIds.push_back(instanceId);

            GUID container{};
            DEVPROPTYPE propertyType{};
            DWORD propertySize = sizeof(container);
            auto hasContainer = SetupDiGetDevicePropertyW(set, &deviceInfo, &DeviceContainerIdKey,
                &propertyType, reinterpret_cast<PBYTE>(&container), propertySize, &propertySize, 0)
                && propertyType == DEVPROP_TYPE_GUID && !EmptyGuid(container);

            std::vector<BYTE> edid;
            auto key = SetupDiOpenDevRegKey(set, &deviceInfo, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_READ);
            if (key != INVALID_HANDLE_VALUE)
            {
                DWORD type{}, size{};
                if (RegQueryValueExW(key, L"EDID", nullptr, &type, nullptr, &size) == ERROR_SUCCESS
                    && type == REG_BINARY && size >= 16)
                {
                    edid.resize(size);
                    if (RegQueryValueExW(key, L"EDID", nullptr, &type, edid.data(), &size) != ERROR_SUCCESS)
                        edid.clear();
                }
                RegCloseKey(key);
            }
            uint32_t serial{};
            if (edid.size() >= 16)
                serial = static_cast<uint32_t>(edid[12]) | (static_cast<uint32_t>(edid[13]) << 8)
                    | (static_cast<uint32_t>(edid[14]) << 16) | (static_cast<uint32_t>(edid[15]) << 24);

            // Friendly name/model is never identity. Only a nonzero Container ID
            // or EDID serial contributes to the opaque persisted binding token.
            if (hasContainer || serial != 0)
            {
                std::vector<BYTE> material;
                // Prefer the monitor-owned EDID identity so HDMI/DP/USB-C port
                // changes do not replace it with a connection-specific container.
                if (serial != 0) AppendBytes(material, edid.data(), edid.size());
                else AppendBytes(material, &container, sizeof(container));
                result.strongId = Sha256Token(material);
            }
            break;
        }
        SetupDiDestroyDeviceInfoList(set);
        return result;
    }

    struct ActiveTarget
    {
        std::wstring logicalTargetId;
        std::wstring gdiName;
        std::wstring monitorDevicePath;
        std::wstring friendlyName;
    };

    DisplaySessionProbe CurrentDisplaySessionProbe()
    {
        DisplaySessionProbe result;
        result.remoteSessionMetric = GetSystemMetrics(SM_REMOTESESSION) != 0;
        DWORD currentSession{};
        if (ProcessIdToSessionId(GetCurrentProcessId(), &currentSession))
            result.currentSessionId = currentSession;

        HKEY key{};
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
            L"SYSTEM\\CurrentControlSet\\Control\\Terminal Server", 0, KEY_READ, &key) == ERROR_SUCCESS)
        {
            DWORD type{}, glassSession{}, size = sizeof(glassSession);
            if (RegQueryValueExW(key, L"GlassSessionId", nullptr, &type,
                reinterpret_cast<BYTE*>(&glassSession), &size) == ERROR_SUCCESS
                && type == REG_DWORD && size == sizeof(glassSession))
                result.glassSessionId = glassSession;
            RegCloseKey(key);
        }
        return result;
    }

    std::optional<DWORD> DisplayAdapterFlags(std::wstring const& gdiName)
    {
        for (DWORD index = 0;; ++index)
        {
            DISPLAY_DEVICEW device{ sizeof(device) };
            if (!EnumDisplayDevicesW(nullptr, index, &device, 0)) break;
            if (EqualInsensitive(device.DeviceName, gdiName)) return device.StateFlags;
        }
        return std::nullopt;
    }

    bool QueryActiveTargets(std::vector<ActiveTarget>& targets, DWORD& error, bool& partialFailure,
        bool& remoteTargetDetected)
    {
        UINT32 pathCount{}, modeCount{};
        auto status = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &pathCount, &modeCount);
        if (status != ERROR_SUCCESS) { error = status; return false; }
        std::vector<DISPLAYCONFIG_PATH_INFO> paths(pathCount);
        std::vector<DISPLAYCONFIG_MODE_INFO> modes(modeCount);
        status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &pathCount, paths.data(), &modeCount, modes.data(), nullptr);
        if (status != ERROR_SUCCESS) { error = status; return false; }
        paths.resize(pathCount);

        for (auto const& path : paths)
        {
            DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
            source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            source.header.size = sizeof(source);
            source.header.adapterId = path.sourceInfo.adapterId;
            source.header.id = path.sourceInfo.id;
            if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS)
            {
                partialFailure = true;
                continue;
            }

            if (auto flags = DisplayAdapterFlags(source.viewGdiDeviceName); flags && IsRemoteOrMirroringDisplayDevice(*flags))
            {
                remoteTargetDetected = remoteTargetDetected || ((*flags & DISPLAY_DEVICE_REMOTE) != 0);
                continue;
            }

            DISPLAYCONFIG_TARGET_DEVICE_NAME target{};
            target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
            target.header.size = sizeof(target);
            target.header.adapterId = path.targetInfo.adapterId;
            target.header.id = path.targetInfo.id;
            if (DisplayConfigGetDeviceInfo(&target.header) != ERROR_SUCCESS)
            {
                partialFailure = true;
                continue;
            }

            ActiveTarget item;
            item.logicalTargetId = LuidText(path.targetInfo.adapterId) + L":" + std::to_wstring(path.targetInfo.id);
            item.gdiName = source.viewGdiDeviceName;
            item.monitorDevicePath = target.monitorDevicePath;
            item.friendlyName = target.monitorFriendlyDeviceName;
            if (item.friendlyName.empty()) item.friendlyName = L"显示器";
            if (std::none_of(targets.begin(), targets.end(), [&](auto const& value)
                { return EqualInsensitive(value.logicalTargetId, item.logicalTargetId); }))
                targets.push_back(std::move(item));
        }
        return true;
    }

    struct LogicalMonitor
    {
        HMONITOR handle{};
        std::wstring gdiName;
        std::wstring friendlyName;
        std::vector<std::wstring> legacyIds;
    };

    std::vector<LogicalMonitor> EnumerateLogicalMonitors(bool& partialFailure, bool& remoteTargetDetected)
    {
        std::vector<LogicalMonitor> result;
        struct CallbackState
        {
            std::vector<LogicalMonitor>* monitors;
            bool* partialFailure;
            bool* remoteTargetDetected;
        } state{ &result, &partialFailure, &remoteTargetDetected };
        if (!EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR monitor, HDC, LPRECT, LPARAM parameter) -> BOOL
        {
            auto& callbackState = *reinterpret_cast<CallbackState*>(parameter);
            MONITORINFOEXW monitorInfo{ sizeof(monitorInfo) };
            if (!GetMonitorInfoW(monitor, &monitorInfo)) { *callbackState.partialFailure = true; return TRUE; }
            DISPLAY_DEVICEW device{ sizeof(device) };
            if (!EnumDisplayDevicesW(monitorInfo.szDevice, 0, &device, EDD_GET_DEVICE_INTERFACE_NAME))
            { *callbackState.partialFailure = true; return TRUE; }
            if (IsRemoteOrMirroringDisplayDevice(device.StateFlags))
            {
                *callbackState.remoteTargetDetected = *callbackState.remoteTargetDetected
                    || ((device.StateFlags & DISPLAY_DEVICE_REMOTE) != 0);
                return TRUE;
            }
            LogicalMonitor item;
            item.handle = monitor;
            item.gdiName = monitorInfo.szDevice;
            item.friendlyName = device.DeviceString[0] ? device.DeviceString : monitorInfo.szDevice;
            if (device.DeviceID[0]) item.legacyIds.push_back(device.DeviceID);
            if (device.DeviceKey[0]) item.legacyIds.push_back(device.DeviceKey);
            callbackState.monitors->push_back(std::move(item));
            return TRUE;
        }, reinterpret_cast<LPARAM>(&state))) partialFailure = true;
        return result;
    }

    struct NativeMonitor
    {
        DdcMonitorInfo info;
        NativeMonitorHandleLease handles{ [](HANDLE handle) { DestroyPhysicalMonitor(handle); } };
    };

    struct NativeEnumeration
    {
        bool success{ true };
        bool partialFailure{};
        DWORD error{};
        DisplayTopologyTrust topologyTrust{ DisplayTopologyTrust::IncompleteOrUnavailable };
        std::vector<NativeMonitor> monitors;
        std::wstring fingerprint;
    };

    std::mutex nativeDdcMutex;

    NativeEnumeration EnumerateNativeMonitors()
    {
        NativeEnumeration result;
        if (IsRemoteDisplaySession(CurrentDisplaySessionProbe()))
        {
            result.topologyTrust = DisplayTopologyTrust::RemoteSessionLimited;
            result.fingerprint = L"remote-session-limited";
            return result;
        }
        std::vector<ActiveTarget> targets;
        bool remoteTargetDetected{};
        if (!QueryActiveTargets(targets, result.error, result.partialFailure, remoteTargetDetected))
        {
            result.topologyTrust = ClassifyDisplayTopology(false, result.error, result.partialFailure, 0);
            result.success = result.topologyTrust == DisplayTopologyTrust::RemoteSessionLimited;
            return result;
        }
        if (remoteTargetDetected)
        {
            result.topologyTrust = DisplayTopologyTrust::RemoteSessionLimited;
            result.fingerprint = L"remote-session-limited";
            return result;
        }
        auto logical = EnumerateLogicalMonitors(result.partialFailure, remoteTargetDetected);
        if (remoteTargetDetected)
        {
            result.topologyTrust = DisplayTopologyTrust::RemoteSessionLimited;
            result.fingerprint = L"remote-session-limited";
            return result;
        }

        for (auto const& target : targets)
        {
            NativeMonitor item;
            item.info.logicalTargetId = target.logicalTargetId;
            item.info.gdiName = target.gdiName;
            item.info.displayName = target.friendlyName;
            item.info.legacyIds.push_back(target.monitorDevicePath);
            auto identity = ReadInterfaceIdentity(target.monitorDevicePath);
            item.info.id = std::move(identity.strongId);
            item.info.legacyIds.insert(item.info.legacyIds.end(), identity.legacyIds.begin(), identity.legacyIds.end());

            auto current = std::find_if(logical.begin(), logical.end(), [&](auto const& value)
                { return EqualInsensitive(value.gdiName, target.gdiName); });
            if (current == logical.end())
            {
                result.partialFailure = true;
                item.info.physicalHandleCount = 0;
                item.info.ambiguous = true;
                result.monitors.push_back(std::move(item));
                continue;
            }
            item.info.legacyIds.insert(item.info.legacyIds.end(), current->legacyIds.begin(), current->legacyIds.end());
            if ((item.info.displayName.empty() || EqualInsensitive(item.info.displayName, L"Generic PnP Monitor"))
                && !current->friendlyName.empty()) item.info.displayName = current->friendlyName;

            DWORD count{};
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(current->handle, &count))
            {
                result.partialFailure = true;
                item.info.physicalHandleCount = 0;
                item.info.ambiguous = true;
                result.monitors.push_back(std::move(item));
                continue;
            }
            if (count)
            {
                std::vector<PHYSICAL_MONITOR> physical(count);
                if (!GetPhysicalMonitorsFromHMONITOR(current->handle, count, physical.data()))
                {
                    result.partialFailure = true;
                    item.info.physicalHandleCount = 0;
                }
                else for (auto const& physicalMonitor : physical) item.handles.Add(physicalMonitor.hPhysicalMonitor);
            }
            item.info.physicalHandleCount = item.handles.Handles().size();
            item.info.ambiguous = item.info.id.empty() || item.info.physicalHandleCount != 1;
            result.monitors.push_back(std::move(item));
        }

        for (auto& monitor : result.monitors)
            if (!monitor.info.id.empty() && std::count_if(result.monitors.begin(), result.monitors.end(), [&](auto const& other)
                { return EqualInsensitive(other.info.id, monitor.info.id); }) != 1)
                monitor.info.ambiguous = true;

        std::vector<std::wstring> fingerprintItems;
        for (auto const& monitor : result.monitors)
            fingerprintItems.push_back(monitor.info.logicalTargetId + L"|" + monitor.info.id + L"|"
                + std::to_wstring(monitor.info.physicalHandleCount) + L"|" + (monitor.info.ambiguous ? L"1" : L"0"));
        std::sort(fingerprintItems.begin(), fingerprintItems.end());
        for (auto const& value : fingerprintItems) result.fingerprint += value + L"\n";
        result.topologyTrust = ClassifyDisplayTopology(false, result.error,
            result.partialFailure, result.monitors.size());
        return result;
    }

    std::vector<DdcMonitorInfo> PublicMonitorInfo(NativeEnumeration const& native, uint64_t generation)
    {
        std::vector<DdcMonitorInfo> result;
        for (auto const& monitor : native.monitors)
        {
            auto info = monitor.info;
            info.topologyGeneration = generation;
            result.push_back(std::move(info));
        }
        return NormalizeDdcMonitorCollection(std::move(result));
    }

    struct NativeMonitorSession
    {
        std::atomic<uint64_t> generation{ 1 };
        std::atomic<DisplayTopologyTrust> topologyTrust{ DisplayTopologyTrust::IncompleteOrUnavailable };
        std::optional<NativeEnumeration> cached;
    };

    uint64_t SessionGeneration(NativeMonitorSession const& session) noexcept
    {
        return session.generation.load(std::memory_order_acquire);
    }

    NativeEnumeration& RefreshLocked(NativeMonitorSession& session, bool force)
    {
        auto remoteSession = IsRemoteDisplaySession(CurrentDisplaySessionProbe());
        if (!force && session.cached && session.cached->success
            && ((remoteSession && session.cached->topologyTrust == DisplayTopologyTrust::RemoteSessionLimited)
                || (!remoteSession && session.cached->topologyTrust == DisplayTopologyTrust::LocalPhysicalAuthoritative)))
            return *session.cached;
        auto current = EnumerateNativeMonitors();
        if (session.cached && session.cached->success && current.success
            && session.cached->topologyTrust == current.topologyTrust
            && session.cached->fingerprint == current.fingerprint)
            return *session.cached;
        session.generation.fetch_add(1, std::memory_order_acq_rel);
        session.cached = std::move(current);
        session.topologyTrust.store(session.cached->topologyTrust, std::memory_order_release);
        return *session.cached;
    }

    void InvalidateLocked(NativeMonitorSession& session)
    {
        session.generation.fetch_add(1, std::memory_order_acq_rel);
        session.topologyTrust.store(DisplayTopologyTrust::IncompleteOrUnavailable, std::memory_order_release);
        session.cached.reset();
    }

    NativeMonitor* ResolveLocked(NativeEnumeration& native, std::wstring const& monitorId,
        DdcErrorKind& error, std::wstring& message)
    {
        if (native.topologyTrust != DisplayTopologyTrust::LocalPhysicalAuthoritative)
        {
            error = DdcErrorKind::BackendUnavailable;
            message = native.topologyTrust == DisplayTopologyTrust::RemoteSessionLimited
                ? L"远程桌面会话中，已保留本地物理显示器配置，返回本地后重新检测"
                : L"Windows 当前显示拓扑不完整或不可用";
            return nullptr;
        }
        std::vector<NativeMonitor*> matches;
        for (auto& monitor : native.monitors)
            if (EqualInsensitive(monitor.info.id, monitorId)) matches.push_back(&monitor);
        if (matches.size() != 1 || matches.front()->info.ambiguous
            || matches.front()->handles.Handles().size() != 1)
        {
            error = matches.empty() ? DdcErrorKind::MonitorUnavailable : DdcErrorKind::AmbiguousMonitor;
            message = matches.empty() ? L"已绑定显示器当前未连接"
                : L"当前逻辑显示目标无法唯一解析到一个物理 DDC 句柄";
            return nullptr;
        }
        return matches.front();
    }

    class NativeDdcBackend final : public IDdcBackend
    {
    public:
        explicit NativeDdcBackend(std::shared_ptr<NativeMonitorSession> session) : session_(std::move(session)) {}
        std::wstring Key() const override { return NativeDdcBackendKey; }
        std::wstring DisplayName() const override { return L"Windows 原生 DDC/CI"; }
        DdcBackendStatus Status() const override { return { DdcAvailability::Available, L"Windows 物理显示器 DDC/CI" }; }
        uint64_t TopologyGeneration() const noexcept override { return SessionGeneration(*session_); }
        DisplayTopologyTrust TopologyTrust() const noexcept override
        { return session_->topologyTrust.load(std::memory_order_acquire); }

        void InvalidateTopology() noexcept override
        {
            std::scoped_lock lock(nativeDdcMutex);
            InvalidateLocked(*session_);
        }

        DdcEnumerationResult Enumerate(DdcCancellationToken const& cancellation) override
        {
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"操作已取消", {}, false };
            std::scoped_lock lock(nativeDdcMutex);
            auto& native = ::RefreshLocked(*session_, true);
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"操作已取消", {}, false };
            if (native.topologyTrust == DisplayTopologyTrust::RemoteSessionLimited)
                return { true, DdcErrorKind::None,
                    L"远程桌面会话中，已保留本地物理显示器配置，返回本地后重新检测",
                    {}, false, DisplayTopologyTrust::RemoteSessionLimited };
            if (!native.success || (native.partialFailure && native.monitors.empty()))
                return { false, DdcErrorKind::BackendUnavailable,
                    L"Windows 当前显示拓扑枚举失败，错误 " + std::to_wstring(native.error), {}, false,
                    DisplayTopologyTrust::IncompleteOrUnavailable };
            auto monitors = PublicMonitorInfo(native, TopologyGeneration());
            return { true, DdcErrorKind::None,
                native.partialFailure ? L"部分显示目标无法完整解析；已阻止不明确的 DDC 操作" : L"",
                std::move(monitors), native.topologyTrust == DisplayTopologyTrust::LocalPhysicalAuthoritative,
                native.topologyTrust };
        }

        DdcCapabilities Capabilities(std::wstring const& monitorId,
            DdcCancellationToken const& cancellation) override
        {
            if (cancellation.IsCanceled())
                return { { DdcAvailability::TemporarilyUnavailable, L"操作已取消" }, true, {}, {} };
            std::scoped_lock lock(nativeDdcMutex);
            auto& native = ::RefreshLocked(*session_, false);
            DdcErrorKind error{}; std::wstring message;
            auto monitor = ::ResolveLocked(native, monitorId, error, message);
            if (!monitor) return { { DdcAvailability::TemporarilyUnavailable, std::move(message) }, true, {}, {} };
            return { { DdcAvailability::Available, L"原生硬件 DDC/CI 可用" }, false, {}, {} };
        }

        DdcValueResult Read(std::wstring const& monitorId, DdcVcpCode code,
            DdcCancellationToken const& cancellation) override
        {
            if (!IsDdcControlVcpCode(code))
                return { false, 0, 0, DdcErrorKind::Unsupported, L"普通 DDC 控制不支持该 VCP 项" };
            if (cancellation.IsCanceled()) return { false, 0, 0, DdcErrorKind::Canceled, L"操作已取消" };
            std::scoped_lock lock(nativeDdcMutex);
            auto& native = ::RefreshLocked(*session_, false);
            auto operationGeneration = TopologyGeneration();
            DdcErrorKind error{}; std::wstring message;
            auto monitor = ::ResolveLocked(native, monitorId, error, message);
            if (!monitor) return { false, 0, 0, error, std::move(message) };
            DWORD current{}, maximum{}; MC_VCP_CODE_TYPE type{}; SetLastError(ERROR_SUCCESS);
            auto success = GetVCPFeatureAndVCPFeatureReply(monitor->handles.Handles().front(),
                static_cast<BYTE>(code), &type, &current, &maximum) != FALSE;
            auto nativeError = GetLastError();
            if (cancellation.IsCanceled()) return { false, 0, 0, DdcErrorKind::Canceled, L"操作已取消" };
            if (operationGeneration != TopologyGeneration())
                return { false, 0, 0, DdcErrorKind::TopologyChanged, L"显示拓扑已变化，旧句柄结果已丢弃" };
            if (!success)
            {
                ::InvalidateLocked(*session_);
                return { false, 0, 0, DdcErrorKind::ReadFailed,
                    L"原生硬件 DDC/CI 读取失败，错误 " + std::to_wstring(nativeError) };
            }
            return { true, static_cast<int>(current), static_cast<int>(maximum), DdcErrorKind::None, {}, operationGeneration };
        }

        DdcWriteResult Write(std::wstring const& monitorId, DdcVcpCode code, int value,
            DdcCancellationToken const& cancellation) override
        {
            if (!IsDdcControlVcpCode(code))
                return { false, DdcErrorKind::Unsupported, L"普通 DDC 控制不支持该 VCP 项" };
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"操作已取消" };
            std::scoped_lock lock(nativeDdcMutex);
            auto& native = ::RefreshLocked(*session_, false);
            auto operationGeneration = TopologyGeneration();
            DdcErrorKind error{}; std::wstring message;
            auto monitor = ::ResolveLocked(native, monitorId, error, message);
            if (!monitor) return { false, error, std::move(message) };
            SetLastError(ERROR_SUCCESS);
            auto success = SetVCPFeature(monitor->handles.Handles().front(),
                static_cast<BYTE>(code), static_cast<DWORD>(value)) != FALSE;
            auto nativeError = GetLastError();
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"操作已取消" };
            if (operationGeneration != TopologyGeneration())
                return { false, DdcErrorKind::TopologyChanged, L"显示拓扑已变化，旧句柄结果已丢弃" };
            if (!success)
            {
                ::InvalidateLocked(*session_);
                return { false, DdcErrorKind::WriteFailed,
                    L"原生硬件 DDC/CI 写入失败，错误 " + std::to_wstring(nativeError) };
            }
            return { true, DdcErrorKind::None, {}, operationGeneration };
        }

    private:
        std::shared_ptr<NativeMonitorSession> session_;
    };

    class NativeInputSourceTransport final : public IInputSourceTransport
    {
    public:
        explicit NativeInputSourceTransport(std::shared_ptr<NativeMonitorSession> session) : session_(std::move(session)) {}

        DdcBackendStatus Status() const override
        {
            return { DdcAvailability::Available, L"Windows 原生输入源传输" };
        }

        uint64_t TopologyGeneration() const noexcept override { return SessionGeneration(*session_); }
        DisplayTopologyTrust TopologyTrust() const noexcept override
        { return session_->topologyTrust.load(std::memory_order_acquire); }

        void InvalidateTopology() noexcept override
        {
            std::scoped_lock lock(nativeDdcMutex);
            InvalidateLocked(*session_);
        }

        InputSourceWriteResult WriteInputSource(std::wstring const& monitorId, int value,
            DdcCancellationToken const& cancellation) override
        {
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"操作已取消" };
            if (!IsValidNativeInputSourceValue(value))
                return { false, DdcErrorKind::InvalidValue, L"输入源值超出有效范围" };
            std::scoped_lock lock(nativeDdcMutex);
            auto& native = RefreshLocked(*session_, false);
            auto operationGeneration = TopologyGeneration();
            DdcErrorKind error{};
            std::wstring message;
            auto monitor = ResolveLocked(native, monitorId, error, message);
            if (!monitor) return { false, error, std::move(message) };
            constexpr BYTE InputSourceVcpCode = 0x60;
            SetLastError(ERROR_SUCCESS);
            auto success = SetVCPFeature(monitor->handles.Handles().front(),
                InputSourceVcpCode, static_cast<DWORD>(value)) != FALSE;
            auto nativeError = GetLastError();
            if (cancellation.IsCanceled()) return { false, DdcErrorKind::Canceled, L"操作已取消" };
            if (operationGeneration != TopologyGeneration())
                return { false, DdcErrorKind::TopologyChanged, L"显示拓扑已变化，旧句柄结果已丢弃" };
            if (!success)
            {
                InvalidateLocked(*session_);
                return { false, DdcErrorKind::WriteFailed,
                    L"原生硬件输入源写入失败，错误 " + std::to_wstring(nativeError) };
            }
            return { true, DdcErrorKind::None, {}, operationGeneration };
        }

    private:
        std::shared_ptr<NativeMonitorSession> session_;
    };
}

namespace DisplaySwitcher::Native
{
    bool IsValidNativeInputSourceValue(int value) noexcept
    {
        return IsValidInputSourceValue(value);
    }

    DdcBackendSet::DdcBackendSet()
    {
        auto session = std::make_shared<NativeMonitorSession>();
        native_ = std::make_unique<NativeDdcBackend>(session);
        inputSource_ = std::make_unique<NativeInputSourceTransport>(std::move(session));
    }

    IDdcBackend* DdcBackendSet::Lookup(std::wstring const& key) const noexcept
    {
        return key == NativeDdcBackendKey ? native_.get() : nullptr;
    }

    IInputSourceTransport* DdcBackendSet::InputSource() const noexcept
    {
        return inputSource_.get();
    }

    void DdcBackendSet::InvalidateTopology() noexcept
    {
        if (native_) native_->InvalidateTopology();
    }

    uint64_t DdcBackendSet::TopologyGeneration() const noexcept
    {
        return native_ ? native_->TopologyGeneration() : 0;
    }
}
