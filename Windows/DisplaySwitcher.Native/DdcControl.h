#pragma once

#include "AppConfig.h"

namespace DisplaySwitcher::Native
{
    enum class DdcVcpCode : uint16_t
    {
        Brightness = 0x10,
        Contrast = 0x12,
        InputSource = 0x60,
        Volume = 0x62,
    };

    enum class DdcAvailability
    {
        Available,
        Unsupported,
        TemporarilyUnavailable,
    };

    enum class DdcErrorKind
    {
        None,
        Unsupported,
        BackendUnavailable,
        MonitorUnavailable,
        ReadFailed,
        WriteFailed,
        InvalidValue,
        Canceled,
    };

    struct DdcBackendStatus
    {
        DdcAvailability availability{ DdcAvailability::TemporarilyUnavailable };
        std::wstring message;
    };

    struct DdcCapabilities
    {
        DdcBackendStatus status;
        bool known{};
        std::vector<DdcVcpCode> readable;
        std::vector<DdcVcpCode> writable;

        bool CanRead(DdcVcpCode code) const noexcept;
        bool CanWrite(DdcVcpCode code) const noexcept;
    };

    struct DdcValueResult
    {
        bool success{};
        int current{};
        int maximum{};
        DdcErrorKind error{ DdcErrorKind::None };
        std::wstring message;
    };

    struct DdcWriteResult
    {
        bool success{};
        DdcErrorKind error{ DdcErrorKind::None };
        std::wstring message;
    };

    struct DdcEnumerationResult
    {
        bool success{};
        DdcErrorKind error{ DdcErrorKind::None };
        std::wstring message;
        std::vector<DdcMonitorInfo> monitors;
        bool complete{};

        bool IsTrustedNonEmptySnapshot() const noexcept
        {
            return success && complete && !monitors.empty();
        }
    };

    struct DdcCancellationState
    {
        std::atomic<uint64_t> generation{};
    };

    class DdcCancellationToken final
    {
    public:
        DdcCancellationToken() = default;
        bool IsCanceled() const noexcept;

    private:
        friend class DdcCancellationSource;
        DdcCancellationToken(std::shared_ptr<DdcCancellationState> state, uint64_t generation) noexcept :
            state_(std::move(state)), generation_(generation) {}
        std::shared_ptr<DdcCancellationState> state_;
        uint64_t generation_{};
    };

    class DdcCancellationSource final
    {
    public:
        DdcCancellationSource() : state_(std::make_shared<DdcCancellationState>()) {}
        DdcCancellationToken Begin() noexcept;
        void Cancel() noexcept;

    private:
        std::shared_ptr<DdcCancellationState> state_;
    };

    class IDdcBackend
    {
    public:
        virtual ~IDdcBackend() = default;
        virtual std::wstring Key() const = 0;
        virtual std::wstring DisplayName() const = 0;
        virtual DdcBackendStatus Status() const = 0;
        virtual DdcEnumerationResult Enumerate(DdcCancellationToken const& cancellation) = 0;
        virtual DdcCapabilities Capabilities(std::wstring const& monitorId,
            DdcCancellationToken const& cancellation) = 0;
        virtual DdcValueResult Read(std::wstring const& monitorId, DdcVcpCode code,
            DdcCancellationToken const& cancellation) = 0;
        virtual DdcWriteResult Write(std::wstring const& monitorId, DdcVcpCode code, int value,
            DdcCancellationToken const& cancellation) = 0;
    };

    using DdcBackendLookup = std::function<IDdcBackend*(std::wstring const& key)>;

    DdcWriteResult WriteNativeWithOneRefresh(IDdcBackend& backend, std::wstring const& monitorId,
        DdcVcpCode code, int value, DdcCancellationToken const& cancellation);

    struct DdcControlItemResult
    {
        std::wstring displayId;
        DdcVcpCode code{ DdcVcpCode::Brightness };
        bool success{};
        bool skipped{};
        bool trusted{};
        bool estimated{};
        std::optional<int> current;
        std::optional<int> maximum;
        DdcAvailability availability{ DdcAvailability::Available };
        DdcErrorKind error{ DdcErrorKind::None };
        std::wstring message;
    };

    struct DdcControlBatchResult
    {
        bool success{};
        bool canceled{};
        std::vector<DdcControlItemResult> items;
    };

    struct DdcTrayControl
    {
        std::wstring displayId;
        std::wstring displayName;
        DdcVcpCode code{ DdcVcpCode::Brightness };
        std::wstring label;
        int value{};
        int maximum{ 100 };
        bool hasValue{};
    };

    std::vector<DdcTrayControl> BuildDdcTrayControls(AppConfig const& config);

    struct DdcWriteRequest
    {
        std::wstring displayId;
        DdcVcpCode code{ DdcVcpCode::Brightness };
        int value{};
        uint64_t generation{};
    };

    class DdcWriteQueue final
    {
    public:
        bool Submit(DdcWriteRequest request);
        std::optional<DdcWriteRequest> TakeNext();
        void CancelPending();
        size_t PendingCount() const;

    private:
        using Key = std::pair<std::wstring, DdcVcpCode>;
        mutable std::mutex mutex_;
        std::map<Key, DdcWriteRequest> pending_;
        bool workerActive_{};
    };

    class DdcControlService final
    {
    public:
        DdcControlService(DdcBackendLookup lookup, std::function<bool()> sideEffectsAllowed = {});
        DdcControlBatchResult Read(AppConfig& config, std::vector<std::wstring> const& displayIds,
            DdcCancellationToken const& cancellation) const;
        DdcControlBatchResult Write(AppConfig& config, std::wstring const& displayId, DdcVcpCode code,
            int value, bool linkAllDisplays, DdcCancellationToken const& cancellation) const;

        static int EffectiveMaximum(int current, int reportedMaximum) noexcept;
        static bool FeatureEnabled(DisplayConfig const& display, DdcVcpCode code) noexcept;
        static std::wstring BackendKey(AppConfig const& config, DisplayConfig const& display);

    private:
        bool Allowed(AppConfig const& config, DdcCancellationToken const& cancellation) const;
        IDdcBackend* Backend(AppConfig const& config, DisplayConfig const& display) const;

        DdcBackendLookup lookup_;
        std::function<bool()> sideEffectsAllowed_;
    };
}
