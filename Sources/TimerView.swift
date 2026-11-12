import SwiftUI

/// 计时器浮窗的全部界面。
///
/// 视觉取向：深色半透明卡片 + 超大等宽数字，投影仪上远距离也能一眼读出；
/// 只保留三个操作（开始/暂停、重置、时长设置），课堂现场不需要更多选择。
struct TimerView: View {

    @ObservedObject var model: TimerModel

    /// 点「设定」或绿点时调用，由 AppDelegate 打开独立的设置窗口
    var onOpenSettings: (() -> Void)?

    /// 右键「关于」入口
    var onShowAbout: (() -> Void)?

    /// 拖动开始时记住窗口原点（SwiftUI 手势本身不移动窗口，要手动 setFrameOrigin）
    @State private var dragStart: CGPoint?

    /// 当前配色（跟随背景亮度自动切换）
    private var palette: Palette { Palette(isLight: model.isLightMode) }

    /// 标题/输入框聚焦时需要窗口临时成为 key，否则 SwiftUI 的 TextField 收不到键盘
    @FocusState private var titleFocused: Bool
    @FocusState private var durationFocused: Bool

    static let width: CGFloat = 360

    /// 初始窗口高度（只用于建窗与位置恢复）。实际高度由面板内容决定：
    /// 浮窗是 NSHostingView 驱动的自适应窗口，SwiftUI 布局完会自动把窗口调整到内容高度，
    /// 所以加内容后不必再手动改这里的数字。
    static let initialHeight: CGFloat = 190

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 4)
            if let segmentLabel = model.segmentLabel {
                Text(segmentLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(accent.opacity(0.9))
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
            }
            timeDisplay
            Spacer(minLength: 4)
            progressBar
            Spacer(minLength: 8)
            controls
            if model.activePanel == .settings {
                SettingsPanel(model: model, onShowAbout: onShowAbout)
                    .padding(.top, 12)
                    .transition(.opacity)
            } else if model.activePanel == .about {
                AboutPanel(model: model)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        // 宽度固定；高度交给内容——展开设置/关于面板时窗口随内容长高，
        // 不再依赖三态硬编码高度（compact 190 / settings 690 / about 520）。
        .frame(width: Self.width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.18), value: model.activePanel)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: model.phase)
        .animation(.linear(duration: 0.1), value: model.remaining)
        // 菜单栏图标可能被系统收纳，右键浮窗是提醒讲师"这个还能退出"的兜底入口
        .contextMenu {
            Button(model.phase == .running ? "暂停" : "开始") { model.toggle() }
            Button("重置") { model.reset() }
            Divider()
            Button("设置…") { onOpenSettings?() }
            Button("关于 Class Timer") { onShowAbout?() }
            Divider()
            Button("退出 Class Timer") { NSApp.terminate(nil) }
        }
    }

    // MARK: - 拖动窗口

    /// 拖动非按钮区域移动浮窗；按钮区域不挂这个手势，避免抢点击
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard let window = TimerPanel.main else { return }
                if dragStart == nil { dragStart = window.frame.origin }
                guard let start = dragStart else { return }
                window.setFrameOrigin(
                    NSPoint(
                        x: start.x + value.translation.width,
                        y: start.y - value.translation.height
                    )
                )
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: - 左上角红黄绿

    /// 自绘的三个圆点：关闭 / 最小化 / 放大缩小（设置面板展开⇄收起）
    private var trafficLights: some View {
        HStack(spacing: 0) {
            trafficLight(color: Color(red: 1.00, green: 0.37, blue: 0.34)) {
                NSApp.terminate(nil)
            }
            .help("退出课堂计时器")

            trafficLight(color: Color(red: 0.99, green: 0.74, blue: 0.18)) {
                model.isSettingsOpen = false
            }
            .help("收起设置")

            trafficLight(color: Color(red: 0.16, green: 0.78, blue: 0.25)) {
                model.isSettingsOpen.toggle()
            }
            .help("放大 / 缩小")
        }
    }

    /// 11pt 圆点 + 18×18 方形热区，保证好点中
    private func trafficLight(color: Color, action: @escaping () -> Void) -> some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 7) {
            trafficLights

            if model.phase == .finished {
                Text("时间到")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(accent)
            } else {
                TextField("", text: $model.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 72)
                    .focused($titleFocused)
                    .onChange(of: titleFocused) { _, focused in
                        if focused {
                            TimerPanel.main?.activateForTextInput()
                        } else {
                            TimerPanel.main?.deactivateForKey()
                            if model.title.trimmingCharacters(in: .whitespaces).isEmpty {
                                model.title = "讨论计时"
                            }
                        }
                    }
            }

            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)

            Spacer()

            Button {
                model.isSettingsOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 9, weight: .semibold))
                    Text("设定 \(model.totalString)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(palette.tertiaryText)
                // 扩大点击热区（上下各 7pt、左右各 8pt）
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击设置计时时长")
        }
        .frame(height: 16)
    }

    // MARK: - 主数字

    private var timeDisplay: some View {
        Text(model.timeString)
            .font(.system(size: 72, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .tracking(-1.5)
            .lineLimit(1)
            // 不允许按可用高度缩小：无论面板展开与否，数字始终是 72pt
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(digitColor(palette))
            .shadow(color: model.phase == .finished ? accent.opacity(0.65) : .clear, radius: 16)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture)
    }

    // MARK: - 进度条

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.trackBackground)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.72), accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(3, geo.size.width * model.overallFraction))
            }
        }
        .frame(height: 6)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    // MARK: - 控制行

    private var controls: some View {
        HStack(spacing: 9) {
            Button(action: model.toggle) {
                HStack(spacing: 6) {
                    Image(systemName: model.playSymbol)
                        .font(.system(size: 11, weight: .bold))
                    Text(model.playLabel)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(palette.primaryButtonText)
                .padding(.horizontal, 17)
                .frame(height: 34)
                .background(Capsule().fill(palette.primaryButtonBackground))
            }
            .buttonStyle(.plain)
            .help("开始 / 暂停计时")

            Button(action: model.reset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.controlText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(palette.controlBackground))
            }
            .buttonStyle(.plain)
            .help("重置为设定时长")

            Spacer(minLength: 4)

            Button {
                model.soundEnabled.toggle()
            } label: {
                Image(systemName: model.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.soundEnabled ? palette.controlText : palette.tertiaryText.opacity(0.6))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("结束提示音开关")

            Button {
                model.isSettingsOpen.toggle()
            } label: {
                Image(systemName: model.isSettingsOpen ? "chevron.up" : "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.controlText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("设置时长")
        }
        .frame(height: 34)
    }

    // MARK: - 设置面板

    // MARK: - 配色

    private var cardBackground: some View {
        ZStack {
            palette.cardBackground
            LinearGradient(
                colors: [palette.cardHighlight, Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            // 时间到的红色闪烁
            Color(red: 1.0, green: 0.22, blue: 0.18)
                .opacity(model.flash ? 0.30 : 0)
        }
    }

    private var accent: Color {
        if model.phase == .finished { return Color(red: 1.0, green: 0.30, blue: 0.26) }
        // 警示色只在真正计时时出现：待开始 / 已暂停不提示剩余时间紧张
        guard model.phase == .running || model.phase == .paused else {
            return Color(red: 0.35, green: 0.62, blue: 1.0)
        }
        // 警示窗口：总时长的 20%，但短计时不要一开始就变橙
        let warnWindow = min(30, max(5, model.total * 0.2))
        let urgentWindow = min(10, max(3, model.total * 0.1))
        if model.remaining <= urgentWindow { return Color(red: 1.0, green: 0.32, blue: 0.25) }
        if model.remaining <= warnWindow { return Color(red: 1.0, green: 0.70, blue: 0.18) }
        return Color(red: 0.35, green: 0.62, blue: 1.0)
    }

    private func digitColor(_ palette: Palette) -> Color {
        switch model.phase {
        case .finished: return accent
        case .paused: return palette.secondaryText
        default: return palette.primaryText
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .idle: return palette.tertiaryText
        case .running: return Color(red: 0.30, green: 0.85, blue: 0.45)
        case .paused: return Color(red: 1.0, green: 0.70, blue: 0.18)
        case .finished: return Color(red: 1.0, green: 0.30, blue: 0.26)
        }
    }
}
