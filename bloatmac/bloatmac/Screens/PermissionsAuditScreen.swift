import SwiftUI

struct PermissionsAuditScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var p = LivePermissionsAudit.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(p.categories) { cat in
                        categoryCard(cat)
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
        .task { p.startIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions Audit").font(.system(size: 22, weight: .bold))
                Text("Apps that declare TCC permission requests in their Info.plist. Granted state isn't readable; tap a category to manage in System Settings.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if p.scanning {
                ProgressView().controlSize(.small)
            } else {
                Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) { p.scan() }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    @ViewBuilder
    private func categoryCard(_ cat: PermissionCategory) -> some View {
        let isOpen = expanded.contains(cat.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if cat.isInfoPlistDriven { toggle(cat.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: cat.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(state.accent.value)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Tokens.bgPanel2))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(cat.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.text)
                            if !cat.isInfoPlistDriven { managedPill }
                        }
                        if cat.isInfoPlistDriven {
                            Text("\(cat.apps.count) app\(cat.apps.count == 1 ? "" : "s") declared this in Info.plist")
                                .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                        } else {
                            Text("Managed via TCC. Open System Settings to inspect grants.")
                                .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                        }
                    }
                    Spacer()
                    Btn(label: "Settings", icon: "gearshape", style: .ghost) {
                        p.openSettings(for: cat)
                    }
                    if cat.isInfoPlistDriven {
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                    }
                }
                .padding(14)
            }.buttonStyle(.plain)

            if isOpen && cat.isInfoPlistDriven {
                Divider()
                ForEach(cat.apps) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.appURL.path))
                            .resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.displayName).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Tokens.text)
                            Text(app.usageString).font(.system(size: 10.5))
                                .foregroundStyle(Tokens.text3).lineLimit(2)
                        }
                        Spacer()
                        Text(app.id).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Tokens.text3).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var managedPill: some View {
        Text("system-managed")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.text3.opacity(0.18)))
            .foregroundStyle(Tokens.text3)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
