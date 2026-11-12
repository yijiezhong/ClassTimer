import SwiftUI

/// 浮窗的配色方案：深色与浅色两套。
///
/// 由 AppearanceSampler 根据浮窗下方的背景亮度自动选择——
/// 背景暗（比如 Keynote 深色页）用深色卡片 + 白字，
/// 背景亮（白底幻灯片）用浅色卡片 + 深字，保证任何背景上都看得清。
struct Palette {

    let isLight: Bool

    /// 卡片底色。
    /// 浅色卡片要足够实（0.97）：半透明时背后的文字会透上来，
    /// 白底幻灯片上数字像浮在字上一样，看着"看不清"。
    var cardBackground: Color {
        isLight ? Color.white.opacity(0.97) : Color.black.opacity(0.88)
    }

    /// 卡片顶部微光
    var cardHighlight: Color {
        isLight ? Color.black.opacity(0.03) : Color.white.opacity(0.035)
    }

    /// 主文字（大数字）。浅色模式用纯黑，不要 0.88 的灰——投影/截图压缩后会显得发虚
    var primaryText: Color {
        isLight ? Color.black : Color.white
    }

    /// 次级文字（标题、说明）
    var secondaryText: Color {
        isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.42)
    }

    /// 更弱的文字（设定、版权）
    var tertiaryText: Color {
        isLight ? Color.black.opacity(0.38) : Color.white.opacity(0.34)
    }

    /// 控件底色
    var controlBackground: Color {
        isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.08)
    }

    /// 控件上的文字
    var controlText: Color {
        isLight ? Color.black.opacity(0.75) : Color.white.opacity(0.78)
    }

    /// 进度条底槽
    var trackBackground: Color {
        isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.13)
    }

    /// 边框：浅色卡片靠它从白底里分离出来
    var border: Color {
        isLight ? Color.black.opacity(0.18) : Color.white.opacity(0.14)
    }

    /// 主按钮（开始）底色
    var primaryButtonBackground: Color {
        isLight ? Color.black.opacity(0.82) : Color.white
    }

    /// 主按钮文字
    var primaryButtonText: Color {
        isLight ? Color.white : Color.black.opacity(0.9)
    }

    /// 分区分隔线
    var divider: Color {
        isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.10)
    }
}
