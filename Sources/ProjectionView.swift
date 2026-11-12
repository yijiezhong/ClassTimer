import SwiftUI

/// 投到第二块屏（投影）的只读镜像。
///
/// 只显示剩余时间和进度，没有任何按钮——讲师在主屏的计时器上操作，
/// 投影屏这边跟着变；在投影屏上误点也不会改变计时状态。
struct ProjectionView: View {

    @ObservedObject var model: TimerModel

    static let width: CGFloat = 640
    static let height: CGFloat = 330

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 8)
            display
            Spacer(minLength: 8)
            progressBar
        }
        .padding(.horizontal, 36)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(width: Self.width, height: Self.height)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.18), value: model.phase)
        .animation(.linear(duration: 0.1), value: model.remaining)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.phase == .finished ? "时间到" : "讨论计时")
                .font(.system(size: 15, weight: .semibold))
                .tracking(3.4)
                .foregroundStyle(model.phase == .finished ? accent : Color.white.opacity(0.45))

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Spacer()

            Text("设定 \(model.totalString)")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.32))
        }
        .frame(height: 20)
    }

    private var display: some View {
        Text(model.timeString)
            .font(.system(size: 178, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .tracking(-4)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(digitColor)
            .shadow(color: model.phase == .finished ? accent.opacity(0.6) : .clear, radius: 30)
            .frame(maxWidth: .infinity)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.72), accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, geo.size.width * model.fraction))
            }
        }
        .frame(height: 9)
    }

    private var cardBackground: some View {
        ZStack {
            Color.black.opacity(0.86)
            LinearGradient(
                colors: [Color.white.opacity(0.04), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            Color(red: 1.0, green: 0.22, blue: 0.18)
                .opacity(model.flash ? 0.30 : 0)
        }
    }

    private var accent: Color {
        if model.phase == .finished { return Color(red: 1.0, green: 0.30, blue: 0.26) }
        guard model.phase == .running || model.phase == .paused else {
            return Color(red: 0.35, green: 0.62, blue: 1.0)
        }
        let warnWindow = min(30, max(5, model.total * 0.2))
        let urgentWindow = min(10, max(3, model.total * 0.1))
        if model.remaining <= urgentWindow { return Color(red: 1.0, green: 0.32, blue: 0.25) }
        if model.remaining <= warnWindow { return Color(red: 1.0, green: 0.70, blue: 0.18) }
        return Color(red: 0.35, green: 0.62, blue: 1.0)
    }

    private var digitColor: Color {
        switch model.phase {
        case .finished: return accent
        case .paused: return Color.white.opacity(0.55)
        default: return .white
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .idle: return Color.white.opacity(0.22)
        case .running: return Color(red: 0.30, green: 0.85, blue: 0.45)
        case .paused: return Color(red: 1.0, green: 0.70, blue: 0.18)
        case .finished: return Color(red: 1.0, green: 0.30, blue: 0.26)
        }
    }
}
