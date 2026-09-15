import SwiftUI

struct LargeFilesScreen: View {
    @ObservedObject private var live = LiveLargeFiles.shared
    @State private var selected: Set<URL> = []
    @State private var sort: Sort = .sizeDesc
    @State private var confirmTrash: Bool = false

    enum Sort: String, CaseIterable {
        case sizeDesc = "Size", ageDesc = "Oldest", nameAsc = "Name"
    }

    var sorted: [LargeFileItem] {
        switch sort {
        case .sizeDesc: return live.items.sorted { $0.sizeBytes > $1.sizeBytes }
        case .ageDesc:  return live.items.sorted { $0.ageDays > $1.ageDays }
        case .nameAsc:  return live.items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        ScreenScroll {
            header
            ActionError(message: live.lastError)
            if live.items.isEmpty && !live.scanning {
                EmptyState(
                    icon: "doc.badge.ellipsis",
                    title: "No large files yet",
                    message: "Scan your home directory and Applications for files at or above the size threshold (default: 100 MB).",
                    actionLabel: "Run scan", action: { live.scan() }
                )
                .frame(minHeight: 380)
            } else {
                tableCard
            }
        }
        .task { live.startIfNeeded() }
    }

    private var thresholdGB: Double { Double(live.thresholdMB) / 1000 }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Large Files").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.scanning { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.scanning, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                thresholdMenu
                sortMenu
                Btn(label: live.scanning ? "Scanning…" : "Rescan",
                    icon: "arrow.clockwise", style: .secondary) {
                    live.scan()
                }
                .disabled(live.scanning)
                if !selected.isEmpty {
                    Btn(label: "Move \(selected.count) to Trash", icon: "trash", style: .danger) {
                        confirmTrash = true
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .alert("Move \(selected.count) item(s) to Trash?",
               isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let n = live.moveToTrash(selected)
                selected.formIntersection(Set(live.items.map(\.id)))
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can be restored from Trash until you empty it.")
        }
    }

    private var headerSubtitle: String {
        if live.scanning {
            let pct = live.totalDirs > 0 ? Int(Double(live.scannedDirs) / Double(live.totalDirs) * 100) : 0
            return "Scanning… \(live.scannedDirs)/\(live.totalDirs) locations (\(pct)%) · \(live.items.count) found"
        }
        return "\(live.items.count) files ≥ \(live.thresholdMB) MB · \(live.totalSizeText) total"
    }

    private var thresholdMenu: some View {
        Menu {
            ForEach([50, 100, 250, 500, 1000, 2000], id: \.self) { mb in
                Button("≥ \(mb) MB") {
                    live.thresholdMB = mb
                    live.scan()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                Text("≥ \(live.thresholdMB) MB").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .glassChip()
            .foregroundStyle(Tokens.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(Sort.allCases, id: \.self) { s in
                Button(s.rawValue) { sort = s }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                Text(sort.rawValue).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .glassChip()
            .foregroundStyle(Tokens.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var tableCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { toggleSelectAll() } label: {
                    AppCheckbox(on: !selected.isEmpty && selected.count == live.items.count, label: "Select all large files")
                }.buttonStyle(.plain).frame(width: 22)
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("KIND").frame(width: 110, alignment: .leading)
                Text("SIZE").frame(width: 90, alignment: .trailing)
                Text("LAST USED").frame(width: 110, alignment: .trailing)
                Text("").frame(width: 28)
            }
            .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Tokens.text3)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Tokens.bgPanel2)

            Divider()

            LazyVStack(spacing: 0) {
                ForEach(sorted) { item in
                    LargeFileRow(item: item,
                                 selected: selected.contains(item.id),
                                 toggle: { toggle(item.id) })
                    Divider().padding(.leading, 14)
                }
            }
        }
        .glassPanel()
    }

    private func toggle(_ id: URL) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func toggleSelectAll() {
        if selected.count == live.items.count { selected.removeAll() }
        else { selected = Set(live.items.map(\.id)) }
    }
}

struct LargeFileRow: View {
    let item: LargeFileItem
    let selected: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: { AppCheckbox(on: selected, label: "Select \(item.name)") }
                .buttonStyle(.plain).frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(item.parent).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tokens.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.kind).font(.system(size: 11.5)).foregroundStyle(Tokens.text2).lineLimit(1)
                .frame(width: 110, alignment: .leading)

            Text(item.sizeText)
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)

            Text(item.ageText)
                .font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
                .frame(width: 110, alignment: .trailing)

            Button { LiveLargeFiles.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }
            .buttonStyle(.plain)
            .frame(width: 28)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Tokens.bgSelected : (hover ? Tokens.bgHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { LiveLargeFiles.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}

struct DuplicatesScreen: View {
    @ObservedObject private var live = LiveDuplicates.shared
    enum Tab: String, CaseIterable { case exact = "Exact", similar = "Similar images" }
    @State private var tab: Tab = .exact
    @State private var confirmResolve: Bool = false

    var body: some View {
        ScreenScroll {
            header
            ActionError(message: live.lastError)
            if live.totalGroups == 0 && !live.scanning {
                EmptyState(
                    icon: "doc.on.doc",
                    title: "No duplicates yet",
                    message: "Bloatmac hashes files and uses Apple's Vision framework to find visually similar images across your home directory.",
                    actionLabel: "Run scan", action: { live.scan() }
                )
                .frame(minHeight: 380)
            } else {
                if live.scanning { progressCard }
                tabBar
                groupsList
            }
        }
        .task { live.startIfNeeded() }
    }

    // MARK: header

    private var header: some View {
        let unkept = (live.exact + live.similar).reduce(0) { $0 + $1.items.filter { !$0.keep }.count }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Duplicates").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.scanning { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.scanning, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                Btn(label: "Pick exact copies", icon: "sparkles", style: .secondary) { live.smartPick() }
                    .disabled(live.totalGroups == 0)
                Btn(label: live.scanning ? "Scanning…" : "Rescan", icon: "arrow.clockwise", style: .secondary) { live.scan() }
                    .disabled(live.scanning)
                Btn(label: unkept > 0 ? "Resolve \(unkept) (\(live.totalRecoverableText))" : "Resolve",
                    icon: "trash", style: .danger) { confirmResolve = true }
                    .disabled(unkept == 0)
            }
        }
        .padding(.bottom, 4)
        .alert("Move \(unkeptCount) item(s) to Trash?", isPresented: $confirmResolve) {
            Button("Move to Trash", role: .destructive) {
                let n = live.resolveAll()
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(live.totalRecoverableText) selected for Trash. Review similar images individually. Space is released only after Trash is emptied.")
        }
    }

    private var unkeptCount: Int {
        (live.exact + live.similar).reduce(0) { $0 + $1.items.filter { !$0.keep }.count }
    }

    private var headerSubtitle: String {
        if live.scanning { return live.phase }
        if live.totalGroups == 0 { return "" }
        return "\(live.exact.count) exact · \(live.similar.count) visually similar · up to \(live.totalRecoverableText) recoverable"
    }

    // MARK: progress

    @ViewBuilder
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(live.phase).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int(live.progress * 100))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Tokens.text3)
            }
            ThinBar(value: live.progress)
            Text("Vision feature prints run on device; large image libraries may take a minute.")
                .font(.system(size: 11)).foregroundStyle(Tokens.text3)
        }
        .padding(16)
        .glassPanel()
    }

    // MARK: tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                let count = (t == .exact ? live.exact.count : live.similar.count)
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
                    HStack(spacing: 6) {
                        Text(t.rawValue).font(.system(size: 12, weight: .semibold))
                        if count > 0 {
                            Text("\(count)").font(.system(size: 10, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tab == t ? Color.white.opacity(0.25) : Tokens.bgPanel2))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tab == t ? Tokens.bgSelected : .clear))
                    .foregroundStyle(tab == t ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: groups

    private var currentGroups: [DupGroup] { tab == .exact ? live.exact : live.similar }

    @ViewBuilder
    private var groupsList: some View {
        if currentGroups.isEmpty && !live.scanning {
            VStack(spacing: 8) {
                Image(systemName: tab == .exact ? "checkmark.seal" : "photo.stack")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(Tokens.text3)
                Text(tab == .exact ? "No exact duplicates found" : "No visually similar images found")
                    .font(.system(size: 13, weight: .semibold))
                Text(tab == .exact
                     ? "Bloatmac compared file contents byte-for-byte and found nothing identical."
                     : "Vision compared image content; nothing crossed the similarity threshold.")
                    .font(.system(size: 11.5)).foregroundStyle(Tokens.text3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 60)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(currentGroups) { group in
                    DupGroupCard(group: group)
                }
            }
        }
    }
}

