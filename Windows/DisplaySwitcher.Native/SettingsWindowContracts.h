#pragma once

#include <algorithm>
#include <cstdint>
#include <cwctype>
#include <optional>
#include <string>
#include <vector>

namespace DisplaySwitcher::Native
{
    struct SettingsSectionContract
    {
        std::wstring title;
        std::vector<std::wstring> rows;
    };

    struct SettingsCardContract
    {
        std::wstring title;
        std::vector<SettingsSectionContract> sections;
        bool hasNestedCards{};
    };

    struct SettingsPageContract
    {
        std::vector<SettingsCardContract> cards;
    };

    enum class SettingsSaveFeedbackScope
    {
        None,
        Usb,
        Collaboration,
    };

    enum class SettingsPage
    {
        General,
        Usb,
        Collaboration,
        Displays,
        Diagnostics,
        About,
    };

    enum class SettingsSaveFeedbackAction
    {
        None,
        ShowScopedFeedback,
        ShowOperationFailure,
    };

    enum class InputSourceTextStatus
    {
        Empty,
        Valid,
        Invalid,
    };

    struct InputSourceTextResult
    {
        InputSourceTextStatus status{ InputSourceTextStatus::Empty };
        std::optional<int> value;
    };

    inline InputSourceTextResult ParseInputSourceText(std::wstring text)
    {
        auto whitespace = [](wchar_t value) { return iswspace(value) != 0; };
        text.erase(text.begin(), std::find_if_not(text.begin(), text.end(), whitespace));
        text.erase(std::find_if_not(text.rbegin(), text.rend(), whitespace).base(), text.end());
        if (text.empty()) return {};
        int value{};
        for (auto character : text)
        {
            if (character < L'0' || character > L'9') return { InputSourceTextStatus::Invalid, std::nullopt };
            auto digit = character - L'0';
            if (value > (65535 - digit) / 10) return { InputSourceTextStatus::Invalid, std::nullopt };
            value = value * 10 + digit;
        }
        if (value < 1 || value > 65535) return { InputSourceTextStatus::Invalid, std::nullopt };
        return { InputSourceTextStatus::Valid, value };
    }

    inline std::wstring FormatInputSourceText(std::optional<int> value)
    {
        return value && *value >= 1 && *value <= 65535 ? std::to_wstring(*value) : L"";
    }

    enum class SettingsOperationFeedbackSeverity
    {
        Informational,
        Success,
        Cancelled,
        Failure,
    };

    enum class UsbLearningCompletion
    {
        None,
        Success,
        Cancelled,
        TimedOut,
        Invalidated,
        Failure,
    };

    inline SettingsOperationFeedbackSeverity NetworkAccessFeedbackSeverity(bool ready)
    {
        return ready ? SettingsOperationFeedbackSeverity::Success : SettingsOperationFeedbackSeverity::Failure;
    }

    inline SettingsOperationFeedbackSeverity UsbLearningFeedbackSeverity(UsbLearningCompletion completion)
    {
        switch (completion)
        {
        case UsbLearningCompletion::Success: return SettingsOperationFeedbackSeverity::Success;
        case UsbLearningCompletion::Cancelled: return SettingsOperationFeedbackSeverity::Cancelled;
        case UsbLearningCompletion::None: return SettingsOperationFeedbackSeverity::Informational;
        default: return SettingsOperationFeedbackSeverity::Failure;
        }
    }

    struct SettingsSaveFeedback
    {
        std::wstring message;
        bool visible{};
        bool failure{};
        int64_t visibleUntilMs{ -1 };

        static constexpr int64_t SuccessDisplayDurationMs = 2000;

        void RecordSuccess(SettingsSaveFeedbackScope scope, std::wstring const& text, int64_t nowMs)
        {
            if (scope == SettingsSaveFeedbackScope::None) return;
            message = text;
            visible = true;
            failure = false;
            visibleUntilMs = nowMs + SuccessDisplayDurationMs;
        }

        void RecordFailure(SettingsSaveFeedbackScope scope, std::wstring const& text)
        {
            if (scope == SettingsSaveFeedbackScope::None) return;
            message = text;
            visible = true;
            failure = true;
            visibleUntilMs = -1;
        }

        void HideIfExpired(int64_t nowMs)
        {
            if (!visible || failure) return;
            if (visibleUntilMs >= 0 && nowMs >= visibleUntilMs) visible = false;
        }

        void Clear()
        {
            visible = false;
            visibleUntilMs = -1;
            message.clear();
            failure = false;
        }

        void ClearTransientSuccess()
        {
            if (visible && !failure) Clear();
        }
    };

    // Production routing boundary between a settings save and its presentation.
    // It has no WinUI dependency, so tests exercise the same scope and timeout logic.
    struct SettingsSaveFeedbackController
    {
        SettingsSaveFeedback usbFeedback;
        SettingsSaveFeedback collaborationFeedback;

        SettingsSaveFeedback& FeedbackFor(SettingsSaveFeedbackScope scope)
        {
            return scope == SettingsSaveFeedbackScope::Usb ? usbFeedback : collaborationFeedback;
        }

        SettingsSaveFeedback const& FeedbackFor(SettingsSaveFeedbackScope scope) const
        {
            return scope == SettingsSaveFeedbackScope::Usb ? usbFeedback : collaborationFeedback;
        }

