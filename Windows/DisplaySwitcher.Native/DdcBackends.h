#pragma once

#include "InputSourceControl.h"

namespace DisplaySwitcher::Native
{
    struct DisplaySessionProbe
    {
        bool remoteSessionMetric{};
        std::optional<uint32_t> currentSessionId;
        std::optional<uint32_t> glassSessionId;
    };

    bool IsRemoteDisplaySession(DisplaySessionProbe const& probe) noexcept;
    bool IsRemoteOrMirroringDisplayDevice(uint32_t stateFlags) noexcept;
    DisplayTopologyTrust ClassifyDisplayTopology(bool remoteSession, uint32_t queryError,
        bool partialFailure, size_t localPhysicalTargetCount) noexcept;
    bool IsValidNativeInputSourceValue(int value) noexcept;

    class NativeMonitorHandleLease final
    {
    public:
        using Releaser = std::function<void(HANDLE)>;

        explicit NativeMonitorHandleLease(Releaser releaser = {}) : releaser_(std::move(releaser)) {}
        ~NativeMonitorHandleLease() { Release(); }
        NativeMonitorHandleLease(NativeMonitorHandleLease const&) = delete;
        NativeMonitorHandleLease& operator=(NativeMonitorHandleLease const&) = delete;
        NativeMonitorHandleLease(NativeMonitorHandleLease&& other) noexcept :
            handles_(std::move(other.handles_)), releaser_(std::move(other.releaser_)) { other.handles_.clear(); }
        NativeMonitorHandleLease& operator=(NativeMonitorHandleLease&& other) noexcept
        {
            if (this != &other)
            {
                Release(); handles_ = std::move(other.handles_); releaser_ = std::move(other.releaser_);
                other.handles_.clear();
            }
            return *this;
        }
        void Add(HANDLE handle)
        {
            if (handle && std::find(handles_.begin(), handles_.end(), handle) == handles_.end()) handles_.push_back(handle);
        }
        std::vector<HANDLE> const& Handles() const noexcept { return handles_; }
        void Release() noexcept
        {
            if (releaser_) for (auto handle : handles_) try { releaser_(handle); } catch (...) {}
            handles_.clear();
        }

    private:
        std::vector<HANDLE> handles_;
        Releaser releaser_;
    };

    class DdcBackendSet final
    {
    public:
        DdcBackendSet();
        IDdcBackend* Lookup(std::wstring const& key) const noexcept;
        IInputSourceTransport* InputSource() const noexcept;
        void InvalidateTopology() noexcept;
        uint64_t TopologyGeneration() const noexcept;

    private:
        std::unique_ptr<IDdcBackend> native_;
        std::unique_ptr<IInputSourceTransport> inputSource_;
    };
}
