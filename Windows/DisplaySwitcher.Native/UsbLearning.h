#pragma once

namespace DisplaySwitcher::Native
{
    struct UsbLearningDevice
    {
        std::wstring localReference;
        std::wstring displayName;
        int vendorId{ -1 };
        int productId{ -1 };
    };

    class UsbLearningSession final
    {
    public:
        static constexpr int64_t LearningWindowMilliseconds = 30000;

        uint64_t Start(std::wstring profileId, std::vector<UsbLearningDevice> const& baseline, int64_t nowMilliseconds);
        void Observe(uint64_t generation, std::vector<UsbLearningDevice> const& devices,
            int64_t nowMilliseconds, bool profileStillExists);
        std::optional<UsbLearningDevice> Confirm(uint64_t generation, std::wstring const& localReference,
            int64_t nowMilliseconds, bool profileStillExists);
        void Cancel(uint64_t generation) noexcept;

        bool Active() const noexcept { return active_; }
        bool BlocksSideEffects() const noexcept { return active_; }
        uint64_t Generation() const noexcept { return generation_; }
        std::wstring const& ProfileId() const noexcept { return profileId_; }
        std::vector<UsbLearningDevice> const& Candidates() const noexcept { return candidates_; }

    private:
        void Finish() noexcept;
        static bool SameReference(std::wstring const& left, std::wstring const& right) noexcept;

        uint64_t generation_{};
        bool active_{};
        int64_t deadlineMilliseconds_{};
        std::wstring profileId_;
        std::vector<std::wstring> baselineReferences_;
        std::vector<UsbLearningDevice> candidates_;
    };
}