// MARK: - Group card

struct DupGroupCard: View {
    let group: DupGroup
    @ObservedObject private var live = LiveDuplicates.shared
    @State private var expanded: Bool = true

    private var recoverable: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: group.recoverableBytes)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
                        .frame(width: 14)
                    if group.kind == .similarImage, let first = group.items.first {
                        QLThumb(url: first.url, size: 40)
                    } else {
                        Image(systemName: kindIcon)
                            .font(.system(size: 16))
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel2))
                            .foregroundStyle(Tokens.text2)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.items.first?.name ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Pill(text: group.kind == .exact ? "Exact match" : "Visually similar",
                                 kind: group.kind == .exact ? .danger : .warn, dot: true)
                            Text("\(group.items.count) copies").font(.system(size: 11)).foregroundStyle(Tokens.text3)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(recoverable).font(.system(size: 13, weight: .heavy)).monospacedDigit()
                        Text("recoverable").font(.system(size: 10.5)).foregroundStyle(Tokens.text3)
                    }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                ForEach(group.items) { item in
                    DupItemRow(group: group, item: item)
                    Divider().padding(.leading, 14)
                }
            }
        }
        .glassPanel()
    }

    private var kindIcon: String {
        switch group.kind { case .exact: return "doc.on.doc"; case .similarImage: return "photo.stack" }
    }
}

