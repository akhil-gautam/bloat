import SwiftUI

// MARK: - Card
struct Card<Content: View>: View {
    let title: String?
    var sub: String? = nil
    let content: () -> Content
    @EnvironmentObject var state: AppState
    init(title: String? = nil, sub: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.sub = sub; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(state.accent.gradient)
                        .frame(width: 3, height: 11)
                    Text(title).font(.system(size: 13, weight: .semibold)).tracking(-0.1).foregroundStyle(Tokens.text)
                    if let sub { Text(sub).font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.text3) }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, title == nil ? 16 : 0)
        }
        .metallic(radius: Tokens.Radius.lg)
    }
}

// MARK: - Pill
enum PillKind { case neutral, warn, danger, good }
struct Pill: View {
    let text: String
    var kind: PillKind = .neutral
    var dot: Bool = false
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(fg).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill(bg))
        .overlay(Capsule().stroke(border))
        .foregroundStyle(fg)
    }
    var bg: Color {
        switch kind {
        case .warn:   return Tokens.warn.opacity(0.12)
        case .danger: return Tokens.danger.opacity(0.12)
        case .good:   return Tokens.good.opacity(0.12)
        case .neutral: return Tokens.bgPanel2
        }
    }
    var border: Color {
        switch kind {
        case .warn:   return Tokens.warn.opacity(0.35)
        case .danger: return Tokens.danger.opacity(0.35)
        case .good:   return Tokens.good.opacity(0.35)
        case .neutral: return Tokens.border
        }
    }
    var fg: Color {
        switch kind {
        case .warn:   return Tokens.warn
        case .danger: return Tokens.danger
        case .good:   return Tokens.good
        case .neutral: return Tokens.text2
        }
    }
}

// MARK: - Switch
struct AppSwitch: View {
    @Binding var on: Bool
    var body: some View {
        Toggle("Enabled", isOn: $on).toggleStyle(.switch).labelsHidden()
    }
}

// MARK: - Checkbox
struct AppCheckbox: View {
    let on: Bool
    var label: String = "Select item"
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(on ? AnyShapeStyle(state.accent.gradient) : AnyShapeStyle(Tokens.bgPanel))
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .stroke(on ? state.accent.value : Tokens.borderStrong, lineWidth: 1.5)
            if on {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 14, height: 14)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "Selected" : "Not selected")
    }
}

// MARK: - Bar
struct ThinBar: View {
    let value: Double      // 0..1
    var kind: PillKind = .neutral
    var height: CGFloat = 6
    @EnvironmentObject var state: AppState
    var color: Color {
        switch kind {
        case .warn: return Tokens.warn
        case .danger: return Tokens.danger
        case .good: return Tokens.good
        case .neutral: return state.accent.value
        }
    }
    var tail: Color {
        kind == .neutral ? state.accent.companion : color.opacity(0.65)
    }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.bgPanel2)
                Capsule()
                    .fill(LinearGradient(colors: [tail, color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .shadow(color: color.opacity(0.5), radius: 4)
                    .animation(.easeOut(duration: 0.7), value: value)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Stat number
struct StatNum: View {
    let value: Double
    var unit: String? = nil
    var decimals: Int = 1
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            CountUp(value: value, decimals: decimals)
                .font(.system(size: 32, weight: .bold)).tracking(-1)
                .foregroundStyle(
                    LinearGradient(colors: [Tokens.text, Tokens.text2], startPoint: .top, endPoint: .bottom)
                )
            if let unit { Text(unit).font(.system(size: 16, weight: .semibold)).foregroundStyle(Tokens.text3) }
        }
        .monospacedDigit()
    }
}

// MARK: - SectionTitle
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Tokens.text4)
            .padding(.vertical, 8)
    }
}

// MARK: - AppIcon (square monogram)
struct AppIconBadge: View {
    let icon: String
    let color: Color
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            Text(icon).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
