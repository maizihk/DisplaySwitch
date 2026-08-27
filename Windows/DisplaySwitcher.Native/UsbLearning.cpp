#include "pch.h"
#include "UsbLearning.h"

namespace DisplaySwitcher::Native
{
    bool UsbLearningSession::SameReference(std::wstring const& left, std::wstring const& right) noexcept
    {
        return _wcsicmp(left.c_str(), right.c_str()) == 0;
    }

    uint64_t UsbLearningSession::Start(std::wstring profileId,
        std::vector<UsbLearningDevice> const& baseline, int64_t nowMilliseconds)
    {
        ++generation_;
        if (!generation_) ++generation_;
        active_ = !profileId.empty();
        profileId_ = std::move(profileId);
        deadlineMilliseconds_ = nowMilliseconds + LearningWindowMilliseconds;
        baselineReferences_.clear();
        candidates_.clear();
        for (auto const& device : baseline)
        {
            if (device.localReference.empty()) continue;
            if (std::none_of(baselineReferences_.begin(), baselineReferences_.end(), [&](auto const& value)
                { return SameReference(value, device.localReference); }))
                baselineReferences_.push_back(device.localReference);
        }
        return generation_;
    }

    void UsbLearningSession::Observe(uint64_t generation, std::vector<UsbLearningDevice> const& devices,
        int64_t nowMilliseconds, bool profileStillExists)
    {
        if (!active_ || generation != generation_) return;
        if (!profileStillExists || nowMilliseconds >= deadlineMilliseconds_)
        {
            Finish();
            return;
        }
        for (auto const& device : devices)
        {
            if (device.localReference.empty()) continue;
            auto existedAtStart = std::any_of(baselineReferences_.begin(), baselineReferences_.end(), [&](auto const& value)
                { return SameReference(value, device.localReference); });
            auto alreadyCandidate = std::any_of(candidates_.begin(), candidates_.end(), [&](auto const& value)
                { return SameReference(value.localReference, device.localReference); });
            if (!existedAtStart && !alreadyCandidate) candidates_.push_back(device);
        }
    }

    std::optional<UsbLearningDevice> UsbLearningSession::Confirm(uint64_t generation,
        std::wstring const& localReference, int64_t nowMilliseconds, bool profileStillExists)
    {
        if (!active_ || generation != generation_ || !profileStillExists || nowMilliseconds >= deadlineMilliseconds_)
        {
            if (generation == generation_) Finish();
            return std::nullopt;
        }
        auto found = std::find_if(candidates_.begin(), candidates_.end(), [&](auto const& candidate)
            { return SameReference(candidate.localReference, localReference); });
        if (found == candidates_.end()) return std::nullopt;
        auto result = *found;
        Finish();
        return result;
    }

    void UsbLearningSession::Cancel(uint64_t generation) noexcept
    {
        if (active_ && generation == generation_) Finish();
    }

    void UsbLearningSession::Finish() noexcept
    {
        active_ = false;
        profileId_.clear();
        baselineReferences_.clear();
        candidates_.clear();
    }
}