struct DupItemRow: View {
    let group: DupGroup
    let item: DupItem
    @State private var hover = false

    private var sizeText: String {
        let bcf = ByteCountFormatter(); bcf.allowedUnits = [.useGB, .useMB, .useKB]; bcf.countStyle = .file
        return bcf.string(fromByteCount: item.sizeBytes)
    }
    private var modText: String {
        guard let d = item.modified else { return "—" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: d)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { LiveDuplicates.shared.toggleKeep(groupID: group.id, itemID: item.id) } label: {
                ZStack {
                    Circle().stroke(item.keep ? Tokens.good : Tokens.borderStrong, lineWidth: 1.5)
                    if item.keep { Circle().fill(Tokens.good).padding(3) }
                }
                .frame(width: 16, height: 16)
            }.buttonStyle(.plain)
                .help(item.keep ? "Will be kept" : "Will be moved to Trash")

            if group.kind == .similarImage {
                QLThumb(url: item.url, size: 48)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(!item.keep, color: Tokens.text3)
                    .foregroundStyle(item.keep ? Tokens.text : Tokens.text3)
                Text(item.parent).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tokens.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let dist = item.visualDistance {
                Pill(text: String(format: "Δ %.2f", dist), kind: .neutral, dot: true)
                    .help("Vision distance from cluster representative — lower is more similar (0 = identical).")
            }

            Text(modText).font(.system(size: 11.5)).foregroundStyle(Tokens.text3).frame(width: 110, alignment: .trailing)
            Text(sizeText).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().frame(width: 90, alignment: .trailing)

            Button { LiveDuplicates.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }.buttonStyle(.plain).frame(width: 28).help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(hover ? Tokens.bgHover : Color.clear)
        .onTapGesture(count: 2) { LiveDuplicates.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}

struct UnusedScreen: View {
    @ObservedObject private var live = LiveUnused.shared
    @State private var selected: Set<URL> = []
    @State private var tab: Tab = .apps
    @State private var confirmTrash: Bool = false

    enum Tab: String, CaseIterable { case apps = "Apps", files = "Files & folders" }

    private var current: [UnusedEntry] {
        tab == .apps ? live.apps : live.files
    }

    var body: some View {
        ScreenScroll {
            header
            ActionError(message: live.lastError)
            if live.totalCount == 0 && !live.scanning {
                EmptyState(
                    icon: "clock.badge.questionmark",
                    title: "Nothing flagged as unused",
                    message: "Bloatmac uses Spotlight's last-used metadata for apps and access timestamps for files. Adjust the threshold or run a scan.",
                    actionLabel: "Run scan", action: { live.scan() }
                )
                .frame(minHeight: 380)
            } else {
                if live.scanning { progressCard }
                tabBar
                listCard
            }
        }
        .task { live.startIfNeeded() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Unused & Old").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.scanning { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.scanning, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                thresholdMenu
                Btn(label: live.scanning ? "Scanning…" : "Rescan",
                    icon: "arrow.clockwise", style: .secondary) { live.scan() }
                    .disabled(live.scanning)
                if !selected.isEmpty {
                    Btn(label: "Move \(selected.count) to Trash", icon: "trash", style: .danger) {
                        confirmTrash = true
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .alert("Move \(selected.count) item(s) to Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let n = live.moveToTrash(selected)
                selected.formIntersection(Set((live.apps + live.files).map(\.id)))
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items can be restored from Trash until you empty it.")
        }
    }

    private var headerSubtitle: String {
        if live.scanning { return live.phase }
        if live.totalCount == 0 { return "" }
        return "\(live.apps.count) apps · \(live.files.count) files & folders · \(live.totalText) to review · older than \(live.thresholdDays) days"
    }

    private var thresholdMenu: some View {
        Menu {
            ForEach([60, 120, 180, 365, 730], id: \.self) { days in
                Button(thresholdLabel(days)) {
                    live.thresholdDays = days
                    live.scan()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                Text("> \(thresholdLabel(live.thresholdDays))").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .glassChip()
            .foregroundStyle(Tokens.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func thresholdLabel(_ days: Int) -> String {
        if days >= 365 { return "\(days/365) year\(days/365 > 1 ? "s" : "")" }
        if days >= 30 { return "\(days/30) months" }
        return "\(days) days"
    }

    @ViewBuilder
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(live.phase).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int(live.progress * 100))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Tokens.text3)
            }
            ThinBar(value: live.progress)
        }
        .padding(16)
        .glassPanel()
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                let count = (t == .apps ? live.apps.count : live.files.count)
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = t; selected.removeAll() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t == .apps ? "app.dashed" : "folder")
                            .font(.system(size: 11, weight: .semibold))
                        Text(t.rawValue).font(.system(size: 12, weight: .semibold))
                        if count > 0 {
                            Text("\(count)").font(.system(size: 10, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tab == t ? Color.white.opacity(0.25) : Tokens.bgPanel2))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tab == t ? Tokens.bgSelected : .clear))
                    .foregroundStyle(tab == t ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var listCard: some View {
        if current.isEmpty && !live.scanning {
            VStack(spacing: 8) {
                Image(systemName: tab == .apps ? "checkmark.seal" : "folder.badge.minus")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(Tokens.text3)
                Text(tab == .apps ? "All your apps are in active use" : "No old files in tracked folders")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 60)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { toggleSelectAll() } label: {
                        AppCheckbox(on: !selected.isEmpty && selected.count == current.count, label: "Select all visible items")
                    }.buttonStyle(.plain).frame(width: 22)
                    Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                    Text("LOCATION").frame(width: 200, alignment: .leading)
                    Text("LAST USED").frame(width: 110, alignment: .trailing)
                    Text("SIZE").frame(width: 90, alignment: .trailing)
                    Text("").frame(width: 28)
                }
                .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Tokens.text3)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Tokens.bgPanel2)
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(current) { item in
                        UnusedEntryRow(item: item,
                                      selected: selected.contains(item.id),
                                      toggle: { toggle(item.id) })
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .glassPanel()
        }
    }

    private func toggle(_ id: URL) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func toggleSelectAll() {
        if selected.count == current.count { selected.removeAll() }
        else { selected = Set(current.map(\.id)) }
    }
}

struct UnusedEntryRow: View {
    let item: UnusedEntry
    let selected: Bool
    let toggle: () -> Void
    @State private var hover = false

    private var icon: String {
        switch item.kind {
        case .app: return "app.dashed"
        case .folder: return "folder"
        case .file: return "doc"
        }
    }
    private var iconColor: Color {
        switch item.kind {
        case .app: return Tokens.catApps
        case .folder: return Tokens.catDocs
        case .file: return Tokens.text2
        }
    }
    private var ageColor: Color {
        if item.ageDays >= 365 { return Tokens.danger }
        if item.ageDays >= 180 { return Tokens.warn }
        return Tokens.text3
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: { AppCheckbox(on: selected, label: "Select \(item.name)") }
                .buttonStyle(.plain).frame(width: 22)

            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(iconColor.opacity(0.12)))
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.parent)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .frame(width: 200, alignment: .leading)

            Text(item.ageText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ageColor)
                .frame(width: 110, alignment: .trailing)

            Text(item.sizeText)
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)

            Button { LiveUnused.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }
            .buttonStyle(.plain).frame(width: 28).help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Tokens.bgSelected : (hover ? Tokens.bgHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { LiveUnused.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}

struct DownloadsCacheScreen: View {
    @ObservedObject private var live = LiveDownloadsCache.shared
    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .downloads
    @State private var selectedDownloads: Set<URL> = []
    @State private var selectedCaches: Set<URL> = []
    @State private var filterCategory: DownloadCategory? = nil
    @State private var confirmTrash: Bool = false
    @State private var confirmCleanCache: Bool = false

    enum Tab: String, CaseIterable { case downloads = "Downloads", caches = "App caches" }

    var body: some View {
        ScreenScroll {
            header
            ActionError(message: live.lastError)
            if live.totalCount == 0 && !live.scanning {
                EmptyState(
                    icon: "arrow.down.circle",
                    title: "Nothing to clean yet",
                    message: "Bloatmac inventories ~/Downloads and per-app caches. Spotlight is consulted for download-source URLs.",
                    actionLabel: "Run scan", action: { live.scan() }
                )
                .frame(minHeight: 380)
            } else {
                if live.scanning { progressCard }
                tabBar
                if tab == .downloads { downloadsView } else { cachesView }
            }
        }
        .task { live.startIfNeeded() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Downloads & Cache").font(.system(size: 28, weight: .heavy)).tracking(-0.5)
                    if live.scanning { PulsingDot(color: Tokens.warn, size: 9) }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .shimmer(active: live.scanning, color: Tokens.warn)
            }
            Spacer()
            HStack(spacing: 8) {
                Btn(label: live.scanning ? "Scanning…" : "Rescan",
                    icon: "arrow.clockwise", style: .secondary) { live.scan() }
                    .disabled(live.scanning)
                if tab == .downloads, !selectedDownloads.isEmpty {
                    Btn(label: "Move \(selectedDownloads.count) to Trash", icon: "trash", style: .danger) {
                        confirmTrash = true
                    }
                }
                if tab == .caches, !selectedCaches.isEmpty {
                    Btn(label: "Clean \(selectedCaches.count) cache\(selectedCaches.count > 1 ? "s" : "")", icon: "sparkles", style: .primary) {
                        confirmCleanCache = true
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .alert("Move \(selectedDownloads.count) item(s) to Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let n = live.trashDownloads(selectedDownloads); selectedDownloads.formIntersection(Set(live.downloads.map(\.id)))
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Empty \(selectedCaches.count) cache director\(selectedCaches.count > 1 ? "ies" : "y")?",
               isPresented: $confirmCleanCache) {
            Button("Clean", role: .destructive) {
                let n = live.cleanCaches(selectedCaches); selectedCaches.formIntersection(Set(live.caches.map(\.id)))
                if n > 0 { LiveStorage.shared.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each app will rebuild its cache the next time it runs.")
        }
    }

    private var headerSubtitle: String {
        if live.scanning { return live.phase }
        if live.totalCount == 0 { return "" }
        return "\(live.downloads.count) downloads (\(live.totalDownloadsText)) · \(live.caches.count) caches · up to \(live.safeCleanText) safe to clean"
    }

    @ViewBuilder
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(live.phase).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int(live.progress * 100))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Tokens.text3)
            }
            ThinBar(value: live.progress)
        }
        .padding(16)
        .glassPanel()
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                let count = (t == .downloads ? live.downloads.count : live.caches.count)
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t == .downloads ? "arrow.down.circle" : "tray.full")
                            .font(.system(size: 11, weight: .semibold))
                        Text(t.rawValue).font(.system(size: 12, weight: .semibold))
                        if count > 0 {
                            Text("\(count)").font(.system(size: 10, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tab == t ? Color.white.opacity(0.25) : Tokens.bgPanel2))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tab == t ? Tokens.bgSelected : .clear))
                    .foregroundStyle(tab == t ? Tokens.text : Tokens.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tokens.bgPanel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.border))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Downloads view

    private var filteredDownloads: [DLEntry] {
        guard let f = filterCategory else { return live.downloads }
        return live.downloads.filter { $0.category == f }
    }

    @ViewBuilder
    private var downloadsView: some View {
        categoryFilterChips
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { toggleSelectAllDownloads() } label: {
                    AppCheckbox(on: !selectedDownloads.isEmpty && selectedDownloads.count == filteredDownloads.count, label: "Select all visible downloads")
                }.buttonStyle(.plain).frame(width: 22)
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("FROM").frame(width: 160, alignment: .leading)
                Text("DOWNLOADED").frame(width: 110, alignment: .trailing)
                Text("SIZE").frame(width: 90, alignment: .trailing)
                Text("").frame(width: 28)
            }
            .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Tokens.text3)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Tokens.bgPanel2)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(filteredDownloads) { item in
                    DownloadRow(item: item,
                                selected: selectedDownloads.contains(item.id),
                                toggle: { toggleDownload(item.id) })
                    Divider().padding(.leading, 14)
                }
            }
        }
        .glassPanel()
    }

    @ViewBuilder
    private var categoryFilterChips: some View {
        let counts = Dictionary(grouping: live.downloads, by: \.category).mapValues(\.count)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "All", count: live.downloads.count, color: state.accent.value, active: filterCategory == nil, showDot: false) {
                    filterCategory = nil; selectedDownloads.removeAll()
                }
                ForEach(DownloadCategory.allCases, id: \.self) { cat in
                    let c = counts[cat] ?? 0
                    if c > 0 {
                        chip(label: cat.label, count: c, color: cat.color, active: filterCategory == cat, showDot: true) {
                            filterCategory = (filterCategory == cat ? nil : cat)
                            selectedDownloads.removeAll()
                        }
                    }
                }
            }
        }
    }

    private func chip(label: String, count: Int, color: Color, active: Bool, showDot: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showDot {
                    Circle().fill(active ? Color.white : color).frame(width: 6, height: 6)
                }
                Text(label).font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .heavy))
                    .monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(active ? Color.white.opacity(0.22) : Tokens.bgPanel2))
                    .foregroundStyle(active ? Color.white : Tokens.text3)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? color : Tokens.bgPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(active ? Color.clear : Tokens.border, lineWidth: 1)
            )
            .foregroundStyle(active ? Color.white : Tokens.text)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func toggleDownload(_ id: URL) {
        if selectedDownloads.contains(id) { selectedDownloads.remove(id) } else { selectedDownloads.insert(id) }
    }
    private func toggleSelectAllDownloads() {
        let visible = filteredDownloads
        if selectedDownloads.count == visible.count { selectedDownloads.removeAll() }
        else { selectedDownloads = Set(visible.map(\.id)) }
    }

    // MARK: - Caches view

    @ViewBuilder
    private var cachesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { toggleSelectAllCaches() } label: {
                    AppCheckbox(on: !selectedCaches.isEmpty && selectedCaches.count == live.caches.filter(\.safeToClean).count, label: "Select all eligible caches")
                }.buttonStyle(.plain).frame(width: 22)
                Text("APP / SOURCE").frame(maxWidth: .infinity, alignment: .leading)
                Text("LAST WRITE").frame(width: 110, alignment: .trailing)
                Text("SIZE").frame(width: 100, alignment: .trailing)
                Text("STATUS").frame(width: 110, alignment: .trailing)
                Text("").frame(width: 28)
            }
            .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Tokens.text3)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Tokens.bgPanel2)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(live.caches) { c in
                    CacheRow(item: c,
                             selected: selectedCaches.contains(c.id),
                             toggle: { toggleCache(c.id) })
                    Divider().padding(.leading, 14)
                }
            }
        }
        .glassPanel()
    }

    private func toggleCache(_ id: URL) {
        if selectedCaches.contains(id) { selectedCaches.remove(id) } else { selectedCaches.insert(id) }
    }
    private func toggleSelectAllCaches() {
        let onlySafe = live.caches.filter(\.safeToClean).map(\.id)
        if selectedCaches == Set(onlySafe) { selectedCaches.removeAll() }
        else { selectedCaches = Set(onlySafe) }
    }
}

