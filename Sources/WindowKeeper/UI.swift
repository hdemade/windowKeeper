import SwiftUI
import Cocoa

// MARK: - Fenêtre principale

struct MainView: View {
    @ObservedObject var model: AppDelegate
    @State private var selectedKey: String?
    @State private var selectedSpace = 1
    @State private var pendingDelete: Layout?
    @State private var renamingKey: String?
    @State private var newName = ""

    private var layouts: [Layout] {
        // La configuration actuelle d'abord, puis les plus récentes.
        model.store.all.sorted { a, b in
            if (a.configKey == model.currentKey) != (b.configKey == model.currentKey) { return a.configKey == model.currentKey }
            return a.savedAt > b.savedAt
        }
    }

    private var selected: Layout? {
        let key = selectedKey ?? model.currentKey
        return layouts.first { $0.configKey == key } ?? layouts.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.trusted { permissionBanner }
            HStack(spacing: 0) {
                sidebar.frame(width: 280)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .alert("Supprimer « \(pendingDelete?.title ?? "") » ?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { layout in
            Button("Supprimer", role: .destructive) {
                model.delete(key: layout.configKey)
                if selectedKey == layout.configKey { selectedKey = nil }
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("La disposition sauvegardée pour ces écrans sera effacée. Cette action est irréversible.")
        }
        .sheet(isPresented: Binding(get: { renamingKey != nil }, set: { if !$0 { renamingKey = nil } })) {
            RenameSheet(name: $newName,
                        placeholder: model.store.layout(for: renamingKey ?? "")?.defaultTitle ?? "",
                        onCancel: { renamingKey = nil },
                        onCommit: {
                            if let key = renamingKey { model.rename(key: key, to: newName) }
                            renamingKey = nil
                        })
        }
    }

    private func startRename(_ layout: Layout) {
        newName = layout.name ?? ""
        renamingKey = layout.configKey
    }

    @ViewBuilder
    private func actions(for layout: Layout) -> some View {
        Button { startRename(layout) } label: { Label("Renommer…", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) { pendingDelete = layout } label: { Label("Supprimer…", systemImage: "trash") }
    }

    // MARK: Bandeau d'autorisation

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Autorisation Accessibilité manquante").font(.headline)
                Text("WindowKeeper ne peut ni lire ni déplacer les fenêtres tant qu'elle n'est pas accordée.")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
            Button("Ouvrir les réglages…") { model.openAccessibilitySettings() }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Colonne de gauche

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Configurations d'écrans")
                .font(.headline)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

            if layouts.isEmpty {
                Text("Aucune disposition sauvegardée pour l'instant.")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(layouts, id: \.configKey) { layout in
                            ConfigRow(layout: layout,
                                      isCurrent: layout.configKey == model.currentKey,
                                      isSelected: layout.configKey == selected?.configKey) {
                                actions(for: layout)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedKey = layout.configKey; selectedSpace = 1 }
                            .contextMenu { actions(for: layout) }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                // Libellé étiré : les interrupteurs restent alignés à droite, même si un libellé passe sur deux lignes.
                Toggle(isOn: Binding(get: { model.autoSave }, set: { model.autoSave = $0 })) {
                    Text("Sauvegarde automatique").frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle(isOn: Binding(get: { model.autoRestore }, set: { model.autoRestore = $0 })) {
                    Text("Restauration au changement d'écrans").frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle(isOn: Binding(get: { model.loginItemEnabled }, set: { _ in model.toggleLoginItem() })) {
                    Text("Lancer à l'ouverture de session").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Détail

    @ViewBuilder
    private var detail: some View {
        if let layout = selected {
            let isCurrent = layout.configKey == model.currentKey
            let spaceCount = max(layout.windows.compactMap { $0.spaceIndex }.max() ?? 1, 1)
            let space = min(selectedSpace, spaceCount)
            let visible = layout.windows.filter { $0.spaceIndex == nil || $0.spaceIndex == space }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(layout.title).font(.title2.weight(.semibold)).lineLimit(1)
                            Button { startRename(layout) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help("Renommer cette configuration")
                        }
                        Text("\(layout.windows.count) fenêtres · sauvegardée \(relative(layout.savedAt))")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }

                if spaceCount > 1 {
                    Picker("", selection: Binding(get: { space }, set: { selectedSpace = $0 })) {
                        ForEach(1...spaceCount, id: \.self) { Text("Bureau \($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LayoutPreview(layout: layout, windows: visible)
                    .frame(minHeight: 200, maxHeight: .infinity)

                WindowList(layout: layout, windows: visible)
                    .frame(height: 150)

                HStack {
                    Button(role: .destructive) { pendingDelete = layout } label: { Label("Supprimer…", systemImage: "trash") }
                    Spacer()
                    if isCurrent {
                        Button { model.restoreCurrent() } label: { Label("Restaurer", systemImage: "arrow.counterclockwise") }
                            .disabled(!model.trusted || model.busy)
                        Button { model.saveNow() } label: { Label("Sauvegarder maintenant", systemImage: "square.and.arrow.down") }
                            .keyboardShortcut("s")
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.trusted || model.busy)
                    } else {
                        Text("Sera restaurée quand ces écrans seront branchés").foregroundColor(.secondary).font(.callout)
                    }
                }
            }
            .padding(20)
        } else {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Aucune disposition sauvegardée").font(.title2.weight(.semibold))
                Text("Placez vos fenêtres comme vous le souhaitez, puis sauvegardez.\nEnsuite WindowKeeper s'en occupe tout seul.")
                    .multilineTextAlignment(.center).foregroundColor(.secondary)
                Button("Sauvegarder maintenant") { model.saveNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.trusted || model.busy)
            }
            .padding(40)
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        if Date().timeIntervalSince(date) < 5 { return "à l'instant" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Ligne de configuration

private struct ConfigRow<Actions: View>: View {
    let layout: Layout
    let isCurrent: Bool
    let isSelected: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: layout.displayCount > 1 ? "display.2" : "laptopcomputer")
                .font(.title3)
                .frame(width: 30)
                .foregroundColor(isSelected ? .white : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(layout.title).font(.body.weight(.medium)).lineLimit(2)
                Text("\(layout.windows.count) fenêtres\(isCurrent ? " · actuelle" : "")")
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Circle().fill(Color.green).frame(width: 8, height: 8)
            }
            if isSelected {
                Menu { actions() } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Renommer ou supprimer")
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .foregroundColor(isSelected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor : Color.clear))
    }
}

// MARK: - Renommage

private struct RenameSheet: View {
    @Binding var name: String
    let placeholder: String
    let onCancel: () -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Renommer la configuration").font(.headline)
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCommit)
            Text("Laissez vide pour reprendre le nom des écrans : \(placeholder)")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Annuler", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Renommer", action: onCommit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Aperçu miniature

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }

    static func color(for bundleID: String) -> Color {
        var hash: UInt32 = 5381
        for byte in bundleID.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.85)
    }
}

private struct LayoutPreview: View {
    let layout: Layout
    let windows: [WindowRecord]

    var body: some View {
        if let displays = layout.displays, !displays.isEmpty {
            Canvas { context, size in
                let union = displays.reduce(CGRect.null) { $0.union($1.bounds) }
                guard union.width > 0, union.height > 0 else { return }
                let margin: CGFloat = 12
                let scale = min((size.width - 2 * margin) / union.width, (size.height - 2 * margin) / union.height)
                let offset = CGPoint(x: (size.width - union.width * scale) / 2, y: (size.height - union.height * scale) / 2)
                func map(_ r: CGRect) -> CGRect {
                    CGRect(x: offset.x + (r.minX - union.minX) * scale, y: offset.y + (r.minY - union.minY) * scale,
                           width: r.width * scale, height: r.height * scale)
                }

                for display in displays {
                    let rect = map(display.bounds).insetBy(dx: 2, dy: 2)
                    let shape = Path(roundedRect: rect, cornerRadius: 8)
                    context.fill(shape, with: .linearGradient(Gradient(colors: [Color(red: 0.36, green: 0.55, blue: 1.0).opacity(0.35),
                                                                                 Color(red: 0.23, green: 0.18, blue: 0.79).opacity(0.35)]),
                                                              startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                              endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                    context.stroke(shape, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
                }

                // Du fond vers le premier plan (la liste est enregistrée premier plan d'abord).
                for window in windows.reversed() {
                    var frame = window.frame
                    if let uuid = window.displayUUID, let rel = window.relativeOrigin,
                       let display = displays.first(where: { $0.uuid == uuid }) {
                        frame.origin = CGPoint(x: display.bounds.minX + rel.x, y: display.bounds.minY + rel.y)
                    }
                    let rect = map(frame).insetBy(dx: 1, dy: 1)
                    guard rect.width > 2, rect.height > 2 else { continue }
                    let shape = Path(roundedRect: rect, cornerRadius: 5)
                    context.fill(shape, with: .color(Color(nsColor: .windowBackgroundColor)))
                    context.fill(shape, with: .color(AppIcons.color(for: window.bundleID).opacity(0.35)))
                    context.stroke(shape, with: .color(.primary.opacity(0.35)), lineWidth: 1)
                    let iconSize = min(32, min(rect.width, rect.height) * 0.6)
                    if iconSize >= 10, let icon = AppIcons.icon(for: window.bundleID) {
                        context.draw(Image(nsImage: icon),
                                     in: CGRect(x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize))
                    }
                }

                for display in displays {
                    let rect = map(display.bounds)
                    context.draw(Text(display.name).font(.caption2).foregroundColor(.secondary),
                                 at: CGPoint(x: rect.minX + 10, y: rect.maxY - 12), anchor: .leading)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor)))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor))
                Text("Aperçu disponible après la prochaine sauvegarde de cette configuration")
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Liste des fenêtres

private struct WindowList: View {
    let layout: Layout
    let windows: [WindowRecord]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 8) {
                        if let icon = AppIcons.icon(for: window.bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "macwindow").frame(width: 18, height: 18)
                        }
                        Text(window.appName).fontWeight(.medium).lineLimit(1)
                        Text(window.title).foregroundColor(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(location(window)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 10)
                    Divider()
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }

    private func location(_ window: WindowRecord) -> String {
        var parts: [String] = []
        if let name = layout.displays?.first(where: { $0.uuid == window.displayUUID })?.name { parts.append(name) }
        parts.append(window.spaceIndex.map { "bureau \($0)" } ?? "tous les bureaux")
        return parts.joined(separator: " · ")
    }
}
