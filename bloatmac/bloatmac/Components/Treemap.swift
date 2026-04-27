import SwiftUI

struct TreemapItem: Identifiable, Hashable {
    let id: String
    let name: String
    let size: Double
    let color: Color
}

struct TreemapTile {
    var x: CGFloat; var y: CGFloat; var w: CGFloat; var h: CGFloat
    let item: TreemapItem
}

func squarify(_ items: [TreemapItem], in rect: CGRect) -> [TreemapTile] {
    let total = items.reduce(0) { $0 + $1.size }
    guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
    let scale = (rect.width * rect.height) / total
    struct Scaled { let item: TreemapItem; let area: Double }
    let scaled = items.map { Scaled(item: $0, area: max(0.0001, $0.size * scale)) }
                      .sorted { $0.area > $1.area }

    var result: [TreemapTile] = []
    var queue = Array(scaled)
    var current = rect
    var row: [Scaled] = []

    func worst(_ row: [Scaled], len: Double) -> Double {
        guard !row.isEmpty else { return .infinity }
        let sum = row.reduce(0) { $0 + $1.area }
        let mx = row.map(\.area).max() ?? 0
        let mn = row.map(\.area).min() ?? .infinity
        let s2 = sum * sum
        let l2 = len * len
        return max((l2 * mx) / s2, s2 / (l2 * mn))
    }

    func layout(_ row: [Scaled], rect: CGRect) -> CGRect {
        let horizontal = rect.width >= rect.height
        let len = Double(horizontal ? rect.height : rect.width)
        let sum = row.reduce(0) { $0 + $1.area }
        let thickness = sum / len
        var pos: Double = 0
        for r in row {
            let breadth = r.area / thickness
            if horizontal {
                result.append(.init(
                    x: rect.minX, y: rect.minY + pos,
                    w: thickness, h: breadth, item: r.item))
            } else {
                result.append(.init(
                    x: rect.minX + pos, y: rect.minY,
                    w: breadth, h: thickness, item: r.item))
            }
            pos += breadth
        }
        if horizontal {
            return CGRect(x: rect.minX + thickness, y: rect.minY, width: rect.width - thickness, height: rect.height)
        } else {
            return CGRect(x: rect.minX, y: rect.minY + thickness, width: rect.width, height: rect.height - thickness)
        }
    }

    while !queue.isEmpty {
        let next = queue[0]
        let len = Double(min(current.width, current.height))
        if row.isEmpty {
            row = [next]; queue.removeFirst()
            continue
        }
        let wOld = worst(row, len: len)
        let wNew = worst(row + [next], len: len)
        if wNew <= wOld {
            row.append(next); queue.removeFirst()
        } else {
            current = layout(row, rect: current)
            row = []
        }
    }
    if !row.isEmpty { _ = layout(row, rect: current) }
    return result
}

struct Treemap: View {
    let items: [TreemapItem]
    var padding: CGFloat = 4
    var animateOrder: Bool = true
    var onSelect: ((TreemapItem) -> Void)? = nil
    var selectedId: String? = nil

    @State private var shown: Int = 0
    @State private var cascadeTask: Task<Void, Never>? = nil

    private func runCascade(to count: Int) {
        cascadeTask?.cancel()
        let from = shown
        if count <= from {
            shown = count
            return
        }
        cascadeTask = Task {
            for i in (from + 1)...count {
                try? await Task.sleep(nanoseconds: 60_000_000)
                if Task.isCancelled { return }
                await MainActor.run { shown = i }
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(x: padding, y: padding, width: geo.size.width - padding*2, height: geo.size.height - padding*2)
            let tiles = squarify(items, in: rect)
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { idx, t in
                    TileView(tile: t, total: items.reduce(0) { $0 + $1.size },
                             selected: selectedId == t.item.id,
                             visible: idx < shown,
                             onTap: { onSelect?(t.item) })
                        .frame(width: max(0, t.w - padding), height: max(0, t.h - padding))
                        .offset(x: t.x, y: t.y)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85).delay(Double(idx) * 0.018), value: shown)
                }
            }
            .onAppear {
                if !animateOrder { shown = tiles.count; return }
                runCascade(to: tiles.count)
            }
            .onChange(of: tiles.count) { _, newCount in
                if !animateOrder { shown = newCount; return }
                runCascade(to: newCount)
            }
        }
    }
}

private struct TileView: View {
    let tile: TreemapTile
    let total: Double
    let selected: Bool
    let visible: Bool
    let onTap: () -> Void

    @State private var hover = false

    var small: Bool { tile.w < 70 || tile.h < 50 }
    var tiny: Bool { tile.w < 40 || tile.h < 32 }
    var pct: Double { tile.item.size / total * 100 }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7).fill(tile.item.color)
                if !tiny {
                    VStack(alignment: .leading) {
                        Text(tile.item.name)
                            .font(.system(size: small ? 11 : 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                        Spacer()
                        VStack(alignment: .leading, spacing: 0) {
                            Text(String(format: tile.item.size >= 10 ? "%.0f GB" : "%.1f GB", tile.item.size))
                                .font(.system(size: small ? 11 : 18, weight: small ? .bold : .heavy))
                                .tracking(-0.5)
                                .foregroundStyle(.white)
                                .monospacedDigit()
                            if !small {
                                Text(String(format: "%.1f%%", pct))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                    .padding(small ? 8 : 12)
                }
            }
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? (hover ? 1.005 : 1) : 0.4)
            .offset(y: hover && visible ? -1 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(selected ? 1 : 0.06), lineWidth: selected ? 2 : 1)
            )
            .shadow(color: .black.opacity(hover ? 0.25 : 0), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
