#pragma once

namespace DisplaySwitcher::Native
{
    class UsbObservationGenerationGate final
    {
    public:
        uint64_t BeginConfiguration() noexcept
        {
            return current_.fetch_add(1, std::memory_order_acq_rel) + 1;
        }
        bool Accepts(uint64_t generation) const noexcept
        {
            return generation != 0 && current_.load(std::memory_order_acquire) == generation;
        }

    private:
        std::atomic<uint64_t> current_{};
    };

    struct UsbSwitchDisplayState
    {
        std::wstring displayId;
        std::optional<int> targetInput;
        bool available{ true };
        bool switchSucceeds{ true };
    };

    struct UsbSwitchInitialState
    {
        bool enabled{};
        bool learning{};
        bool safeState{};
        std::optional<bool> baselinePresence;
        bool collaborationWakeEnabled{};
        bool collaborationProfileValid{};
        std::vector<UsbSwitchDisplayState> displayMappings;
        std::wstring bindingKey;
    };

    struct UsbSwitchAction
    {
        enum class Kind { EstablishBaseline, SwitchDisplay, WakeDisplay, SendWakeDisplay, Report };
        Kind kind{};
        std::wstring displayId;
        std::optional<int> targetInput;
        std::optional<bool> succeeded;
        std::wstring reason;
    };

    class UsbSwitchCoordinator final
    {
    public:
        static constexpr int64_t WakeCoalescingWindowMilliseconds = 2000;

        explicit UsbSwitchCoordinator(UsbSwitchInitialState initial = {});
        std::vector<UsbSwitchAction> ObserveUsb(int64_t nowMilliseconds, bool present);
        std::vector<UsbSwitchAction> ReceiveWakeDisplay(int64_t nowMilliseconds);
        void UpdateConfiguration(UsbSwitchInitialState initial) noexcept;
        void ConfigurationChanged() noexcept;

    private:
        std::vector<UsbSwitchAction> RequestWake(int64_t nowMilliseconds);
        UsbSwitchInitialState state_;
        std::optional<int64_t> lastWakeMilliseconds_;
    };
}
