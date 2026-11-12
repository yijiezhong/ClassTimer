import Foundation
import AppKit
import Combine
import Carbon.HIToolbox

/// 课堂讨论计时器的状态与计时逻辑。
///
/// 设计要点：
/// - 所有计时都基于「截止时刻 deadline」计算，而不是逐次减 0.1 秒，
///   这样即使主线程短暂卡顿（拖窗口、动画）也不会累积误差。
/// - 每 0.1 秒刷新一次，供 SwiftUI 平滑绘制进度条；状态栏标题同步刷新。
/// - 结束提醒 = 三声提示音 + 窗口红色闪烁，两者都可单独关闭/静音。
final class TimerModel: ObservableObject {

    enum Phase: Equatable {
        case idle       // 已设定，未开始
        case running    // 计时中
        case paused     // 暂停
        case finished   // 时间到
    }

    struct Preset: Identifiable, Hashable {
        let minutes: Int
        var id: Int { minutes }
        var label: String { "\(minutes)′" }
        var seconds: TimeInterval { TimeInterval(minutes * 60) }
    }

    static let presets: [Preset] = [1, 2, 3, 5, 8, 10, 15, 25, 30, 45].map(Preset.init)

    /// 分段计时里的一段（讨论 5 分钟 → 汇报 3 分钟…）
    struct Segment: Identifiable, Codable, Hashable {
        var id = UUID()
        var name: String
        /// 分钟数，允许小数（0.5 = 30 秒）
        var minutes: Double

        var seconds: TimeInterval {
            max(10, min(99 * 60 + 59, minutes * 60))
        }
    }

    /// 分段计时：打开且至少两段时按段连播；关闭时按单段时长计时。
    @Published var multiSegmentEnabled: Bool {
        didSet {
            UserDefaults.standard.set(multiSegmentEnabled, forKey: Keys.multiSegment)
            applySegmentsIfNeeded()
        }
    }

    /// 段列表（修改后按新表重新开始）
    @Published var segments: [Segment] {
        didSet {
            persistSegments()
            applySegmentsIfNeeded()
        }
    }

    /// 当前跑到第几段（0 起），分段模式下有效
    @Published private(set) var currentSegmentIndex = 0

    /// 是否真的按多段跑（开关打开且至少两段）
    var isSegmented: Bool { multiSegmentEnabled && segments.count >= 2 }

    /// 单段模式下记住的时长；分段开关关掉后恢复到它
    private var singleDuration: TimeInterval = 600

    /// 分段模式的整体进度（1 = 刚开始，0 = 全部跑完）
    var overallFraction: Double {
        guard isSegmented else { return fraction }
        let all = segments.reduce(0) { $0 + $1.seconds }
        guard all > 0 else { return 0 }
        let done = segments.prefix(currentSegmentIndex).reduce(0) { $0 + $1.seconds }
        let used = done + (total - remaining)
        return max(0, min(1, 1 - used / all))
    }

    /// 分段模式下 header 上显示的「段名 1/3」；单段返回 nil
    var segmentLabel: String? {
        guard isSegmented else { return nil }
        return "\(segments[currentSegmentIndex].name) \(currentSegmentIndex + 1)/\(segments.count)"
    }

    /// 允许的最短 / 最长时长（10 秒 ~ 99 分 59 秒）
    static let minDuration: TimeInterval = 10
    static let maxDuration: TimeInterval = 99 * 60 + 59

    @Published private(set) var total: TimeInterval
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var phase: Phase = .idle

    /// 时间到时的红闪开关
    @Published private(set) var flash = false

    /// 主浮窗当前展开的面板
    enum PanelMode: String {
        case none, settings, about
    }

    @Published var activePanel: PanelMode = .none

    /// 外观模式：自动（按背景亮度）/ 深色 / 浅色
    enum AppearanceMode: String, CaseIterable {
        case auto, dark, light

        var label: String {
            switch self {
            case .auto: return "自动"
            case .dark: return "深色"
            case .light: return "浅色"
            }
        }
    }

