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

    struct SettingsProfileNameLayoutContract
    {
        bool inputUsesStarWidth{ true };
        bool enabledToggleUsesAutoWidth{ true };
        bool hasFlexibleSpacer{};
    };

    inline SettingsProfileNameLayoutContract ProfileNameLayoutContract()
    {
        return {};
    }

    struct SettingsStatusPlacementContract
    {
        bool outsideScrollViewer{ true };
        bool leftAligned{ true };
    };

    inline SettingsStatusPlacementContract StatusPlacementContract()
    {
        return {};
    }

    struct UsbDeviceRowContract
    {
        bool containsStatus{};
        int statusParentCount{ 1 };
    };

    inline UsbDeviceRowContract UsbDeviceRowLayoutContract()
    {
        return {};
    }
}