        SettingsSaveFeedbackAction RecordSaveResult(SettingsSaveFeedbackScope scope, bool changed,
            bool succeeded, std::wstring const& message, int64_t nowMs)
        {
            if (!changed) return SettingsSaveFeedbackAction::None;
            if (scope == SettingsSaveFeedbackScope::None)
                return succeeded ? SettingsSaveFeedbackAction::None : SettingsSaveFeedbackAction::ShowOperationFailure;
            if (succeeded)
            {
                FeedbackFor(scope).RecordSuccess(scope, message, nowMs);
                return SettingsSaveFeedbackAction::ShowScopedFeedback;
            }
            FeedbackFor(scope).RecordFailure(scope, message);
            return SettingsSaveFeedbackAction::ShowScopedFeedback;
        }

        bool IsVisibleOn(SettingsPage page, int64_t nowMs)
        {
            auto scope = page == SettingsPage::Usb ? SettingsSaveFeedbackScope::Usb :
                (page == SettingsPage::Collaboration ? SettingsSaveFeedbackScope::Collaboration : SettingsSaveFeedbackScope::None);
            if (scope == SettingsSaveFeedbackScope::None) return false;
            auto& feedback = FeedbackFor(scope);
            feedback.HideIfExpired(nowMs);
            return feedback.visible;
        }

        SettingsSaveFeedback const* VisibleFeedback(SettingsPage page, int64_t nowMs)
        {
            if (!IsVisibleOn(page, nowMs)) return nullptr;
            return &FeedbackFor(page == SettingsPage::Usb ? SettingsSaveFeedbackScope::Usb : SettingsSaveFeedbackScope::Collaboration);
        }

        void ClearTransientSuccess(SettingsSaveFeedbackScope scope)
        {
            if (scope != SettingsSaveFeedbackScope::None) FeedbackFor(scope).ClearTransientSuccess();
        }

        void ClearTransientSuccesses()
        {
            usbFeedback.ClearTransientSuccess();
            collaborationFeedback.ClearTransientSuccess();
        }

        bool HasActiveSuccess() const noexcept
        {
            return (usbFeedback.visible && !usbFeedback.failure) ||
                (collaborationFeedback.visible && !collaborationFeedback.failure);
        }
    };

    inline SettingsPageContract UsbTabLayoutContract()
    {
        return
        {
            {
                {
                    L"自动切换",
                    {
                        {
                            L"自动切换",
                            {
                                L"自动切换开关",
                                L"触发设备",
                                L"当前状态",
                                L"对端输入源显示器列表",
                            },
                        }
                    },
                },
                {
                    L"联动协同",
                    {
                        {
                            L"联动协同",
                            {
                                L"联动目标",
                                L"联动开关",
                            },
                        },
                    },
                },
            },
        };
    }

    inline SettingsPageContract PeerTabLayoutContract()
    {
        return
        {
            {
                {
                    L"协同状态",
                    {
                        {
                            L"协同状态",
                            {
                                L"当前连接/权限状态",
                                L"检查网络权限",
                                L"检测连接",
                                L"原有安全说明",
                            },
                        },
                    },
                },
                {
                    L"配置",
                    {
                        {
                            L"配置选择",
                            {
                                L"当前配置",
                                L"添加配置",
                            },
                        },
                        {
                            L"配置详情",
                            {
                                L"配置名称",
                                L"启用开关",
                                L"对端地址",
                                L"端口",
                                L"配对密码",
                                L"对端输入源显示器列表",
                                L"本机触发设备引用状态",
                                L"删除配置",
                            },
                        },
                    },
                },
            },
        };
    }

    enum class SettingsLayoutElement
    {
        UsbDeviceStatus,
        ScopedSaveFeedback,
    };

    enum class SettingsLayoutRegion
    {
        UsbCurrentStatusRow,
        FixedWindowFooter,
    };

    struct SettingsWindowLayoutPresenter
    {
        bool Attach(SettingsLayoutElement element, SettingsLayoutRegion region)
        {
            auto expected = element == SettingsLayoutElement::UsbDeviceStatus
                ? SettingsLayoutRegion::UsbCurrentStatusRow : SettingsLayoutRegion::FixedWindowFooter;
            if (region != expected) return false;
            auto& count = element == SettingsLayoutElement::UsbDeviceStatus
                ? usbDeviceStatusParentCount : scopedSaveFeedbackParentCount;
            if (count != 0) return false;
            ++count;
            return true;
        }

        void Reset()
        {
            usbDeviceStatusParentCount = 0;
            scopedSaveFeedbackParentCount = 0;
        }

        int usbDeviceStatusParentCount{};
        int scopedSaveFeedbackParentCount{};
    };

    struct PeerInputMappingLayoutModel
    {
        double labelColumnWidth{ 200 };
        double inputColumnWidth{ 120 };
        double columnSpacing{ 16 };
        double rowSpacing{ 8 };

        size_t LabelRowSpan(size_t displayCount) const noexcept
        {
            return (std::max)(size_t{ 1 }, displayCount);
        }
    };

    inline SettingsPageContract SettingsPageLayout(SettingsPage page)
    {
        switch (page)
        {
        case SettingsPage::Usb: return UsbTabLayoutContract();
        case SettingsPage::Collaboration: return PeerTabLayoutContract();
        default: return {};
        }
    }
}
