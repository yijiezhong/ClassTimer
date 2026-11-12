import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 嵌在主浮窗里的设置面板（点「设定」或齿轮展开）。
///
/// 之前窗口高度用 setFrame 调整后视觉不更新，是因为 NSHostingView 的
/// SwiftUI 布局没跟着重算；现在改由 AppDelegate 重建 contentView 来强制刷新。
struct SettingsPanel: View {

    @ObservedObject var model: TimerModel

    /// 由 AppDelegate 注入，用于打开关于窗口
    var onShowAbout: (() -> Void)?

    private var palette: Palette { Palette(isLight: model.isLightMode) }

    @State private var durationInput: String = ""
    @FocusState private var durationFocused: Bool
    @FocusState private var segmentFocus: String?

    /// 正在录制哪一项（nil 表示没在录）
    enum HotKeyTarget { case toggle, settings, about }
    @State private var recordingTarget: HotKeyTarget?
    @State private var hotKeyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("计时时长")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.primaryText)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                spacing: 6
            ) {
                ForEach(TimerModel.presets) { preset in
                    presetChip(preset)
                }
            }

            HStack(spacing: 8) {
                Text("自定义")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.primaryText)

                Spacer(minLength: 0)

                TextField("00:00", text: $durationInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 104, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(palette.controlBackground)
                    )
                    .focused($durationFocused)
                    .onSubmit {
                        commitDurationInput()
                        // 回车后退出编辑：下次点击输入框一定重新触发「清空」，
                        // 不会出现"还停在输入框里、旧值留着"的情况
                        durationFocused = false
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        // 已经处于编辑状态时再点一下，也把旧值清掉，保持"每次输入从零开始"
                        if durationFocused { durationInput = "" }
                    })
                    .onChange(of: durationFocused) { _, focused in
                        if focused {
                            // 点进来就把旧值清掉，直接输新数字；直接回车/点走会恢复原值。
                            // 先清空再 activate：反过来的话 makeKey 引起的重新布局可能把刚清的空值又填回旧值。
                            durationInput = ""
                            TimerPanel.main?.activateForTextInput()
                        } else {
                            TimerPanel.main?.deactivateForKey()
                            commitDurationInput()
                        }
                    }
                    .help("输入 mm:ss（如 00:12）或分钟数（如 25），回车生效")

                Text("分:秒")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.primaryText)
            }

                HStack(spacing: 8) {
                    Text("分段计时")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.primaryText)

                    Text("讨论 5′ → 汇报 3′ 这类连播")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.primaryText)

                    Spacer(minLength: 0)

                    selfDrawToggle(isOn: $model.multiSegmentEnabled, enabled: true)
                }
                .frame(height: 22)

            if model.multiSegmentEnabled {
                segmentEditor
            }

            HStack(spacing: 8) {
                Text("外观")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.primaryText)

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    ForEach(TimerModel.AppearanceMode.allCases, id: \.self) { mode in
                        appearanceChip(mode)
                    }
                }
            }
            .frame(height: 24)

            // 已授权的用户不需要看到这一行；只有没权限时才提示 + 给「去授权」入口
            if !CGPreflightScreenCaptureAccess() {
                HStack(spacing: 8) {
                    Text("屏幕录制权限")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.primaryText)

                    Spacer(minLength: 0)

                    Text("未授权（自动模式退化为跟随系统外观）")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.primaryText)
                    Button("去授权") {
                        // 必须先向系统「请求」一次，ClassTimer 才会被登记到
                        // 系统设置 → 隐私与安全性 → 录屏与系统录音的列表里；
                        // 只打开设置面板而不请求，列表里根本不会出现这个 app。
                        _ = CGRequestScreenCaptureAccess()
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.controlText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(palette.controlBackground)
                        )
                }
                .frame(height: 22)
            }

            Divider().overlay(palette.divider)

            settingRow("结束提示音", isOn: $model.soundEnabled)
            settingRow("最后 10 秒滴答", isOn: $model.tickSoundEnabled)
            settingRow(
                "投影到第二块屏",
                isOn: $model.projectionEnabled,
                enabled: true,
                hint: model.hasExternalScreen ? nil : "未检测到第二块屏"
            )

            HStack(spacing: 8) {
                Text("提示音方案")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.primaryText)

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    ForEach(TimerModel.SoundPack.allCases, id: \.self) { pack in
                        soundPackChip(pack)
                    }
                }
            }
            .frame(height: 24)

            Divider().overlay(palette.divider)

            hotKeyRow(
                title: "开始 / 暂停",
                keyCode: model.hotKeyCode,
                mask: model.hotKeyMask,
                target: .toggle
            )
            hotKeyRow(
                title: "打开 / 关闭设置",
                keyCode: model.settingsHotKeyCode,
                mask: model.settingsHotKeyMask,
                target: .settings
            )
            hotKeyRow(
                title: "打开 / 关闭关于",
                keyCode: model.aboutHotKeyCode,
                mask: model.aboutHotKeyMask,
                target: .about
            )

            Divider().overlay(palette.divider)

            HStack {
                Spacer()
                Button("关于 Class Timer") { onShowAbout?() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.primaryText)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.controlBackground.opacity(0.7))
        )
        .onAppear { durationInput = model.totalString }
        .onChange(of: model.total) { _, _ in
            // 外部（预设/±30s）改变时同步输入框，但用户正在输入时不覆盖
            if !isEditingInput { durationInput = model.totalString }
        }
    }

    // MARK: - 快捷键行与录制

    /// 自绘开关：系统 Toggle 的 .tint 在本机 macOS 上不生效（开合都是灰轨道），
    /// 这里手画一个——开=蓝、关=灰，圆钮白，和系统设置里的观感一致。
    private func selfDrawToggle(isOn: Binding<Bool>, enabled: Bool) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Capsule()
                    .fill(isOn.wrappedValue ? Color.blue : Color.gray.opacity(0.45))
                Circle()
                    .fill(Color.white)
                    .frame(width: 15, height: 15)
                    .padding(2)
            }
            .frame(width: 36, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// 分段编辑器：段名 + 分钟数 + 删除；至少保留两段
    private var segmentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.segments.enumerated()), id: \.element.id) { index, segment in
                HStack(spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.tertiaryText)
                        .frame(width: 16, alignment: .leading)

                    TextField("段名", text: Binding(
                        get: { segment.name },
                        set: { model.segments[index].name = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(palette.controlBackground)
                    )
                    .focused($segmentFocus, equals: "name-\(index)")
                    .onChange(of: segmentFocus) { _, focused in
                        handleSegmentFocus(focused)
                    }

                    TextField("5", text: Binding(
                        get: { String(format: "%g", segment.minutes) },
                        set: { text in
                            if let value = Double(text), value >= 0.17, value <= 99 {
                                model.segments[index].minutes = value
                            }
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(palette.primaryText)
                    .padding(.horizontal, 7)
                    .frame(width: 48, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(palette.controlBackground)
                    )
                    .focused($segmentFocus, equals: "minutes-\(index)")
                    .onChange(of: segmentFocus) { _, focused in
                        handleSegmentFocus(focused)
                    }

                    Text("′")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.tertiaryText)

                    Button {
                        guard model.segments.count > 2 else { return }
                        model.segments.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.segments.count <= 2)
                    .help("删除这一段（至少保留两段）")
                }
                .frame(height: 24)
            }

            HStack(spacing: 6) {
                Button {
                    let next = model.segments.count + 1
                    model.segments.append(TimerModel.Segment(name: "第 \(next) 段", minutes: 5))
                } label: {
                    Text("＋ 添加一段")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.controlText)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(palette.controlBackground)
                        )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Text("共 \(model.segments.count) 段 · \(totalSegmentsText)")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.tertiaryText)
                    .monospacedDigit()
            }
            .frame(height: 22)
        }
    }

    /// 分段时间加总（用于编辑器右下角提示）
    private var totalSegmentsText: String {
        let seconds = Int(model.segments.reduce(0) { $0 + $1.seconds })
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 段编辑器里的输入框聚焦时，面板需要临时成为 key 才能收到键盘
    private func handleSegmentFocus(_ focused: String?) {
        if focused == nil {
            TimerPanel.main?.deactivateForKey()
        } else {
            TimerPanel.main?.activateForTextInput()
        }
    }

    private func soundPackChip(_ pack: TimerModel.SoundPack) -> some View {
        let selected = model.soundPack == pack
        return Button {
            model.soundPack = pack
        } label: {
            Text(pack.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? palette.primaryButtonText : palette.controlText)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? palette.primaryButtonBackground : palette.controlBackground)
                )
        }
        .buttonStyle(.plain)
        .help("提示音方案：\(pack.label)")
    }

    private func appearanceChip(_ mode: TimerModel.AppearanceMode) -> some View {
        let selected = model.appearanceMode == mode
        return Button {
            model.appearanceMode = mode
        } label: {
            Text(mode.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? palette.primaryButtonText : palette.controlText)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? palette.primaryButtonBackground : palette.controlBackground)
                )
        }
        .buttonStyle(.plain)
    }

    private func hotKeyRow(
        title: String,
        keyCode: UInt32,
        mask: UInt32,
        target: HotKeyTarget
    ) -> some View {
        let recording = recordingTarget == target
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.primaryText.opacity(0.9))

            Spacer(minLength: 0)

            Text(recording ? "按下组合键…" : HotKeyManager.displayString(keyCode: keyCode, modifiers: mask))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(recording ? Color.orange : palette.primaryText)

            Button(recording ? "取消" : "录制") {
                if recording {
                    stopRecordingHotKey()
                } else {
                    startRecordingHotKey(target: target)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(palette.controlText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.controlBackground)
            )
        }
        .frame(height: 22)
    }

    private func startRecordingHotKey(target: HotKeyTarget) {
        recordingTarget = target
        // 非激活面板平时收不到键盘，录制期间临时成为 key
        TimerPanel.main?.activateForTextInput()
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mask = HotKeyManager.carbonModifiers(from: event.modifierFlags)
            // 必须带至少一个修饰键（⌃⌥⌘），否则会和普通打字/Keynote 空格冲突
            let hasModifier = mask & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) != 0
            guard hasModifier else { return event }

            let code = UInt32(event.keyCode)
            switch target {
            case .toggle:
                model.hotKeyCode = code
                model.hotKeyMask = mask
                HotKeyManager.shared.register(id: 1, keyCode: code, modifiers: mask)
            case .settings:
                model.settingsHotKeyCode = code
                model.settingsHotKeyMask = mask
                HotKeyManager.shared.register(id: 2, keyCode: code, modifiers: mask)
            case .about:
                model.aboutHotKeyCode = code
                model.aboutHotKeyMask = mask
                HotKeyManager.shared.register(id: 3, keyCode: code, modifiers: mask)
            }
            stopRecordingHotKey()
            return nil
        }
    }

    private func stopRecordingHotKey() {
        recordingTarget = nil
        if let hotKeyMonitor {
            NSEvent.removeMonitor(hotKeyMonitor)
        }
        hotKeyMonitor = nil
        TimerPanel.main?.deactivateForKey()
    }

    /// 正在编辑输入框时不要被外部状态覆盖
    private var isEditingInput: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    /// 解析输入：纯数字按分钟，含冒号按 mm:ss
    private func commitDurationInput() {
        let text = durationInput.trimmingCharacters(in: .whitespaces)
        var seconds: TimeInterval?

        if text.contains(":") {
            let parts = text.split(separator: ":").map(String.init)
            if parts.count == 2, let minutes = Double(parts[0]), let secs = Double(parts[1]) {
                seconds = minutes * 60 + secs
            }
        } else if let value = Int(text) {
            // 纯数字：1–2 位当分钟（25 → 25:00）；
            // 3–4 位按 mmss 右对齐补零（0012 / 012 → 00:12，1230 → 12:30），
            // 这样输入 "0012" 会回填成 00:12 而不是 0012。
            if text.count <= 2 {
                seconds = Double(value) * 60
            } else if text.count <= 4 {
                let padded = String(format: "%04d", value)
                let minutes = Double(padded.prefix(2)) ?? 0
                let secs = Double(padded.suffix(2)) ?? 0
                seconds = minutes * 60 + secs
            }
        }

        if let seconds, seconds >= 10, seconds <= 99 * 60 + 59 {
            model.applyDuration(seconds)
        }
        // 没输入就点走：恢复当前时长，而不是把时长清掉
        durationInput = model.totalString
    }

    private func settingRow(
        _ title: String,
        isOn: Binding<Bool>,
        enabled: Bool = true,
        hint: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.primaryText)

            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.primaryText)
            }

            Spacer(minLength: 0)

            selfDrawToggle(isOn: isOn, enabled: enabled)
        }
        .frame(height: 22)
    }

    private func presetChip(_ preset: TimerModel.Preset) -> some View {
        let selected = Int(model.total) == preset.minutes * 60
        return Button {
            model.selectDuration(preset.seconds)
        } label: {
            Text(preset.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                // 选中态必须用「深底白字 / 浅底黑字」的对比色：
                // 之前文字写死 black、底用 primaryText（浅色模式也是黑），黑底黑字看不清
                .foregroundStyle(selected ? palette.primaryButtonText : palette.controlText)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? palette.primaryButtonBackground : palette.controlBackground)
                )
        }
        .buttonStyle(.plain)
        .help("\(preset.minutes) 分钟")
    }

}
