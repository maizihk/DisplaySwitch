#pragma once

#include <algorithm>
#include <cstdint>
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
        ShowCollaborationFeedback,
        ShowOperationFailure,
    };

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
            if (scope != SettingsSaveFeedbackScope::Collaboration) return;
            message = text;
            visible = true;
            failure = false;
            visibleUntilMs = nowMs + SuccessDisplayDurationMs;
        }

        void RecordFailure(SettingsSaveFeedbackScope scope, std::wstring const& text)
        {
            if (scope != SettingsSaveFeedbackScope::Collaboration) return;
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
    };

    // Production routing boundary between a settings save and its presentation.
    // It has no WinUI dependency, so tests exercise the same scope and timeout logic.
    struct SettingsSaveFeedbackController
    {
        SettingsSaveFeedback feedback;
        bool successTimerActive{};

        SettingsSaveFeedbackAction RecordSaveResult(SettingsSaveFeedbackScope scope, bool changed,
            bool succeeded, std::wstring const& message, int64_t nowMs)
        {
            if (!changed) return SettingsSaveFeedbackAction::None;
            if (scope == SettingsSaveFeedbackScope::None)
                return succeeded ? SettingsSaveFeedbackAction::None : SettingsSaveFeedbackAction::ShowOperationFailure;
            if (succeeded)
            {
                feedback.RecordSuccess(scope, message, nowMs);
                successTimerActive = true;
                return SettingsSaveFeedbackAction::ShowCollaborationFeedback;
            }
            feedback.RecordFailure(scope, message);
            successTimerActive = false;
            return SettingsSaveFeedbackAction::ShowCollaborationFeedback;
        }

        bool IsVisibleOn(SettingsPage page, int64_t nowMs)
        {
            feedback.HideIfExpired(nowMs);
            if (!feedback.visible) successTimerActive = false;
            return page == SettingsPage::Collaboration && feedback.visible;
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
        CollaborationSaveFeedback,
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
                ? usbDeviceStatusParentCount : collaborationSaveFeedbackParentCount;
            if (count != 0) return false;
            ++count;
            return true;
        }

        void Reset()
        {
            usbDeviceStatusParentCount = 0;
            collaborationSaveFeedbackParentCount = 0;
        }

        int usbDeviceStatusParentCount{};
        int collaborationSaveFeedbackParentCount{};
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
