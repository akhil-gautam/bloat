import SwiftUI

struct ThreatHygieneScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var h = LiveThreatHygiene.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    if h.findings.isEmpty && !h.scanning { emptyState }
                    summaryCard
                    ForEach(HygieneCategory.allCases, id: \.self) { cat in
                        if let rows = h.byCategory[cat], !rows.isEmpty {
                            categorySection(cat, rows: rows)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
        .task { h.startIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Threat Hygiene").font(.system(size: 22, weight: .bold))
                Text("Heuristic audit of code signatures, persistence, browser extensions, and quarantine residue. Not a virus scanner — Apple's XProtect handles that.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.text3)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 540, alignment: .leading)
            }
            Spacer()
            if h.scanning {
                ProgressView().controlSize(.small)
            } else {
                Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) { h.scan() }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var summaryCard: some View {
        let actionable = h.actionable
        let critical   = actionable.filter { $0.severity == .critical }.count
        let warning    = actionable.filter { $0.severity == .warning }.count
        let info       = actionable.filter { $0.severity == .info }.count
        let allGood    = critical == 0 && warning == 0
        return HStack(spacing: 14) {
            Image(systemName: allGood ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 26))
                .foregroundStyle(critical > 0 ? Tokens.danger : warning > 0 ? Tokens.warn : Tokens.good)
            VStack(alignment: .leading, spacing: 2) {
                Text(allGood ? "Nothing critical detected" : "Review \(critical + warning) finding\(critical + warning == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.text)
                HStack(spacing: 12) {
                    if critical > 0 { countPill("\(critical) critical", Tokens.danger) }
                    if warning  > 0 { countPill("\(warning) warning",   Tokens.warn) }
                    if info     > 0 { countPill("\(info) info",         Tokens.text3) }
                }
                .font(.system(size: 11))
            }
            Spacer()
        }
        .padding(16)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func countPill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func categorySection(_ cat: HygieneCategory, rows: [HygieneFinding]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: cat.icon).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.accent.value)
                Text(cat.label).font(.system(size: 13, weight: .bold)).foregroundStyle(Tokens.text)
                Spacer()
                Text("\(rows.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider().opacity(0.4)
            ForEach(rows) { row in
                findingRow(row)
                Divider().opacity(0.4)
            }
        }
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func findingRow(_ r: HygieneFinding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            severityDot(r.severity)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text(r.detail).font(.system(size: 11)).foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if !r.recommendation.isEmpty {
                    Text(r.recommendation).font(.system(size: 11)).foregroundStyle(Tokens.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let url = r.path {
                Button {
                    h.revealInFinder(url)
                } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 13))
                }.buttonStyle(.plain).foregroundStyle(Tokens.text3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func severityDot(_ s: HygieneSeverity) -> some View {
        let color: Color = {
            switch s {
            case .critical: return Tokens.danger
            case .warning:  return Tokens.warn
            case .info:     return Tokens.text3
            case .ok:       return Tokens.good
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.checkered").font(.system(size: 32)).foregroundStyle(Tokens.text3)
            Text("Run a scan to audit your Mac's hygiene").font(.system(size: 13, weight: .semibold))
            Text("Takes about 15 seconds.").font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}
