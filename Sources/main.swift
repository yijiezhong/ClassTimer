import AppKit

// 纯代码 AppKit 应用入口：不加载 nib/storyboard，全部界面由 AppDelegate 构建。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 菜单栏 App，不占 Dock
app.run()
