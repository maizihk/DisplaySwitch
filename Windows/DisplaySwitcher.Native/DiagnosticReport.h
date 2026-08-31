#pragma once

#include "AboutInfo.h"
#include "AppConfig.h"
#include "DdcControl.h"

namespace DisplaySwitcher::Native
{
    enum class DiagnosticHeartbeatState { Never, Recent, Expired };
    enum class DiagnosticOperationKind { None, Enumerate, Read, Write, InputSource };
    enum class DiagnosticOperationState { Idle, Success, Failed, Ambiguous, Offline, Stale };

    struct DiagnosticProfileSummary
    {
        size_t anonymousIndex{};
        bool enabled{};
        bool endpointBound{};
        bool connected{};
        DiagnosticHeartbeatState heartbeat{ DiagnosticHeartbeatState::Never };
    };

    struct DiagnosticUsbSummary
    {
        bool enabled{};
        bool triggerSelected{};
        size_t mappingCount{};
        bool collaborationWakeEnabled{};
    };

    struct DiagnosticBackendSummary
    {
        DdcAvailability availability{ DdcAvailability::TemporarilyUnavailable };
        bool enumerateSupported{};
        bool readSupported{};
        bool writeSupported{};
    };

    struct DiagnosticDisplaySummary
    {
        size_t anonymousIndex{};
        DisplayBindingStatus binding{ DisplayBindingStatus::Offline };
        bool brightnessEnabled{};
        bool contrastEnabled{};
        bool volumeEnabled{};
        DiagnosticOperationKind lastKind{ DiagnosticOperationKind::None };
        DiagnosticOperationState lastState{ DiagnosticOperationState::Idle };
    };

    struct DiagnosticSnapshot
    {
        AboutInfo about;
        int schemaVersion{ CurrentAppConfigSchemaVersion };
        bool safeMode{};
        bool detailedRecordingEnabled{};
        std::vector<DiagnosticProfileSummary> profiles;
        DiagnosticUsbSummary usb;
        DiagnosticBackendSummary backend;
        std::vector<DiagnosticDisplaySummary> displays;
        std::vector<std::string> sessions;
    };

    std::wstring BuildDiagnosticPreview(DiagnosticSnapshot const& snapshot);
    std::wstring DescribeDiagnosticOperation(DiagnosticDisplaySummary const& display);
    std::wstring DescribeBasicDdcResult(DdcControlItemResult const& item, bool write);

    class IDiagnosticSnapshotProvider
    {
    public:
        virtual ~IDiagnosticSnapshotProvider() = default;
        virtual DiagnosticSnapshot ReadSnapshot() = 0;
    };

    class CallbackDiagnosticSnapshotProvider final : public IDiagnosticSnapshotProvider
    {
    public:
        explicit CallbackDiagnosticSnapshotProvider(std::function<DiagnosticSnapshot()> callback) :
            callback_(std::move(callback)) {}
        DiagnosticSnapshot ReadSnapshot() override { return callback_ ? callback_() : DiagnosticSnapshot{}; }
    private:
        std::function<DiagnosticSnapshot()> callback_;
    };

    class DiagnosticAliasRegistry final
    {
    public:
        size_t Profile(std::wstring const& stableId);
        size_t Display(std::wstring const& stableId);
    private:
        static size_t Resolve(std::map<std::wstring, size_t>& values, std::wstring const& stableId);
        std::mutex mutex_;
        std::map<std::wstring, size_t> profiles_;
        std::map<std::wstring, size_t> displays_;
    };

    class DiagnosticPreviewModel final
    {
    public:
        std::wstring Refresh(IDiagnosticSnapshotProvider& provider);
        std::wstring const& VisiblePreview() const noexcept { return preview_; }
        std::wstring CopyPayload() const { return preview_; }
    private:
        std::wstring preview_;
    };

    class DiagnosticHeartbeatTracker final
    {
    public:
        void Reconcile(std::wstring const& localEndpointId,
            std::vector<CollaborationProfile> const& profiles);
        void Observe(std::wstring const& profileId, std::wstring const& peerEndpointId,
            int64_t nowMilliseconds);
        DiagnosticHeartbeatState State(std::wstring const& profileId,
            std::wstring const& peerEndpointId, int64_t nowMilliseconds,
            int64_t recentWindowMilliseconds = 6000) const;
        void Reset();

    private:
        struct Entry
        {
            std::wstring localEndpointId;
            std::wstring peerEndpointId;
            std::wstring peerHost;
            int peerPort{};
            size_t pairingCodeFingerprint{};
            std::optional<int> peerProtocolVersion;
            int64_t lastSeenMilliseconds{};
        };
        mutable std::mutex mutex_;
        std::map<std::wstring, Entry> entries_;
    };

    class DisplayOperationTracker final
    {
    public:
        void Reconcile(std::vector<DisplayConfig> const& displays);
        void Record(std::wstring const& displayId, std::wstring const& bindingId, uint64_t topologyGeneration,
            DiagnosticOperationKind kind, DiagnosticOperationState state);
        void RecordBatch(std::vector<DisplayConfig> const& displays, DdcControlBatchResult const& result,
            DiagnosticOperationKind kind);
        std::vector<DiagnosticDisplaySummary> Snapshot(std::vector<DisplayConfig> const& displays,
            DiagnosticAliasRegistry* aliases = nullptr) const;

    private:
        struct Entry
        {
            std::wstring bindingId;
            uint64_t topologyGeneration{};
            DiagnosticOperationKind kind{ DiagnosticOperationKind::None };
            DiagnosticOperationState state{ DiagnosticOperationState::Idle };
        };
        mutable std::mutex mutex_;
        std::map<std::wstring, Entry> entries_;
    };
}