struct DownloadRow: View {
    let item: DLEntry
    let selected: Bool
    let toggle: () -> Void
    @State private var hover = false
    @State private var ocrOpen = false
    @ObservedObject private var live = LiveDownloadsCache.shared
    @EnvironmentObject private var state: AppState

    private var ocrState: DownloadOCRState { live.ocrState(for: item) }
    private var isOCREligible: Bool {
        if case .unsupported = ocrState { return false }
        return true
    }
    private var ocrText: String? {
        if case .text(let text) = ocrState { return text }
        return nil
    }
    private var ocrLoading: Bool {
        switch ocrState { case .idle, .loading: return true; default: return false }
    }
    private var ocrMessage: String? {
        switch ocrState {
        case .noText: return "No text found"
        case .failed(let reason): return "Text recognition failed: \(reason)"
        case .unsupported:
            return LiveDownloadsCache.ocrEligibleExtensions.contains(item.url.pathExtension.lowercased()) ? "Text recognition supports images up to 30 MB" : nil
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: { AppCheckbox(on: selected, label: "Select \(item.name)") }
                .buttonStyle(.plain).frame(width: 22)

            HStack(spacing: 8) {
                if isOCREligible {
                    QLThumb(url: item.url, size: 36)
                } else {
                    Image(systemName: item.category.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(item.category.color)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 6).fill(item.category.color.opacity(0.15)))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.kind).font(.system(size: 10.5)).foregroundStyle(Tokens.text3).lineLimit(1)
                        if let text = ocrText {
                            Button { ocrOpen = true } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "text.viewfinder").font(.system(size: 9, weight: .semibold))
                                    Text("“\(text)”")
                                        .font(.system(size: 10.5, design: .serif)).italic()
                                        .lineLimit(1)
                                }
                                .foregroundStyle(state.accent.value)
                            }
                            .buttonStyle(.plain)
                            .help("Click to view full recognized text")
                            .popover(isPresented: $ocrOpen, arrowEdge: .bottom) {
                                OCRPreviewPopover(name: item.name, text: text)
                            }
                        } else if ocrLoading {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini).scaleEffect(0.55)
                                Text("Reading text…").font(.system(size: 10)).foregroundStyle(Tokens.text3)
                            }
                        } else if let message = ocrMessage {
                            Text(message).font(.system(size: 10)).foregroundStyle(Tokens.text3)
                                .lineLimit(1).help(message)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { live.ocrIfEligible(for: item) }

            HStack(spacing: 4) {
                if let src = item.sourceDomain, !src.isEmpty {
                    Image(systemName: "link").font(.system(size: 10))
                    Text(src).font(.system(size: 11.5)).lineLimit(1)
                } else {
                    Text("—").font(.system(size: 11.5))
                }
            }
            .foregroundStyle(Tokens.text3)
            .frame(width: 160, alignment: .leading)

            Text(item.ageText)
                .font(.system(size: 11.5))
                .foregroundStyle(item.ageDays > 30 ? Tokens.warn : Tokens.text3)
                .frame(width: 110, alignment: .trailing)

            Text(item.sizeText)
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)

            Button { LiveDownloadsCache.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }.buttonStyle(.plain).frame(width: 28).help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Tokens.bgSelected : (hover ? Tokens.bgHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { LiveDownloadsCache.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}

struct OCRPreviewPopover: View {
    let name: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.viewfinder")
                Text("Recognized text").font(.system(size: 12, weight: .bold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                        Text(copied ? "Copied" : "Copy").font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
            }
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.text)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .frame(maxHeight: 240)
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 9))
                Text("Extracted by Apple Vision · Recognize Text")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Tokens.text4)
        }
        .padding(14)
        .frame(width: 380)
    }
}

