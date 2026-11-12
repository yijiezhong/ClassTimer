import AppKit
import SwiftUI
import Combine
import Carbon

/// 计时器专用浮窗面板。
///
/// 关键设置（决定「浮在所有 App 之上，包括全屏播放的 Keynote」）：
/// - level = .screenSaver  —— 高于普通窗口、浮动窗口和全屏 App 的窗口层级
/// - collectionBehavior 含 .canJoinAllSpaces / .fullScreenAuxiliary / .stationary
///   —— 允许加入所有空间（含别的 App 新建的全屏空间），并随空间切换保持原位
/// - nonactivatingPanel  —— 点击时不激活本 App，不会把 Keynote 从播放状态踢出来
/// - canBecomeKey = false —— 完全不参与键盘焦点，讲师点计时器不会吞掉翻页快捷键
final class TimerPanel: NSPanel {

    /// 主浮窗引用，供 SwiftUI 里的拖动手势移动窗口用（投影窗不设置）
    static weak var main: TimerPanel?
    /// 输入框聚焦时临时置 true，让 TextField 能接收键盘
    private var forceKey = false
    override var canBecomeKey: Bool { forceKey }

    /// 进入文字输入：窗口临时成为 key
    func activateForTextInput() {
        forceKey = true
        makeKey()
    }

    /// 退出文字输入：恢复不抢键盘焦点
    func deactivateForKey() {
        forceKey = false
        if isKeyWindow { makeFirstResponder(nil) }
    }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if CommandLine.arguments.contains("--verbose"), event.type == .leftMouseDown {
            let p = event.locationInWindow
            FileHandle.standardError.write(
                "[panel] mouseDown at (\(String(format: "%.1f", p.x)), \(String(format: "%.1f", p.y))) frame=\(frame)\n"
                    .data(using: .utf8)!
            )
        }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = TimerModel()
    private var panel: TimerPanel!
    private var hostingView: NSHostingView<TimerView>!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var moveObserver: NSObjectProtocol?
    private var projectionPanel: TimerPanel?
    private var aboutWindow: NSWindow?
    private let appearanceSampler = AppearanceSampler()

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        installURLEventHandler()
        buildPanel()
        buildStatusItem()
        bindModel()

        model.onStatusTitleChange = { [weak self] title in
            self?.statusItem.button?.title = title
        }
        model.publishStatus()