    @Published var appearanceMode: AppearanceMode = .auto {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
        }
    }

    /// 采样器测得的「浮窗下方背景是否偏亮」（仅在「自动」模式下生效）
    @Published private(set) var backgroundIsBright = false

    /// 实际是否走浅色配色。
    /// 自动模式下取反色，形成对比：背景暗→浅色卡片，背景亮→深色卡片，
    /// 否则黑底幻灯片上放黑卡片、白底上放白卡片都会糊在一起。
    var isLightMode: Bool {
        switch appearanceMode {
        case .auto: return !backgroundIsBright
        case .dark: return false
        case .light: return true
        }
    }

    func updateBackgroundBright(_ isBright: Bool) {
        backgroundIsBright = isBright
    }

    /// 兼容旧调用：设置面板是否展开
    var isSettingsOpen: Bool {
        get { activePanel == .settings }
        set { activePanel = newValue ? .settings : .none }
    }

    /// 点同一个图标时收起，否则切到目标面板。
    /// 打开设置面板时自动暂停计时——讲师改时长/开关时不该让倒计时继续跑。
    func togglePanel(_ mode: PanelMode) {
        let opening = activePanel != mode
        if opening && mode == .settings {
            pauseIfRunning()
        }
        activePanel = opening ? mode : .none
    }

    /// 只在运行中才暂停（暂停/空闲/结束都不动）
    func pauseIfRunning() {
        guard phase == .running else { return }
        debugLog("auto-pause (opening settings)")
        pause()
    }

    /// 全局热键（keyCode + Carbon 修饰键），默认 ⌃⌥Space
    @Published var hotKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotKeyCode), forKey: "hotKeyCode") }
    }

    @Published var hotKeyMask: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotKeyMask), forKey: "hotKeyMask") }
    }

    /// 打开/关闭设置面板的全局热键，默认 ⌃⌥⇧S
    @Published var settingsHotKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(settingsHotKeyCode), forKey: "settingsHotKeyCode") }
    }

    @Published var settingsHotKeyMask: UInt32 {
        didSet { UserDefaults.standard.set(Int(settingsHotKeyMask), forKey: "settingsHotKeyMask") }
    }

    /// 打开/关闭关于面板的全局热键，默认 ⌃⌥⇧A
    @Published var aboutHotKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(aboutHotKeyCode), forKey: "aboutHotKeyCode") }
    }

    @Published var aboutHotKeyMask: UInt32 {
        didSet { UserDefaults.standard.set(Int(aboutHotKeyMask), forKey: "aboutHotKeyMask") }
    }

    /// 热键变更时通知 AppDelegate 重新注册
    var onHotKeyChanged: ((UInt32, UInt32) -> Void)?

    /// 浮窗标题（可编辑，默认「讨论计时」）
    @Published var title: String {
        didSet {
            UserDefaults.standard.set(title, forKey: "panelTitle")
        }
    }

    /// 时间到的三声提示音
    @Published var soundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEnabled, forKey: Keys.sound)
        }
    }

    /// 最后 10 秒的每秒滴答声
    @Published var tickSoundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(tickSoundEnabled, forKey: Keys.tickSound)
        }
    }

    /// 把计时状态镜像到第二块屏（投影）
    @Published var projectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(projectionEnabled, forKey: Keys.projection)
        }
    }

    /// 是否检测到第二块屏幕（只有一块屏时投影开关不可用）
    @Published var hasExternalScreen = NSScreen.screens.count > 1

    /// 状态栏标题回调（MenuBar 图标旁显示剩余时间）
    var onStatusTitleChange: ((String) -> Void)?

    /// --verbose 时把操作打到 stderr，便于命令行排查
    func debugLog(_ message: String) {
        guard CommandLine.arguments.contains("--verbose") else { return }
        FileHandle.standardError.write("[timer] \(message)\n".data(using: .utf8)!)
    }

    private var ticker: Timer?
    private var flashTimer: Timer?
    private var deadline: Date?
    private var alarmSounds: [NSSound] = []

    /// 提示音方案。
    /// - classic：木鱼「ポク」+ 佛铃与台词（默认）
    /// - soft：纯合成的轻柔滴答 + 柔和钟声，没有台词
    /// - system：不依赖资源文件，用 macOS 系统提示音（Tink / Glass）
    enum SoundPack: String, CaseIterable {
        case classic, soft, system

        var label: String {
            switch self {
            case .classic: return "经典"
            case .soft: return "轻柔"
            case .system: return "系统"
            }
        }

        /// 滴答音的 wav 文件名（不含扩展名）；nil 表示用系统声
        var tickFile: String? {
            switch self {
            case .classic: return "woodblock"
            case .soft: return "soft-tick"
            case .system: return nil
            }
        }

        /// 结束提醒的 wav 文件名（不含扩展名）；nil 表示用系统声
        var chimeFile: String? {
            switch self {
            case .classic: return "rest-chime"
            case .soft: return "soft-chime"
            case .system: return nil
            }
        }
    }

    /// 提示音方案（切换后立即生效，不需要重启）
    @Published var soundPack: SoundPack {
        didSet {
            UserDefaults.standard.set(soundPack.rawValue, forKey: Keys.soundPack)
            reloadSounds()
        }
    }

    /// 最后 10 秒的滴答音（具体文件由「提示音方案」决定）
    private var tickSound: NSSound?

    /// 结束提醒（具体文件由「提示音方案」决定）
    private var restChime: NSSound?

    /// 上一次触发滴答用的整秒数，避免 0.1 秒刷新时重复响
    private var lastTickSecond = -1

    /// 结束铃+台词是否已播（在剩余 1 秒时触发，避免到点重复）
    private var finalChimePlayed = false

    private enum Keys {
        static let duration = "durationSeconds"
        static let sound = "soundEnabled"
        static let tickSound = "tickSoundEnabled"
        static let projection = "projectionEnabled"
        static let soundPack = "soundPack"
        static let multiSegment = "multiSegmentEnabled"
        static let segments = "segments"
    }

    // MARK: - 生命周期

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.double(forKey: Keys.duration)
        let initial = saved > 0 ? saved : 600   // 默认 10 分钟
        self.total = initial
        self.remaining = initial
        self.soundEnabled = defaults.object(forKey: Keys.sound) as? Bool ?? true
        self.tickSoundEnabled = defaults.object(forKey: Keys.tickSound) as? Bool ?? true
        self.projectionEnabled = defaults.object(forKey: Keys.projection) as? Bool ?? true
        self.soundPack = SoundPack(rawValue: defaults.string(forKey: Keys.soundPack) ?? "") ?? .classic
        self.multiSegmentEnabled = defaults.object(forKey: Keys.multiSegment) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.segments),
           let savedSegments = try? JSONDecoder().decode([Segment].self, from: data),
           savedSegments.count >= 2 {
            self.segments = savedSegments
        } else {
            self.segments = [
                Segment(name: "讨论", minutes: 5),
                Segment(name: "汇报", minutes: 3)
            ]
        }
        self.singleDuration = initial
        self.title = defaults.string(forKey: "panelTitle") ?? "讨论计时"
        if let saved = defaults.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: saved) {
            self.appearanceMode = mode
        }

        // 默认 ⌃⌥⌘Space / ⌃⌥⌘S / ⌃⌥⌘A（避开 Keynote 的空格、⌘P、⌥⌘P 与系统 ⌘Space）
        let ctrlOptCmd = Int(controlKey) | Int(optionKey) | Int(cmdKey)
        let savedCode = defaults.object(forKey: "hotKeyCode") as? Int
        let savedMask = defaults.object(forKey: "hotKeyMask") as? Int
        self.hotKeyCode = UInt32(savedCode ?? Int(kVK_Space))
        self.hotKeyMask = UInt32(savedMask ?? ctrlOptCmd)

        self.settingsHotKeyCode = UInt32(defaults.object(forKey: "settingsHotKeyCode") as? Int ?? Int(kVK_ANSI_S))
        self.settingsHotKeyMask = UInt32(defaults.object(forKey: "settingsHotKeyMask") as? Int ?? ctrlOptCmd)
        self.aboutHotKeyCode = UInt32(defaults.object(forKey: "aboutHotKeyCode") as? Int ?? Int(kVK_ANSI_A))
        self.aboutHotKeyMask = UInt32(defaults.object(forKey: "aboutHotKeyMask") as? Int ?? ctrlOptCmd)

        reloadSounds()

        // 若上次退出时分段计时是开启的，启动即以第一段作为当前时长（否则会显示单段时长）
        if multiSegmentEnabled, segments.count >= 2 {
            total = segments[0].seconds
            remaining = total
        }
    }

    // MARK: - 派生状态

    var fraction: Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, remaining / total))
    }

    /// 显示用的整秒数（向上取整，保持「还剩 1 秒」的感觉）
    var displaySeconds: Int {
        max(0, Int(remaining.rounded(.up)))
    }

    var timeString: String { Self.format(seconds: displaySeconds) }

    var totalString: String { Self.format(seconds: Int(total)) }

    var playLabel: String {
        switch phase {
        case .idle: return "开始"
        case .running: return "暂停"
        case .paused: return "继续"
        case .finished: return "再来一次"
        }
    }

    var playSymbol: String {
        switch phase {
        case .running: return "pause.fill"
        case .finished: return "arrow.clockwise"
        default: return "play.fill"
        }
    }

    var isRunning: Bool { phase == .running }

    // MARK: - 控制

    func toggle() {
        debugLog("toggle phase=\(phase)")
        switch phase {
        case .running:
            pause()
        case .paused:
            start()
        case .idle, .finished:
            start()
        }
    }

    func start() {
        debugLog("start phase=\(phase) remaining=\(remaining)")
        guard total > 0 else { return }
        // 分段模式：从第 0 段重新开始（暂停续跑时保留当前段）
        if isSegmented, phase == .idle || phase == .finished {
            currentSegmentIndex = 0
            total = segments[0].seconds
        }
        if phase != .paused {
            remaining = total
        }
        deadline = Date().addingTimeInterval(remaining)
        phase = .running
        isSettingsOpen = false
        lastTickSecond = -1
        finalChimePlayed = false
        startTicker()
        publishStatus()
    }

    func pause() {
        guard phase == .running else { return }
        if let deadline {
            remaining = max(0, deadline.timeIntervalSinceNow)
        }
        deadline = nil
        stopTicker()
        phase = .paused
        publishStatus()
    }

    func reset() {
        debugLog("reset")
        stopTicker()
        deadline = nil
        if isSegmented {
            currentSegmentIndex = 0
            total = segments[0].seconds
        }
        remaining = total
        phase = .idle
        lastTickSecond = -1
        finalChimePlayed = false
        stopFlash()
        publishStatus()
    }

    // MARK: - 分段

    private func persistSegments() {
        if let data = try? JSONEncoder().encode(segments) {
            UserDefaults.standard.set(data, forKey: Keys.segments)
        }
    }

    /// 段表/开关变化后重算总时长并回到待开始。
    /// 运行中改动会先 reset，避免「计时中段表被改」导致状态不一致。
    private func applySegmentsIfNeeded() {
        guard phase == .idle || phase == .finished else {
            reset()
            return
        }
        if isSegmented {
            currentSegmentIndex = 0
            total = segments[0].seconds
        } else {
            total = singleDuration
        }
        remaining = total
        deadline = nil
        phase = .idle
        lastTickSecond = -1
        finalChimePlayed = false
        stopTicker()
        stopFlash()
        publishStatus()
    }

    /// 设定总时长（会打断当前计时并回到待开始状态）
    func applyDuration(_ seconds: TimeInterval) {
        debugLog("applyDuration \(seconds)")
        // 选单段时长意味着退出分段模式：两者共用 total，混着用会打架
        if multiSegmentEnabled {
            multiSegmentEnabled = false
        }
        let clamped = min(Self.maxDuration, max(Self.minDuration, seconds))
        total = clamped
        remaining = clamped
        phase = .idle
        deadline = nil
        lastTickSecond = -1
        finalChimePlayed = false
        stopTicker()
        stopFlash()
        singleDuration = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Keys.duration)
        publishStatus()
    }

    /// 预设按钮：只改时长，保持设置面板展开，方便连续对比几个时长
    func selectDuration(_ seconds: TimeInterval) {
        applyDuration(seconds)
    }

    func stepDuration(by delta: TimeInterval) {
        applyDuration(total + delta)
    }

    // MARK: - 计时

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard phase == .running, let deadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            remaining = 0
            finish()
        } else {
            remaining = left
            tickLastSecondsIfNeeded()
        }
        publishStatus()
    }

    /// 最后 10 秒：每跨过一个整秒响一声滴答。
    /// 用整秒数变化做触发条件，0.1 秒的刷新频率不会重复响同一秒。
    private func tickLastSecondsIfNeeded() {
        let second = displaySeconds
        guard second != lastTickSecond else { return }
        lastTickSecond = second
        guard second > 0, second <= 10 else { return }

        if second == 1 {
            // 只有「最后一段」的最后一秒才起铃+台词；中间段结束时由 advanceToNextSegment
            // 播一声轻提示，避免每段都响 4.45 秒的佛铃。
            guard !isSegmented || currentSegmentIndex + 1 >= segments.count else { return }
            debugLog("final chime")
            playFinalChime()
        } else if tickSoundEnabled {
            debugLog("tick \(second)")
            tickSound?.stop()
            tickSound?.play()
        }
    }

    private func finish() {
        // 分段模式：本段走完就自动接下一段，最后一段才真正结束
        if isSegmented, currentSegmentIndex + 1 < segments.count {
            advanceToNextSegment()
            return
        }
        phase = .finished
        remaining = 0
        deadline = nil
        stopTicker()
        // 正常情况铃声已在剩余 1 秒时起播，这里只做兜底
        if !finalChimePlayed {
            playFinalChime()
        }
        startFlash()
        publishStatus()
    }

    /// 段与段之间不打断计时：一声轻提示 + 立刻进入下一段
    private func advanceToNextSegment() {
        _ = tickSound?.stop()
        tickSound?.play()
        currentSegmentIndex += 1
        total = segments[currentSegmentIndex].seconds
        remaining = total
        deadline = Date().addingTimeInterval(total)
        lastTickSecond = -1
        finalChimePlayed = false
        phase = .running
        debugLog("advance segment -> \(currentSegmentIndex + 1)/\(segments.count) \(segments[currentSegmentIndex].name)")
        publishStatus()
    }

    // MARK: - 结束提醒

    /// 佛铃 + 台词（一次完整播放，不被打断）
    private func playFinalChime() {
        guard soundEnabled, !finalChimePlayed else { return }
        finalChimePlayed = true
        alarmSounds = alarmSounds.filter { $0.isPlaying }
        if let chime = restChime?.copy() as? NSSound {
            chime.volume = 0.95
            chime.play()
            alarmSounds.append(chime)
            debugLog("chime 开始播放，时长 \(chime.duration)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + chime.duration + 0.3) {
                FileHandle.standardError.write(
                    "[sound] chime 播放结束检查 isPlaying=\(chime.isPlaying)\n".data(using: .utf8)!
                )
            }
        }
    }

    /// 按当前「提示音方案」重新加载两段声音；切换方案后立即生效。
    private func reloadSounds() {
        tickSound = Self.loadSound(file: soundPack.tickFile, system: "Tink", volume: 0.9)
        restChime = Self.loadSound(file: soundPack.chimeFile, system: "Glass", volume: 0.95)
        debugLog("soundPack=\(soundPack.rawValue)")
    }

    /// 从 App 包里的 Resources 加载 WAV；资源缺失（例如新 clone 没跑过合成脚本）时退回系统提示音，
    /// 保证不会因为少了 wav 就彻底没声音。
    private static func loadSound(file: String?, system systemName: String, volume: Float) -> NSSound? {
        if let file {
            if let url = Bundle.main.url(forResource: file, withExtension: "wav"),
               let sound = NSSound(contentsOf: url, byReference: false) {
                sound.volume = volume
                return sound
            }
            if CommandLine.arguments.contains("--verbose") {
                FileHandle.standardError.write("[sound] 缺失 \(file).wav，退回系统声 \(systemName)\n".data(using: .utf8)!)
            }
        }
        return systemSound(systemName, volume: volume)
    }

    /// 音频资源缺失时的兜底（开发期直接跑二进制时不至于没声音）
    private static func systemSound(_ name: String, volume: Float) -> NSSound? {
        guard let copy = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else {
            return nil
        }
        copy.volume = volume
        return copy
    }

    private func startFlash() {
        flashTimer?.invalidate()
        flash = true
        var remainingFlashes = 6
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            remainingFlashes -= 1
            if remainingFlashes <= 0 {
                timer.invalidate()
                self.flashTimer = nil
                self.flash = false
            } else {
                self.flash.toggle()
            }
        }
    }

    private func stopFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
        flash = false
    }

    // MARK: - 状态栏

    func publishStatus() {
        let prefix: String
        switch phase {
        case .idle: prefix = "⏱"
        case .running: prefix = "⏱"
        case .paused: prefix = "⏸"
        case .finished: prefix = "🔔"
        }
        onStatusTitleChange?("\(prefix) \(timeString)")
    }

    // MARK: - 工具

    static func format(seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