struct CacheRow: View {
    let item: AppCacheEntry
    let selected: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: { AppCheckbox(on: selected, label: "Select \(item.displayName)") }
                .buttonStyle(.plain).frame(width: 22)
                .opacity(item.safeToClean ? 1 : 0.4)
                .disabled(!item.safeToClean)

            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.safeToClean ? Tokens.good : Tokens.warn)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill((item.safeToClean ? Tokens.good : Tokens.warn).opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(item.bundleID).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tokens.text3).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.ageText)
                .font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
                .frame(width: 110, alignment: .trailing)

            Text(item.sizeText)
                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                .frame(width: 100, alignment: .trailing)

            HStack {
                Spacer()
                Pill(text: item.safeToClean ? "Safe" : "Keep",
                     kind: item.safeToClean ? .good : .warn, dot: true)
                    .help(item.cleanReason ?? "")
            }
            .frame(width: 110, alignment: .trailing)

            Button { LiveDownloadsCache.shared.revealInFinder(item.url) } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Tokens.text : Tokens.text3)
            }.buttonStyle(.plain).frame(width: 28).help("Reveal in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Tokens.bgSelected : (hover ? Tokens.bgHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { LiveDownloadsCache.shared.revealInFinder(item.url) }
        .onHover { hover = $0 }
    }
}