        showPanel()
        model.hasExternalScreen = NSScreen.screens.count > 1
        updateProjectionWindow()
        applyLaunchArguments()
        enforceInitialHeightIfCompact()
    }

    /// 启动时把窗口钳回紧凑高度。
    /// AppKit 的窗口状态恢复即使设了 isRestorable = false，也可能在 orderFront
    /// 之后再把上次的 frame 套回来（实测展开过的设置面板 787pt 被恢复）；
    /// 这里在启动末尾兜底一次，`--open-settings` 展开时跳过。
    private func enforceInitialHeightIfCompact() {
        guard model.activePanel == .none else { return }
        var frame = panel.frame
        let target = TimerView.initialHeight
        guard abs(frame.height - target) > 1 else { return }
        let top = frame.maxY
        frame.size.height = target
        frame.origin.y = top - target
        panel.setFrame(frame, display: true)
        model.debugLog("enforce compact height -> \(frame)")
    }

    /// 便于自动化验证的启动参数：
    /// --seconds 30    设定时长（秒）
    /// --autostart     启动即开始计时
    /// --open-settings 启动即展开时长设置
    private func applyLaunchArguments() {
        let args = CommandLine.arguments

        if let index = args.firstIndex(of: "--seconds"),
           index + 1 < args.count,
           let value = Double(args[index + 1]) {
            model.applyDuration(value)
        }

        if args.contains("--open-settings") {
            model.isSettingsOpen = true
        }

        if args.contains("--autostart") {
            model.start()
        }

        // 诊断/修复用：主动向系统请求一次屏幕录制权限，
        // 让 ClassTimer 出现在「系统设置 → 隐私与安全性 → 录屏与系统录音」列表里
        if args.contains("--request-screen-capture") {
            let granted = CGRequestScreenCaptureAccess()
            model.debugLog("request-screen-capture granted=\(granted)")
        }

        if args.contains("--show-about") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showAbout()
            }
        }
    }

    // MARK: - 浮窗

    private func buildPanel() {
        hostingView = NSHostingView(rootView: TimerView(
            model: model,
            onShowAbout: { [weak self] in self?.showAbout() }
        ))
        hostingView.wantsLayer = true
        // 窗口 resize 时让 SwiftUI 内容跟着撑满，否则 setFrame 只会改窗口、内容仍是旧高度
        hostingView.autoresizingMask = [.width, .height]

        let rect = NSRect(
            x: 0,
            y: 0,
            width: TimerView.width,
            height: TimerView.initialHeight
        )

        panel = TimerPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        TimerPanel.main = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        // 关掉系统背景拖动：它会吞掉顶部 header 区域的点击（设定按钮点不动），
        // 拖动改由 SwiftUI 的 dragGesture 在大数字/进度条区域实现。
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        // 关掉 AppKit 的窗口状态恢复：否则从 Finder/open -a 启动时，
        // 系统会把上次的窗口尺寸（比如展开的设置面板 787pt）套回来，
        // 看起来像"一启动就展开设置"。
        panel.isRestorable = false

        restorePanelFrame()

        // 背景亮度采样：自动在深/浅模式间切换
        appearanceSampler.onChange = { [weak self] backgroundIsBright in
            self?.model.debugLog("backgroundIsBright=\(backgroundIsBright) -> isLightMode=\(backgroundIsBright ? false : true)")
            self?.model.updateBackgroundBright(backgroundIsBright)
        }
        appearanceSampler.start(window: panel)

        // 全局热键：1=开始/暂停，2=设置，3=关于
        HotKeyManager.shared.handlers[1] = { [weak self] in self?.model.toggle() }
        HotKeyManager.shared.handlers[2] = { [weak self] in self?.model.togglePanel(.settings) }
        HotKeyManager.shared.handlers[3] = { [weak self] in self?.model.togglePanel(.about) }
        HotKeyManager.shared.install()
        HotKeyManager.shared.register(id: 1, keyCode: model.hotKeyCode, modifiers: model.hotKeyMask)
        HotKeyManager.shared.register(id: 2, keyCode: model.settingsHotKeyCode, modifiers: model.settingsHotKeyMask)
        HotKeyManager.shared.register(id: 3, keyCode: model.aboutHotKeyCode, modifiers: model.aboutHotKeyMask)


        // 黄点隐藏浮窗后，用户再次 open app 或从菜单激活时自动恢复显示
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak panel] _ in
            if CommandLine.arguments.contains("--verbose") {
                FileHandle.standardError.write(
                    "[panel] didBecomeActive, visible=\(panel?.isVisible ?? false)\n".data(using: .utf8)!
                )
            }
            guard let panel, !panel.isVisible else { return }
            panel.orderFrontRegardless()
        }

        // 记住拖动后的位置
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.savePanelOrigin()
        }

        // 面板展开/收起时窗口高度由 SwiftUI 内容驱动（自适应，不再硬编码三态）。
        // 高度变化以「顶边不动、向下长」的方式进行，若下方空间不足就会长到屏幕外，
        // 所以每次 resize 后把窗口回夹到当前屏的可见区域。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.clampPanelToScreen()
        }

        // 进入/退出全屏（Keynote 放映）会切换 Space，切完必须重新把浮窗顶上来，
        // 否则它会被留在原来的空间里，看起来像"没浮上去"。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringPanelToFront()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringPanelToFront()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.model.hasExternalScreen = NSScreen.screens.count > 1
            self.updateProjectionWindow()
            self.ensurePanelOnScreen()
            self.bringPanelToFront()
        }
    }

    /// 把浮窗重新压到当前 Space 最上层（不抢焦点、不激活 App）
    private func bringPanelToFront() {
        guard let panel, panel.isVisible else { return }
        // 全屏 App 的空间里，level 与 collectionBehavior 需要重新确认一次
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.orderFrontRegardless()

        if let projectionPanel, projectionPanel.isVisible {
            projectionPanel.level = .screenSaver
            projectionPanel.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .fullScreenAuxiliary,
                .ignoresCycle
            ]
            projectionPanel.orderFrontRegardless()
        }
    }

    @objc func showPanel() {
        panel.orderFrontRegardless()
        panel.setIsVisible(true)
    }

    // MARK: - 位置

    /// 每次启动都把手动摆到固定角落（不恢复上次拖到的位置）。
    ///
    /// 位置策略（配合 Keynote 双屏放映）：
    /// - **双屏**：讲师屏（内置屏，通常是 Keynote 的演讲者显示器）→ **右下角**，
    ///   避开演讲者视图右侧的备注/下一张幻灯片预览；投影屏（播放显示器）→ 右上角。
    /// - **单屏**：右上角（普通计时场景，不挡标题栏与内容）。
    private func restorePanelFrame() {
        let size = NSSize(width: TimerView.width, height: TimerView.initialHeight)
        let screens = NSScreen.screens
        let isDualScreen = screens.count > 1
        // 内置屏 = 讲师笔记本屏，Keynote 演讲者显示器默认在这块屏上
        let home = (isDualScreen ? builtInScreen() : nil)
            ?? screens.first
        let visible = home?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = isDualScreen
            ? bottomRightOrigin(in: visible, size: size)
            : defaultOrigin(in: visible, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        model.debugLog("restorePanelFrame dual=\(isDualScreen) origin=\(origin)")
    }

    /// 内置屏（笔记本屏）——Keynote 演讲者显示器默认所在
    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    /// 右下角（AppKit 左下原点：x 靠右、y 靠下）
    private func bottomRightOrigin(in visible: NSRect, size: NSSize) -> NSPoint {
        let inset: CGFloat = 12
        return NSPoint(
            x: visible.maxX - size.width - inset,
            y: visible.minY + inset
        )
    }

    /// 默认位置：屏幕右上角，留 12pt 让卡片阴影不被屏幕边缘裁掉
    private func defaultOrigin(in visible: NSRect, size: NSSize) -> NSPoint {
        let inset: CGFloat = 12
        return NSPoint(
            x: visible.maxX - size.width - inset,
            y: visible.maxY - size.height - inset
        )
    }

    /// 窗口是否至少有一块（60×40）落在某块屏幕的可见区域内
    private func isFrameVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let hit = screen.visibleFrame.intersection(frame)
            return !hit.isNull && hit.width >= 60 && hit.height >= 40
        }
    }

    /// 屏幕配置变化（进入/退出全屏、插拔外接屏）后，把跑到屏幕外的浮窗拉回主屏
    private func ensurePanelOnScreen() {
        guard let panel, panel.isVisible else { return }
        let frame = panel.frame
        if isFrameVisible(frame) { return }
        guard let home = NSScreen.screens.first else { return }
        let size = frame.size
        let origin = defaultOrigin(in: home.visibleFrame, size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        savePanelOrigin()
    }

    /// 把窗口回夹到「与它交叠面积最大的那块屏」的可见区域。
    /// 面板高度自适应后，窗口可能在展开时向下长出屏幕（顶边固定、向下长），
    /// 这里把它推回可见范围；高度超过屏幕时同时按屏幕高度收窄。
    private func clampPanelToScreen() {
        guard let panel, panel.isVisible else { return }
        var frame = panel.frame
        let screen = NSScreen.screens
            .filter { $0.frame.intersects(frame) }
            .max { a, b in
                a.frame.intersection(frame).area < b.frame.intersection(frame).area
            }
            ?? panel.screen
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var changed = false
        if frame.width > visible.width { frame.size.width = visible.width; changed = true }
        if frame.height > visible.height { frame.size.height = visible.height; changed = true }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width; changed = true }
        if frame.minX < visible.minX { frame.origin.x = visible.minX; changed = true }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height; changed = true }
        if frame.minY < visible.minY { frame.origin.y = visible.minY; changed = true }

        if changed {
            model.debugLog("clamp panel -> \(frame)")
            panel.setFrame(frame, display: true)
            savePanelOrigin()
        }
    }

    private func savePanelOrigin() {
        let origin = panel.frame.origin
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: "panelX")
        defaults.set(Double(origin.y), forKey: "panelY")
    }

    private func resetPanelPosition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 12,
            y: visible.maxY - size.height - 12
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        savePanelOrigin()
    }

    private func bindModel() {
        // 注意：@Published 的 sink 在 willSet 阶段触发，此时 model.projectionEnabled
        // 还是旧值，必须用回调参数，不能回读属性。
        model.$projectionEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.updateProjectionWindow(enabled: enabled)
            }
            .store(in: &cancellables)
    }

    // MARK: - 投影（第二块屏）

    /// 播放显示器（投影屏）：优先非内置屏（外接显示器）；
    /// 全是外接屏的台式机场景，取第一块非主屏。
    /// 单屏时返回 nil。
    private var externalScreen: NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return nil }
        if let builtin = builtInScreen(),
           let external = screens.first(where: { $0 !== builtin }) {
            return external
        }
        let primary = screens.first
        return screens.first { $0 !== primary }
    }

    private func updateProjectionWindow(enabled: Bool? = nil) {
        let shouldShow = enabled ?? model.projectionEnabled
        guard shouldShow, let screen = externalScreen else {
            projectionPanel?.orderOut(nil)
            return
        }
        showProjection(on: screen)
    }

    private func showProjection(on screen: NSScreen) {
        if projectionPanel == nil {
            buildProjectionPanel()
        }
        positionProjection(on: screen)
        projectionPanel?.orderFrontRegardless()
    }

    private func buildProjectionPanel() {
        let hosting = NSHostingView(rootView: ProjectionView(model: model))
        hosting.wantsLayer = true

        let rect = NSRect(
            x: 0,
            y: 0,
            width: ProjectionView.width,
            height: ProjectionView.height
        )
        let panel = TimerPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        // 关掉系统背景拖动：它会吞掉顶部 header 区域的点击（设定按钮点不动），
        // 拖动改由 SwiftUI 的 dragGesture 在大数字/进度条区域实现。
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.isRestorable = false

        projectionPanel = panel

    }

    /// 播放显示器（投影屏）上的只读板固定在**右上角**，避开幻灯片主体内容。
    /// 不恢复上次拖到的位置——每堂课位置一致才不用找。
    private func positionProjection(on screen: NSScreen) {
        guard let panel = projectionPanel else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let inset: CGFloat = 24
        let origin = NSPoint(
            x: visible.maxX - size.width - inset,
            y: visible.maxY - size.height - inset
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        model.debugLog("projection origin=\(origin) screen=\(screen.localizedName)")
    }

    // MARK: - 状态栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.title = "⏱ 10:00"
        }

        let menu = NSMenu()

        let visibility = NSMenuItem(
            title: "显示 / 隐藏计时器",
            action: #selector(togglePanelVisibility),
            keyEquivalent: ""
        )
        visibility.target = self
        menu.addItem(visibility)

        let position = NSMenuItem(
            title: "把计时器放回右上角",
            action: #selector(resetPosition),
            keyEquivalent: ""
        )
        position.target = self
        menu.addItem(position)

        menu.addItem(.separator())

        let show = NSMenuItem(
            title: "显示浮窗",
            action: #selector(showPanel),
            keyEquivalent: ""
        )
        show.target = self
        menu.addItem(show)

        let about = NSMenuItem(
            title: "关于 Class Timer",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: "开始 / 暂停",
            action: #selector(toggleTimer),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let reset = NSMenuItem(
            title: "重置",
            action: #selector(resetTimer),
            keyEquivalent: ""
        )
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出课堂计时器",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func togglePanelVisibility() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    @objc private func resetPosition() {
        resetPanelPosition()
    }

    @objc private func toggleTimer() {
        model.toggle()
        if !panel.isVisible { showPanel() }
    }

    @objc private func resetTimer() {
        model.reset()
        if !panel.isVisible { showPanel() }
    }

    // MARK: - 自定义 URL scheme（classtimer://show）

    /// 浮窗被隐藏（菜单栏「显示 / 隐藏计时器」或黄点）后，URL scheme 是最可靠的唤起方式：
    /// `open "classtimer://show"` 显示，`open "classtimer://toggle"` 切换。
    /// scheme 在 Info.plist 的 CFBundleURLTypes 里注册（由 build.sh 生成）。
    private func installURLEventHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? ""
        model.debugLog("url event: \(raw)")
        if raw.lowercased().hasSuffix("toggle") {
            togglePanelVisibility()
        } else {
            showPanel()
        }
    }

    /// 浮窗被黄点隐藏后，再次打开 app（open -a / 点菜单）要能重新显示
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if CommandLine.arguments.contains("--verbose") {
            FileHandle.standardError.write("[panel] handleReopen\n".data(using: .utf8)!)
        }
        showPanel()
        return true
    }

    @objc private func showAbout() {
        model.togglePanel(.about)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}


private extension NSRect {
    /// 与另一矩形相交的面积（不相交为 0），用于挑选窗口所在的屏幕
    var area: CGFloat { width * height }
}
