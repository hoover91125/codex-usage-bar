import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .system: return "System Default"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        }
    }

    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh-hant") || preferred.hasPrefix("zh-tw") ||
            preferred.hasPrefix("zh-hk") || preferred.hasPrefix("zh-mo") {
            return .zhHant
        }
        if preferred.hasPrefix("zh") { return .zhHans }
        if preferred.hasPrefix("ja") { return .japanese }
        if preferred.hasPrefix("ko") { return .korean }
        if preferred.hasPrefix("es") { return .spanish }
        return .english
    }

    var locale: Locale {
        switch resolved {
        case .zhHans: return Locale(identifier: "zh_CN")
        case .zhHant: return Locale(identifier: "zh_TW")
        case .japanese: return Locale(identifier: "ja_JP")
        case .korean: return Locale(identifier: "ko_KR")
        case .spanish: return Locale(identifier: "es_ES")
        case .system, .english: return Locale(identifier: "en_US")
        }
    }
}

enum L10n {
    static func string(_ key: String, language: AppLanguage) -> String {
        let resolved = language.resolved
        return tables[resolved]?[key] ?? tables[.english]?[key] ?? key
    }

    static func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        String(format: string(key, language: language), locale: language.locale, arguments: arguments)
    }

    /// A compact "time left" string — "3h 12m", "4d 6h", "45m" — in
    /// `language`'s own unit abbreviations. Nil once the moment has passed, so
    /// callers fall back to the absolute time rather than printing "0m".
    /// `DateComponentsFormatter` is not used: its `.abbreviated` style spells
    /// the units out in CJK ("3小时12分钟"), which is twice the width the
    /// popover captions and the Touch Bar have to spare.
    static func formatRelative(_ date: Date, language: AppLanguage, now: Date = Date()) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let day = string("dur_day", language: language)
        let hour = string("dur_hour", language: language)
        let minute = string("dur_minute", language: language)
        let join = string("dur_join", language: language)

        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 1 { return "<1\(minute)" }
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)\(day)\(join)\(hours)\(hour)" : "\(days)\(day)"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)\(hour)\(join)\(minutes)\(minute)" : "\(hours)\(hour)"
        }
        return "\(minutes)\(minute)"
    }

    /// Locale-aware "H:mm" (or "M/d H:mm" with `includeDate`) in `language`'s
    /// locale. `UsageStore.formatDate` is the instance-level form; this one
    /// exists so the Touch Bar can size its items against every language's
    /// date shape up front, without a store.
    static func formatDate(_ date: Date, language: AppLanguage, includeDate: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.setLocalizedDateFormatFromTemplate(includeDate ? "MdHm" : "Hm")
        return formatter.string(from: date)
    }

    private static let tables: [AppLanguage: [String: String]] = [
        .zhHans: [
            "system_default": "跟随系统", "settings": "设置", "quit": "退出",
            "loading_account": "正在读取账户…", "five_hour_quota": "5 小时额度", "weekly_quota": "每周额度",
            "remaining": "%d%% 剩余", "unavailable": "不可用", "reset_at": "重置：%@", "updated_at": "更新于 %@",
            "credits_unlimited": "积分无限", "credits_balance": "积分 %@", "credits_unavailable": "无积分信息",
            "reset_count": "%d 次重置", "refresh": "刷新", "official_usage": "官方 Usage",
            "section_display": "显示", "display_mode": "百分比显示", "display_mode_remaining": "剩余量", "display_mode_used": "使用量",
            "used": "已使用 %d%%", "alert_warning": "橙色警示", "alert_critical": "红色警示",
            "alert_description": "达到门槛时，菜单栏文字、菜单窗口与 Touch Bar 的百分比和进度条会依序变成橙、红。",
            "section_language": "语言", "language": "应用语言", "section_menu_bar": "菜单栏", "icon": "图标",
            "icon_size": "图标大小", "text_size": "文字字号", "section_general": "通用",
            "section_services": "服务", "service_missing_codex": "找不到 Codex CLI。",
            "service_missing_claude": "找不到 Claude Code 凭据，请先使用 Claude Code 登录。",
            "menu_bar_source": "菜单栏显示", "provider_unavailable": "未安装 %@。",
            "launch_at_login": "登录时自动启动", "touch_bar_mode": "触控栏显示",
            "touch_bar_mode_always": "始终显示", "touch_bar_mode_when_relevant": "仅在相关应用位于前台时显示",
            "touch_bar_mode_off": "关闭", "touch_bar_content": "显示内容",
            "touch_bar_content_automatic": "自动（单一服务）", "touch_bar_content_both": "同时显示 Codex 与 Claude", "touch_bar_both_compact": "精简版面（含重置时间）",
            "touch_bar_description": "显示 5 小时与每周额度、进度和重置时间。",
            "touch_bar_unavailable": "当前系统不支持前台常驻；本应用激活时仍可显示。",
            "settings_window_title": "Codex Usage Bar 设置", "five_hour_short": "5 小时", "weekly_short": "每周",
            "weekly_prefix": "周", "loading_reset": "正在读取重置时间…", "reset_customization": "Codex 重置时间",
            "refresh_usage": "刷新 Usage", "refresh_codex_usage": "刷新 Codex Usage", "show_usage_bar": "显示 Usage 条", "quota_customization": "Codex %@额度",
            "touch_bar_reset": "重置 5h %@ · 周 %@", "loading_usage": "正在读取 Usage…", "usage_unavailable": "Usage 暂不可用",
            "error_codex_not_found": "找不到 Codex CLI。请先安装或更新 ChatGPT/Codex。",
            "error_launch_failed": "无法启动 Codex：%@", "error_timeout": "读取超时，请稍后重试。",
            "error_invalid_response": "Codex 返回了无法识别的 Usage 数据。", "error_server": "Codex 返回错误：%@",
            "error_unknown": "未知错误", "error_launch_at_login": "无法更新开机启动设置：%@",
            "error_claude_credentials_not_found": "找不到 Claude 凭据。请先使用 Claude Code 登录。",
            "error_claude_token_expired": "Claude Code 登录已过期，请先打开 Claude Code 以刷新。",
            "error_claude_not_subscribed": "此 Claude 账户没有可显示的订阅 Usage。",
            "error_http_status": "Claude 返回了错误（状态码 %d）。", "error_network": "网络错误：%@", "error_rate_limited": "请求过于频繁，稍后自动重试。",
            "icon_gauge": "仪表盘", "icon_simple_gauge": "简洁仪表", "icon_speedometer": "速度表", "icon_bar_chart": "柱状图",
            "icon_trend": "趋势图", "icon_percent": "百分比", "icon_bolt": "闪电", "icon_flame": "火焰",
            "icon_sparkles": "星光", "icon_terminal": "终端", "icon_command": "Command", "icon_cpu": "处理器",
            "icon_chip": "芯片", "icon_timer": "计时器", "icon_refresh_clock": "刷新时钟", "icon_waveform": "状态波形", "icon_hidden": "隐藏图标",
            "alert_normal": "正常", "section_alerts": "警示门槛",
            "dur_day": "天", "dur_hour": "时", "dur_minute": "分", "dur_join": "",
            "reset_in": "%@后重置", "retry_after": "%@ 后重试", "section_models": "各模型每周",
            "pace_help": "进度条上的细线是按时间平均消耗应到的位置；越过它表示消耗偏快。",
            "tab_services": "服务", "tab_display": "显示", "tab_menu_bar": "菜单栏",
            "tab_touch_bar": "Touch Bar", "tab_general": "通用",
            "battery_note": "使用电池时 Claude 的刷新间隔加倍；显示器休眠时暂停刷新。",
            "threshold_preview": "预览", "menu_bar_tint": "低于门槛时为菜单栏文字着色",
            "show_pace_marker": "在进度条上显示速度参考线", "project_page": "项目页面",
            "on_battery": "电池供电"
        ],
        .zhHant: [
            "system_default": "跟隨系統", "settings": "設定", "quit": "結束",
            "loading_account": "正在讀取帳戶…", "five_hour_quota": "5 小時額度", "weekly_quota": "每週額度",
            "remaining": "剩餘 %d%%", "unavailable": "無法使用", "reset_at": "重置：%@", "updated_at": "更新於 %@",
            "credits_unlimited": "點數無限", "credits_balance": "點數 %@", "credits_unavailable": "無點數資訊",
            "reset_count": "%d 次重置", "refresh": "重新整理", "official_usage": "官方 Usage",
            "section_display": "顯示", "display_mode": "百分比顯示", "display_mode_remaining": "剩餘量", "display_mode_used": "使用量",
            "used": "已使用 %d%%", "alert_warning": "橘色警示", "alert_critical": "紅色警示",
            "alert_description": "達到門檻時，選單列文字、選單視窗與 Touch Bar 的百分比和進度條會依序變成橘、紅。",
            "section_language": "語言", "language": "應用程式語言", "section_menu_bar": "選單列", "icon": "圖示",
            "icon_size": "圖示大小", "text_size": "文字大小", "section_general": "一般",
            "section_services": "服務", "service_missing_codex": "找不到 Codex CLI。",
            "service_missing_claude": "找不到 Claude Code 憑證，請先使用 Claude Code 登入。",
            "menu_bar_source": "選單列顯示", "provider_unavailable": "未安裝 %@。",
            "launch_at_login": "登入時自動啟動", "touch_bar_mode": "觸控列顯示",
            "touch_bar_mode_always": "永遠顯示", "touch_bar_mode_when_relevant": "僅在相關應用程式位於前景時顯示",
            "touch_bar_mode_off": "關閉", "touch_bar_content": "顯示內容",
            "touch_bar_content_automatic": "自動（單一服務）", "touch_bar_content_both": "同時顯示 Codex 與 Claude", "touch_bar_both_compact": "精簡版面（含重置時間）",
            "touch_bar_description": "顯示 5 小時與每週額度、進度和重置時間。",
            "touch_bar_unavailable": "目前系統不支援前景常駐；啟用本應用程式時仍可顯示。",
            "settings_window_title": "Codex Usage Bar 設定", "five_hour_short": "5 小時", "weekly_short": "每週",
            "weekly_prefix": "週", "loading_reset": "正在讀取重置時間…", "reset_customization": "Codex 重置時間",
            "refresh_usage": "重新整理 Usage", "refresh_codex_usage": "重新整理 Codex Usage", "show_usage_bar": "顯示 Usage 列", "quota_customization": "Codex %@額度",
            "touch_bar_reset": "重置 5h %@ · 週 %@", "loading_usage": "正在讀取 Usage…", "usage_unavailable": "Usage 暫時無法使用",
            "error_codex_not_found": "找不到 Codex CLI。請先安裝或更新 ChatGPT/Codex。",
            "error_launch_failed": "無法啟動 Codex：%@", "error_timeout": "讀取逾時，請稍後再試。",
            "error_invalid_response": "Codex 傳回了無法識別的 Usage 資料。", "error_server": "Codex 傳回錯誤：%@",
            "error_unknown": "未知錯誤", "error_launch_at_login": "無法更新登入啟動設定：%@",
            "error_claude_credentials_not_found": "找不到 Claude 憑證。請先使用 Claude Code 登入。",
            "error_claude_token_expired": "Claude Code 登入已過期，請先開啟 Claude Code 以重新整理。",
            "error_claude_not_subscribed": "此 Claude 帳戶沒有可顯示的訂閱 Usage。",
            "error_http_status": "Claude 傳回了錯誤（狀態碼 %d）。", "error_network": "網路錯誤：%@", "error_rate_limited": "請求過於頻繁，稍後自動重試。",
            "icon_gauge": "儀表板", "icon_simple_gauge": "簡潔儀表", "icon_speedometer": "速度表", "icon_bar_chart": "長條圖",
            "icon_trend": "趨勢圖", "icon_percent": "百分比", "icon_bolt": "閃電", "icon_flame": "火焰",
            "icon_sparkles": "星光", "icon_terminal": "終端機", "icon_command": "Command", "icon_cpu": "處理器",
            "icon_chip": "晶片", "icon_timer": "計時器", "icon_refresh_clock": "更新時鐘", "icon_waveform": "狀態波形", "icon_hidden": "隱藏圖示",
            "alert_normal": "正常", "section_alerts": "警示門檻",
            "dur_day": "天", "dur_hour": "時", "dur_minute": "分", "dur_join": "",
            "reset_in": "%@後重置", "retry_after": "%@ 後重試", "section_models": "各模型每週",
            "pace_help": "進度條上的細線是依時間平均消耗應到的位置；越過它表示消耗偏快。",
            "tab_services": "服務", "tab_display": "顯示", "tab_menu_bar": "選單列",
            "tab_touch_bar": "Touch Bar", "tab_general": "一般",
            "battery_note": "使用電池時 Claude 的更新間隔加倍；螢幕睡眠時暫停更新。",
            "threshold_preview": "預覽", "menu_bar_tint": "低於門檻時為選單列文字著色",
            "show_pace_marker": "在進度條上顯示速度參考線", "project_page": "專案頁面",
            "on_battery": "電池供電"
        ],
        .english: [
            "system_default": "System Default", "settings": "Settings", "quit": "Quit",
            "loading_account": "Loading account…", "five_hour_quota": "5-hour limit", "weekly_quota": "Weekly limit",
            "remaining": "%d%% remaining", "unavailable": "Unavailable", "reset_at": "Resets: %@", "updated_at": "Updated %@",
            "credits_unlimited": "Unlimited credits", "credits_balance": "Credits %@", "credits_unavailable": "No credit information",
            "reset_count": "%d resets", "refresh": "Refresh", "official_usage": "Official Usage",
            "section_display": "Display", "display_mode": "Percentages show", "display_mode_remaining": "Remaining", "display_mode_used": "Used",
            "used": "%d%% used", "alert_warning": "Orange alert", "alert_critical": "Red alert",
            "alert_description": "As a window falls past each threshold its percentage and bar turn orange, then red — in the menu bar title, the menu and on the Touch Bar.",
            "section_language": "Language", "language": "App language", "section_menu_bar": "Menu Bar", "icon": "Icon",
            "icon_size": "Icon size", "text_size": "Text size", "section_general": "General",
            "section_services": "Services", "service_missing_codex": "Codex CLI not found.",
            "service_missing_claude": "No Claude Code credentials. Sign in with Claude Code first.",
            "menu_bar_source": "Menu bar shows", "provider_unavailable": "%@ isn't installed.",
            "launch_at_login": "Launch at login", "touch_bar_mode": "Touch Bar",
            "touch_bar_mode_always": "Always show", "touch_bar_mode_when_relevant": "Only when a relevant app is active",
            "touch_bar_mode_off": "Off", "touch_bar_content": "Shows",
            "touch_bar_content_automatic": "One provider (automatic)", "touch_bar_content_both": "Codex and Claude together", "touch_bar_both_compact": "Compact layout (with reset times)",
            "touch_bar_description": "Shows 5-hour and weekly limits, progress, and reset times.",
            "touch_bar_unavailable": "Persistent display is unavailable on this system; it can still appear while this app is active.",
            "settings_window_title": "Codex Usage Bar Settings", "five_hour_short": "5 hour", "weekly_short": "Weekly",
            "weekly_prefix": "Wk", "loading_reset": "Loading reset times…", "reset_customization": "Codex reset times",
            "refresh_usage": "Refresh Usage", "refresh_codex_usage": "Refresh Codex Usage", "show_usage_bar": "Show Usage Bar", "quota_customization": "Codex %@ limit",
            "touch_bar_reset": "Reset 5h %@ · Wk %@", "loading_usage": "Loading Usage…", "usage_unavailable": "Usage unavailable",
            "error_codex_not_found": "Codex CLI was not found. Install or update ChatGPT/Codex first.",
            "error_launch_failed": "Could not start Codex: %@", "error_timeout": "The request timed out. Try again later.",
            "error_invalid_response": "Codex returned unrecognized Usage data.", "error_server": "Codex returned an error: %@",
            "error_unknown": "Unknown error", "error_launch_at_login": "Could not update the launch-at-login setting: %@",
            "error_claude_credentials_not_found": "Claude credentials were not found. Sign in with Claude Code first.",
            "error_claude_token_expired": "Claude Code's login has expired. Open Claude Code once to refresh it.",
            "error_claude_not_subscribed": "This Claude account has no subscription usage to show.",
            "error_http_status": "Claude returned an error (status %d).", "error_network": "Network error: %@", "error_rate_limited": "Rate limited. Retrying automatically later.",
            "icon_gauge": "Gauge", "icon_simple_gauge": "Simple Gauge", "icon_speedometer": "Speedometer", "icon_bar_chart": "Bar Chart",
            "icon_trend": "Trend", "icon_percent": "Percentage", "icon_bolt": "Bolt", "icon_flame": "Flame",
            "icon_sparkles": "Sparkles", "icon_terminal": "Terminal", "icon_command": "Command", "icon_cpu": "Processor",
            "icon_chip": "Chip", "icon_timer": "Timer", "icon_refresh_clock": "Refresh Clock", "icon_waveform": "Status Waveform", "icon_hidden": "Hide Icon",
            "alert_normal": "Normal", "section_alerts": "Alert thresholds",
            "dur_day": "d", "dur_hour": "h", "dur_minute": "m", "dur_join": " ",
            "reset_in": "Resets in %@", "retry_after": "Retries in %@", "section_models": "Weekly by model",
            "pace_help": "The hairline on each bar marks where an even burn would be by now; past it means you are spending faster than the window refills.",
            "tab_services": "Services", "tab_display": "Display", "tab_menu_bar": "Menu Bar",
            "tab_touch_bar": "Touch Bar", "tab_general": "General",
            "battery_note": "On battery, Claude's refresh interval doubles; refreshing pauses while the display sleeps.",
            "threshold_preview": "Preview", "menu_bar_tint": "Tint the menu bar text below a threshold",
            "show_pace_marker": "Show the pace mark on progress bars", "project_page": "Project page",
            "on_battery": "On battery"
        ],
        .japanese: [
            "system_default": "システム設定に従う", "settings": "設定", "quit": "終了",
            "loading_account": "アカウントを読み込み中…", "five_hour_quota": "5時間の上限", "weekly_quota": "週間上限",
            "remaining": "残り %d%%", "unavailable": "利用不可", "reset_at": "リセット：%@", "updated_at": "更新：%@",
            "credits_unlimited": "クレジット無制限", "credits_balance": "クレジット %@", "credits_unavailable": "クレジット情報なし",
            "reset_count": "%d 回リセット", "refresh": "更新", "official_usage": "公式 Usage",
            "section_display": "表示", "display_mode": "パーセント表示", "display_mode_remaining": "残量", "display_mode_used": "使用量",
            "used": "使用済み %d%%", "alert_warning": "オレンジ警告", "alert_critical": "赤警告",
            "alert_description": "しきい値を下回るごとに、メニューバー・メニュー・Touch Bar のパーセントとバーがオレンジ・赤に変わります。",
            "section_language": "言語", "language": "アプリの言語", "section_menu_bar": "メニューバー", "icon": "アイコン",
            "icon_size": "アイコンサイズ", "text_size": "文字サイズ", "section_general": "一般",
            "section_services": "サービス", "service_missing_codex": "Codex CLI が見つかりません。",
            "service_missing_claude": "Claude Code の認証情報が見つかりません。先に Claude Code でサインインしてください。",
            "menu_bar_source": "メニューバーに表示", "provider_unavailable": "%@ はインストールされていません。",
            "launch_at_login": "ログイン時に起動", "touch_bar_mode": "Touch Bar 表示",
            "touch_bar_mode_always": "常に表示", "touch_bar_mode_when_relevant": "関連アプリが前面のときのみ表示",
            "touch_bar_mode_off": "オフ", "touch_bar_content": "表示内容",
            "touch_bar_content_automatic": "自動（1件のみ）", "touch_bar_content_both": "Codex と Claude を同時表示", "touch_bar_both_compact": "コンパクト表示（リセット時刻あり）",
            "touch_bar_description": "5時間と週間の上限、進捗、リセット時刻を表示します。",
            "touch_bar_unavailable": "このシステムでは常時表示できませんが、本アプリの使用中は表示できます。",
            "settings_window_title": "Codex Usage Bar 設定", "five_hour_short": "5時間", "weekly_short": "週間",
            "weekly_prefix": "週", "loading_reset": "リセット時刻を読み込み中…", "reset_customization": "Codex リセット時刻",
            "refresh_usage": "Usage を更新", "refresh_codex_usage": "Codex Usage を更新", "show_usage_bar": "Usage バーを表示", "quota_customization": "Codex %@上限",
            "touch_bar_reset": "リセット 5h %@・週 %@", "loading_usage": "Usage を読み込み中…", "usage_unavailable": "Usage を利用できません",
            "error_codex_not_found": "Codex CLI が見つかりません。ChatGPT/Codex をインストールまたは更新してください。",
            "error_launch_failed": "Codex を起動できません：%@", "error_timeout": "読み込みがタイムアウトしました。後でもう一度お試しください。",
            "error_invalid_response": "Codex から認識できない Usage データが返されました。", "error_server": "Codex エラー：%@",
            "error_unknown": "不明なエラー", "error_launch_at_login": "ログイン時起動の設定を更新できません：%@",
            "error_claude_credentials_not_found": "Claude の認証情報が見つかりません。先に Claude Code でサインインしてください。",
            "error_claude_token_expired": "Claude Code のログインが期限切れです。一度 Claude Code を開いて更新してください。",
            "error_claude_not_subscribed": "この Claude アカウントには表示できるサブスクリプション Usage がありません。",
            "error_http_status": "Claude がエラーを返しました（ステータス %d）。", "error_network": "ネットワークエラー：%@", "error_rate_limited": "リクエストが多すぎます。後で自動的に再試行します。",
            "icon_gauge": "ゲージ", "icon_simple_gauge": "シンプルゲージ", "icon_speedometer": "速度計", "icon_bar_chart": "棒グラフ",
            "icon_trend": "トレンド", "icon_percent": "パーセント", "icon_bolt": "稲妻", "icon_flame": "炎",
            "icon_sparkles": "きらめき", "icon_terminal": "ターミナル", "icon_command": "Command", "icon_cpu": "プロセッサ",
            "icon_chip": "チップ", "icon_timer": "タイマー", "icon_refresh_clock": "更新時計", "icon_waveform": "ステータス波形", "icon_hidden": "アイコンを非表示",
            "alert_normal": "正常", "section_alerts": "警告しきい値",
            "dur_day": "日", "dur_hour": "時間", "dur_minute": "分", "dur_join": "",
            "reset_in": "%@後にリセット", "retry_after": "%@後に再試行", "section_models": "モデル別の週間",
            "pace_help": "バー上の細い線は、均等に消費した場合の現在位置です。越えていれば消費が速いことを示します。",
            "tab_services": "サービス", "tab_display": "表示", "tab_menu_bar": "メニューバー",
            "tab_touch_bar": "Touch Bar", "tab_general": "一般",
            "battery_note": "バッテリー駆動時は Claude の更新間隔が2倍になり、ディスプレイのスリープ中は更新を停止します。",
            "threshold_preview": "プレビュー", "menu_bar_tint": "しきい値を下回るとメニューバーの文字に色を付ける",
            "show_pace_marker": "進捗バーにペースの目安線を表示", "project_page": "プロジェクトページ",
            "on_battery": "バッテリー駆動"
        ],
        .korean: [
            "system_default": "시스템 설정 따르기", "settings": "설정", "quit": "종료",
            "loading_account": "계정 불러오는 중…", "five_hour_quota": "5시간 한도", "weekly_quota": "주간 한도",
            "remaining": "%d%% 남음", "unavailable": "사용할 수 없음", "reset_at": "재설정: %@", "updated_at": "업데이트: %@",
            "credits_unlimited": "크레딧 무제한", "credits_balance": "크레딧 %@", "credits_unavailable": "크레딧 정보 없음",
            "reset_count": "%d회 재설정", "refresh": "새로 고침", "official_usage": "공식 Usage",
            "section_display": "표시", "display_mode": "퍼센트 표시", "display_mode_remaining": "남은 양", "display_mode_used": "사용량",
            "used": "%d%% 사용", "alert_warning": "주황색 경고", "alert_critical": "빨간색 경고",
            "alert_description": "임계값을 지날 때마다 메뉴 막대, 메뉴, Touch Bar의 퍼센트와 막대가 주황, 빨강으로 바뀝니다.",
            "section_language": "언어", "language": "앱 언어", "section_menu_bar": "메뉴 막대", "icon": "아이콘",
            "icon_size": "아이콘 크기", "text_size": "텍스트 크기", "section_general": "일반",
            "section_services": "서비스", "service_missing_codex": "Codex CLI를 찾을 수 없습니다.",
            "service_missing_claude": "Claude Code 자격 증명이 없습니다. 먼저 Claude Code로 로그인하세요.",
            "menu_bar_source": "메뉴 막대 표시", "provider_unavailable": "%@이(가) 설치되어 있지 않습니다.",
            "launch_at_login": "로그인 시 실행", "touch_bar_mode": "Touch Bar 표시",
            "touch_bar_mode_always": "항상 표시", "touch_bar_mode_when_relevant": "관련 앱이 활성화된 경우에만 표시",
            "touch_bar_mode_off": "끄기", "touch_bar_content": "표시 내용",
            "touch_bar_content_automatic": "자동(단일 서비스)", "touch_bar_content_both": "Codex와 Claude 동시 표시", "touch_bar_both_compact": "간결 레이아웃(재설정 시각 포함)",
            "touch_bar_description": "5시간 및 주간 한도, 진행률과 재설정 시간을 표시합니다.",
            "touch_bar_unavailable": "이 시스템에서는 상시 표시할 수 없지만 앱이 활성화된 동안에는 표시됩니다.",
            "settings_window_title": "Codex Usage Bar 설정", "five_hour_short": "5시간", "weekly_short": "주간",
            "weekly_prefix": "주", "loading_reset": "재설정 시간 불러오는 중…", "reset_customization": "Codex 재설정 시간",
            "refresh_usage": "Usage 새로 고침", "refresh_codex_usage": "Codex Usage 새로 고침", "show_usage_bar": "Usage 바 표시", "quota_customization": "Codex %@ 한도",
            "touch_bar_reset": "재설정 5h %@ · 주 %@", "loading_usage": "Usage 불러오는 중…", "usage_unavailable": "Usage 사용 불가",
            "error_codex_not_found": "Codex CLI를 찾을 수 없습니다. ChatGPT/Codex를 설치하거나 업데이트하세요.",
            "error_launch_failed": "Codex를 실행할 수 없습니다: %@", "error_timeout": "요청 시간이 초과되었습니다. 나중에 다시 시도하세요.",
            "error_invalid_response": "Codex가 인식할 수 없는 Usage 데이터를 반환했습니다.", "error_server": "Codex 오류: %@",
            "error_unknown": "알 수 없는 오류", "error_launch_at_login": "로그인 시 실행 설정을 업데이트할 수 없습니다: %@",
            "error_claude_credentials_not_found": "Claude 자격 증명을 찾을 수 없습니다. 먼저 Claude Code로 로그인하세요.",
            "error_claude_token_expired": "Claude Code 로그인이 만료되었습니다. Claude Code를 한 번 열어 갱신하세요.",
            "error_claude_not_subscribed": "이 Claude 계정에는 표시할 구독 Usage가 없습니다.",
            "error_http_status": "Claude가 오류를 반환했습니다(상태 코드 %d).", "error_network": "네트워크 오류: %@", "error_rate_limited": "요청이 너무 잦습니다. 잠시 후 자동으로 재시도합니다.",
            "icon_gauge": "게이지", "icon_simple_gauge": "간단한 게이지", "icon_speedometer": "속도계", "icon_bar_chart": "막대 차트",
            "icon_trend": "추세", "icon_percent": "백분율", "icon_bolt": "번개", "icon_flame": "불꽃",
            "icon_sparkles": "반짝임", "icon_terminal": "터미널", "icon_command": "Command", "icon_cpu": "프로세서",
            "icon_chip": "칩", "icon_timer": "타이머", "icon_refresh_clock": "새로 고침 시계", "icon_waveform": "상태 파형", "icon_hidden": "아이콘 숨기기",
            "alert_normal": "정상", "section_alerts": "경고 임계값",
            "dur_day": "일", "dur_hour": "시", "dur_minute": "분", "dur_join": " ",
            "reset_in": "%@ 후 재설정", "retry_after": "%@ 후 재시도", "section_models": "모델별 주간",
            "pace_help": "막대 위의 가는 선은 균등하게 사용했을 때의 현재 위치입니다. 이를 넘으면 소비가 빠르다는 뜻입니다.",
            "tab_services": "서비스", "tab_display": "표시", "tab_menu_bar": "메뉴 막대",
            "tab_touch_bar": "Touch Bar", "tab_general": "일반",
            "battery_note": "배터리 사용 시 Claude 새로 고침 간격이 두 배가 되고, 디스플레이가 잠자면 새로 고침을 멈춥니다.",
            "threshold_preview": "미리보기", "menu_bar_tint": "임계값 아래에서 메뉴 막대 글자에 색 입히기",
            "show_pace_marker": "진행 막대에 페이스 표시선 보기", "project_page": "프로젝트 페이지",
            "on_battery": "배터리 사용 중"
        ],
        .spanish: [
            "system_default": "Según el sistema", "settings": "Ajustes", "quit": "Salir",
            "loading_account": "Cargando cuenta…", "five_hour_quota": "Límite de 5 horas", "weekly_quota": "Límite semanal",
            "remaining": "%d%% restante", "unavailable": "No disponible", "reset_at": "Se restablece: %@", "updated_at": "Actualizado %@",
            "credits_unlimited": "Créditos ilimitados", "credits_balance": "Créditos %@", "credits_unavailable": "Sin información de créditos",
            "reset_count": "%d restablecimientos", "refresh": "Actualizar", "official_usage": "Usage oficial",
            "section_display": "Visualización", "display_mode": "Los porcentajes muestran", "display_mode_remaining": "Restante", "display_mode_used": "Usado",
            "used": "%d%% usado", "alert_warning": "Alerta naranja", "alert_critical": "Alerta roja",
            "alert_description": "Al cruzar cada umbral, el porcentaje y la barra pasan a naranja y luego a rojo, en la barra de menús, el menú y la Touch Bar.",
            "section_language": "Idioma", "language": "Idioma de la app", "section_menu_bar": "Barra de menús", "icon": "Icono",
            "icon_size": "Tamaño del icono", "text_size": "Tamaño del texto", "section_general": "General",
            "section_services": "Servicios", "service_missing_codex": "No se encontró Codex CLI.",
            "service_missing_claude": "No hay credenciales de Claude Code. Inicia sesión con Claude Code primero.",
            "menu_bar_source": "Mostrar en la barra de menús", "provider_unavailable": "%@ no está instalado.",
            "launch_at_login": "Abrir al iniciar sesión", "touch_bar_mode": "Touch Bar",
            "touch_bar_mode_always": "Mostrar siempre", "touch_bar_mode_when_relevant": "Solo cuando una app relevante esté activa",
            "touch_bar_mode_off": "Desactivado", "touch_bar_content": "Muestra",
            "touch_bar_content_automatic": "Automático (un servicio)", "touch_bar_content_both": "Codex y Claude juntos", "touch_bar_both_compact": "Diseño compacto (con reinicios)",
            "touch_bar_description": "Muestra límites de 5 horas y semanales, progreso y horas de restablecimiento.",
            "touch_bar_unavailable": "La visualización permanente no está disponible; puede mostrarse mientras esta app esté activa.",
            "settings_window_title": "Ajustes de Codex Usage Bar", "five_hour_short": "5 horas", "weekly_short": "Semanal",
            "weekly_prefix": "Sem", "loading_reset": "Cargando restablecimientos…", "reset_customization": "Restablecimientos de Codex",
            "refresh_usage": "Actualizar Usage", "refresh_codex_usage": "Actualizar Codex Usage", "show_usage_bar": "Mostrar barra de Usage", "quota_customization": "Límite %@ de Codex",
            "touch_bar_reset": "Rest. 5h %@ · Sem %@", "loading_usage": "Cargando Usage…", "usage_unavailable": "Usage no disponible",
            "error_codex_not_found": "No se encontró Codex CLI. Instala o actualiza ChatGPT/Codex.",
            "error_launch_failed": "No se pudo iniciar Codex: %@", "error_timeout": "La solicitud agotó el tiempo. Inténtalo más tarde.",
            "error_invalid_response": "Codex devolvió datos de Usage no reconocidos.", "error_server": "Error de Codex: %@",
            "error_unknown": "Error desconocido", "error_launch_at_login": "No se pudo actualizar el inicio de sesión: %@",
            "error_claude_credentials_not_found": "No se encontraron credenciales de Claude. Inicia sesión con Claude Code primero.",
            "error_claude_token_expired": "La sesión de Claude Code ha caducado. Abre Claude Code una vez para renovarla.",
            "error_claude_not_subscribed": "Esta cuenta de Claude no tiene Usage de suscripción para mostrar.",
            "error_http_status": "Claude devolvió un error (código %d).", "error_network": "Error de red: %@", "error_rate_limited": "Demasiadas solicitudes. Se reintentará automáticamente.",
            "icon_gauge": "Indicador", "icon_simple_gauge": "Indicador simple", "icon_speedometer": "Velocímetro", "icon_bar_chart": "Gráfico de barras",
            "icon_trend": "Tendencia", "icon_percent": "Porcentaje", "icon_bolt": "Rayo", "icon_flame": "Llama",
            "icon_sparkles": "Destellos", "icon_terminal": "Terminal", "icon_command": "Command", "icon_cpu": "Procesador",
            "icon_chip": "Chip", "icon_timer": "Temporizador", "icon_refresh_clock": "Reloj de actualización", "icon_waveform": "Onda de estado", "icon_hidden": "Ocultar icono",
            "alert_normal": "Normal", "section_alerts": "Umbrales de alerta",
            "dur_day": "d", "dur_hour": "h", "dur_minute": "min", "dur_join": " ",
            "reset_in": "Se restablece en %@", "retry_after": "Reintento en %@", "section_models": "Semanal por modelo",
            "pace_help": "La línea fina de cada barra marca dónde estaría un consumo uniforme; pasarla significa gastar más rápido de lo que se repone.",
            "tab_services": "Servicios", "tab_display": "Visualización", "tab_menu_bar": "Barra de menús",
            "tab_touch_bar": "Touch Bar", "tab_general": "General",
            "battery_note": "Con batería, el intervalo de Claude se duplica; la actualización se detiene mientras la pantalla duerme.",
            "threshold_preview": "Vista previa", "menu_bar_tint": "Colorear el texto de la barra de menús bajo un umbral",
            "show_pace_marker": "Mostrar la marca de ritmo en las barras", "project_page": "Página del proyecto",
            "on_battery": "Con batería"
        ]
    ]
}
