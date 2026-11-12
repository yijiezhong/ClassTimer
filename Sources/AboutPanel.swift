import AppKit
import SwiftUI

/// 嵌在主浮窗里的「关于」面板（点快捷键或菜单展开，与设置面板同一套机制）。
struct AboutPanel: View {

    @ObservedObject var model: TimerModel

    private var palette: Palette { Palette(isLight: model.isLightMode) }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "版本 \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                .padding(.top, 4)

            Text("Class Timer")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .padding(.top, 10)

            Text(versionText)
                .font(.system(size: 12))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
                .padding(.top, 6)

            Text("累了就休息一下吧")
                .font(.system(size: 13))
                .foregroundStyle(palette.primaryText.opacity(0.9))
                .padding(.top, 10)

            Text("© 钟义杰")
                .font(.system(size: 11))
                .foregroundStyle(palette.primaryText)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
    }
}
