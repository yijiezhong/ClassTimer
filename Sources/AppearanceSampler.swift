import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// 采样浮窗「下方」的背景亮度，用来决定浮窗走深色还是浅色。
///
/// 旧实现用 `CGWindowListCreateImage(.optionOnScreenBelowWindow)`，但该 API 在
/// macOS 14+ 已被标记 unavailable、在新系统上直接返回 nil。这里改用
/// ScreenCaptureKit：用 SCContentFilter 把浮窗自身排除掉，截到的就是背景。
final class AppearanceSampler {

    /// 亮度高于此值视为「背景偏亮」
    private let threshold: CGFloat = 0.52
    /// 滞回带，避免临界附近来回跳
    private let hysteresis: CGFloat = 0.08

    private var timer: Timer?
    private var lastResult: Bool?
    private var candidate: Bool?
    private var isSampling = false
    private var lastLog: String = ""

    /// 回调：true = 背景偏亮（自动模式下浮窗会用深色卡片）
    var onChange: ((Bool) -> Void)?

    private weak var targetWindow: NSWindow?

    func start(window: NSWindow) {
        stop()
        targetWindow = window
        log("start")
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !isSampling, let window = targetWindow else { return }

        // 没有屏幕录制权限时直接停掉采样。
        // 不这么做的后果：SCShareableContent 每次调用都会触发系统
        // 「ClassTimer 想要录制屏幕」的弹窗，而采样每 0.8 秒跑一次，
        // 看起来就是「反复弹窗要授权」。
        guard CGPreflightScreenCaptureAccess() else {
            log("no permission -> stop sampling, fallback to system appearance")
            stop()
            fallbackToSystemAppearance()
            return
        }

        isSampling = true

        // 窗口几何必须在主线程先取成值再交给异步采样：
        // NSWindow.windowNumber / frame 都是 MainActor 隔离属性，
        // 后台 Task 里直接访问在 Swift 6 语言模式下会报错（当前只是 warning）。
        let windowNumber = window.windowNumber
        let windowFrame = window.frame
        Task { [weak self] in
            defer { Task { @MainActor in self?.isSampling = false } }
            await self?.sample(windowNumber: windowNumber, windowFrame: windowFrame)
        }
    }

    private func sample(windowNumber: Int, windowFrame: CGRect) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // 找到自己这个窗口，从截图里排除掉
            guard let ownWindow = content.windows.first(where: {
                $0.windowID == CGWindowID(windowNumber)
            }) else {
                log("own window not found")
                return
            }
            // 必须选「窗口所在的那块屏」，否则会把主屏的坐标套到副屏内容上，
            // 采到的是桌面壁纸而不是浮窗背后的幻灯片。
            let winFrameForDisplay = windowFrame
            let display = content.displays.first { $0.frame.intersects(winFrameForDisplay) }
                ?? content.displays.first
            guard let display else {
                log("no display")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [ownWindow])
            let config = SCStreamConfiguration()
            config.width = 128
            config.height = 128
            config.showsCursor = false
            config.capturesAudio = false

            // 只采浮窗那块区域：编辑模式下整屏会被工具栏/桌面稀释，必须看「窗口背后」。
            // 坐标系：NSWindow.frame 是屏幕坐标（左下原点），SCStreamConfiguration.sourceRect
            // 要的是 display 本地坐标（左上原点），所以 y 要做一次翻转。
            let winFrame = windowFrame
            let displayFrame = display.frame
            let displayHeight = CGFloat(display.height)
            let relX = winFrame.minX - displayFrame.minX
            let relY = winFrame.minY - displayFrame.minY
            let topY = displayHeight - (relY + winFrame.height)
            config.sourceRect = CGRect(
                x: relX,
                y: topY,
                width: winFrame.width,
                height: winFrame.height
            )

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            guard let luminance = Self.averageLuminance(image) else { return }
            log(String(format: "lum=%.2f", luminance))
            apply(luminance: luminance)
        } catch {
            log("capture error: \(error.localizedDescription)")
            fallbackToSystemAppearance()
        }
    }

    private func apply(luminance: CGFloat) {
        let backgroundIsBright: Bool
        if let lastResult {
            // 滞回：只在明显跨过阈值时才切换
            backgroundIsBright = lastResult
                ? luminance > threshold - hysteresis
                : luminance > threshold + hysteresis
        } else {
            backgroundIsBright = luminance > threshold
        }

        if candidate == backgroundIsBright {
            if lastResult != backgroundIsBright {
                lastResult = backgroundIsBright
                onChange?(backgroundIsBright)
            }
        } else {
            candidate = backgroundIsBright
        }
    }

    /// 截图不可用时退化为跟随系统外观
    private func fallbackToSystemAppearance() {
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let backgroundIsBright = !systemDark
        guard lastResult != backgroundIsBright else { return }
        lastResult = backgroundIsBright
        onChange?(backgroundIsBright)
    }

    private func log(_ message: String) {
        guard CommandLine.arguments.contains("--verbose") else { return }
        let line = "[sampler] \(message)"
        guard line != lastLog else { return }   // 同样的日志不重复刷
        lastLog = line
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }

    /// 缩到 16×16，只取中心 50% 区域求亮度中位数（0–1）。
    /// 用中位数而不是平均值：幻灯片边缘、文字、窗口阴影都会拉低平均值，
    /// 中位数只看「多数像素是什么颜色」，更贴近人眼对背景的判断。
    static func averageLuminance(_ image: CGImage) -> CGFloat? {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        // 只取中心那一半，避开窗口边缘
        let lo = size / 4
        let hi = size - lo
        var values: [CGFloat] = []
        values.reserveCapacity((hi - lo) * (hi - lo))
        for y in lo..<hi {
            for x in lo..<hi {
                let i = (y * size + x) * 4
                let r = CGFloat(pixels[i]) / 255
                let g = CGFloat(pixels[i + 1]) / 255
                let b = CGFloat(pixels[i + 2]) / 255
                values.append(0.299 * r + 0.587 * g + 0.114 * b)
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }
}
