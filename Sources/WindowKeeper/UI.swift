import SwiftUI
import Cocoa

// MARK: - Fenêtre principale

/// Ce que vise un renommage, une suppression ou la sélection : un ensemble d'écrans (son dernier état)
/// ou l'une de ses sauvegardes.
struct ConfigTarget: Hashable {
    var key: String
    var snapshotID: String?
}

struct MainView: View {
    @ObservedObject var model: AppDelegate
    @State private var selection: ConfigTarget?
    @State private var expanded: Set<String> = []
    @State private var selectedSpace = 1
    @State private var pendingDelete: ConfigTarget?
    @State private var renaming: ConfigTarget?
    @State private var renamingInDetail = false

    private var layouts: [Layout] {
        // La configuration actuelle d'abord, puis les plus récentes.
        model.store.all.sorted { a, b in
            if (a.configKey == model.currentKey) != (b.configKey == model.currentKey) { return a.configKey == model.currentKey }
            return a.savedAt > b.savedAt
        }
    }

    private func layout(for target: ConfigTarget) -> Layout? {
        if let id = target.snapshotID { return model.store.snapshot(key: target.key, id: id) }
        return model.store.layout(for: target.key)
    }

    /// La sélection si elle existe encore, sinon le dernier état de la configuration actuelle.
    private var current: ConfigTarget? {
        if let selection = selection, layout(for: selection) != nil { return selection }
        guard let first = layouts.first(where: { $0.configKey == model.currentKey }) ?? layouts.first else { return nil }
        return ConfigTarget(key: first.configKey)
    }

    private func label(for target: ConfigTarget) -> String {
        guard let layout = layout(for: target) else { return "" }
        return target.snapshotID == nil ? layout.title : layout.snapshotLabel
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.trusted { permissionBanner }
            if let release = model.updater.available { updateBanner(release) }
            HStack(spacing: 0) {
                sidebar.frame(width: 300)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 880, minHeight: 540)
        .onAppear { expanded.insert(model.currentKey) }
        .alert("Supprimer « \(pendingDelete.map(label(for:)) ?? "") » ?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { target in
            Button("Supprimer", role: .destructive) {
                if let id = target.snapshotID {
                    model.deleteSnapshot(key: target.key, id: id)
                } else {
                    model.delete(key: target.key)
                }
                if selection == target || (target.snapshotID == nil && selection?.key == target.key) { selection = nil }
            }
            Button("Annuler", role: .cancel) {}
        } message: { target in
            Text(deleteMessage(target))
        }
    }

    /// Le nom affiché quand l'utilisateur n'en a pas choisi.
    private func defaultLabel(for target: ConfigTarget) -> String {
        guard var layout = layout(for: target) else { return "" }
        layout.name = nil
        return target.snapshotID == nil ? layout.defaultTitle : layout.snapshotLabel
    }

    /// Champ d'édition du nom, affiché à la place du titre pendant un renommage.
    private func nameField(for target: ConfigTarget, inDetail: Bool) -> InlineNameField? {
        guard renaming == target, renamingInDetail == inDetail else { return nil }
        let fallback = defaultLabel(for: target)
        return InlineNameField(initial: layout(for: target)?.name ?? fallback,
                               placeholder: fallback,
                               font: inDetail ? .title2.weight(.semibold) : .body.weight(.medium),
                               onCommit: { text in
                                   let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                   let name = trimmed == fallback ? "" : trimmed
                                   if let id = target.snapshotID {
                                       model.renameSnapshot(key: target.key, id: id, to: name)
                                   } else {
                                       model.rename(key: target.key, to: name)
                                   }
                                   if renaming == target { renaming = nil }
                               },
                               onCancel: { if renaming == target { renaming = nil } })
    }

    private func deleteMessage(_ target: ConfigTarget) -> String {
        if target.snapshotID != nil { return "Cette sauvegarde sera effacée. Cette action est irréversible." }
        let count = model.store.snapshots(for: target.key).count
        let extra = count == 0 ? "" : " ainsi que ses \(count) sauvegarde\(count > 1 ? "s" : "")"
        return "Le dernier état enregistré pour ces écrans\(extra) sera effacé. Cette action est irréversible."
    }

    private func startRename(_ target: ConfigTarget, inDetail: Bool = false) {
        if !inDetail { expanded.insert(target.key) }
        selection = target
        renamingInDetail = inDetail
        renaming = target
    }

    /// Sauvegarde tout de suite, puis ouvre le nom de la nouvelle sauvegarde à l'édition.
    private func startSnapshot() {
        let key = model.currentKey
        model.saveSnapshot(name: "") { id in
            guard let id = id else { return }
            let target = ConfigTarget(key: key, snapshotID: id)
            withAnimation(.easeInOut(duration: 0.15)) { _ = expanded.insert(key) }
            startRename(target)
        }
    }

    private func select(_ target: ConfigTarget) {
        selection = target
        selectedSpace = 1
    }

    @ViewBuilder
    private func actions(for target: ConfigTarget) -> some View {
        if target.snapshotID == nil && target.key == model.currentKey {
            Button { startSnapshot() } label: { Label("Nouvelle sauvegarde", systemImage: "plus") }
                .disabled(!model.trusted || model.busy)
        }
        if let layout = layout(for: target), target.key == model.currentKey {
            Button { model.restore(layout) } label: { Label("Restaurer", systemImage: "arrow.counterclockwise") }
                .disabled(!model.trusted || model.busy)
            Divider()
        }
        Button { startRename(target) } label: { Label("Renommer", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) { pendingDelete = target } label: {
            Label(target.snapshotID == nil ? "Supprimer la configuration…" : "Supprimer…", systemImage: "trash")
        }
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

    // MARK: Bandeau de mise à jour

    private func updateBanner(_ release: UpdateChecker.Release) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").foregroundColor(.accentColor).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("WindowKeeper \(release.version) est disponible").font(.headline)
                Text("Vous utilisez la version \(model.updater.currentVersion).")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
            Button("Notes de version") { NSWorkspace.shared.open(release.pageURL) }
            Button("Télécharger") { model.updater.download(release) }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.10))
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
                    VStack(spacing: 4) {
                        ForEach(layouts, id: \.configKey) { layout in
                            group(layout)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Divider()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.autoSave ? "Sauvegarde auto toutes les \(AutoSaveInterval.label(model.autoSaveInterval))"
                                        : "Sauvegarde auto désactivée")
                    Text(model.autoRestore ? "Restauration auto activée" : "Restauration auto désactivée")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button { model.showSettings() } label: { Label("Réglages…", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Ouvrir les réglages (⌘,)")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Un ensemble d'écrans, dépliable pour montrer son dernier état et ses sauvegardes.
    @ViewBuilder
    private func group(_ layout: Layout) -> some View {
        let key = layout.configKey
        let snapshots = model.store.snapshots(for: key)
        let isOpen = expanded.contains(key)
        let groupTarget = ConfigTarget(key: key)
        let selected = current

        ConfigRow(layout: layout,
                  nameField: nameField(for: groupTarget, inDetail: false),
                  snapshotCount: snapshots.count,
                  isCurrent: key == model.currentKey,
                  isSelected: selected?.key == key && !isOpen,
                  isExpanded: isOpen,
                  toggle: {
                      withAnimation(.easeInOut(duration: 0.15)) {
                          if isOpen { expanded.remove(key) } else { expanded.insert(key) }
                      }
                  }) {
            actions(for: groupTarget)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            select(groupTarget)
            if !isOpen { withAnimation(.easeInOut(duration: 0.15)) { _ = expanded.insert(key) } }
        }
        .contextMenu { actions(for: groupTarget) }

        if isOpen {
            VStack(spacing: 2) {
                SnapshotRow(icon: "clock.arrow.circlepath",
                            title: "Dernier état",
                            nameField: nil,
                            subtitle: "Automatique · \(layout.windows.count) fenêtres · \(relative(layout.savedAt))",
                            isSelected: selected == groupTarget) {
                    actions(for: groupTarget)
                }
                .contentShape(Rectangle())
                .onTapGesture { select(groupTarget) }
                .contextMenu { actions(for: groupTarget) }

                ForEach(snapshots, id: \.snapshotID) { snapshot in
                    let target = ConfigTarget(key: key, snapshotID: snapshot.snapshotID)
                    SnapshotRow(icon: "bookmark",
                                title: snapshot.snapshotLabel,
                                nameField: nameField(for: target, inDetail: false),
                                subtitle: "\(snapshot.windows.count) fenêtres · \(relative(snapshot.savedAt))",
                                isSelected: selected == target) {
                        actions(for: target)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { select(target) }
                    .contextMenu { actions(for: target) }
                }

                if key == model.currentKey {
                    Button { startSnapshot() } label: {
                        Label("Nouvelle sauvegarde", systemImage: "plus.circle")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 4).padding(.horizontal, 10)
                    .disabled(!model.trusted || model.busy)
                }
            }
            .padding(.leading, 28)
            .padding(.bottom, 4)
        }
    }

    // MARK: Détail

    @ViewBuilder
    private var detail: some View {
        if let target = current, let layout = layout(for: target) {
            let isCurrent = target.key == model.currentKey
            let isSnapshot = target.snapshotID != nil
            let groupTitle = model.store.layout(for: target.key)?.title ?? layout.title
            let spaceCount = max(layout.windows.compactMap { $0.spaceIndex }.max() ?? 1, 1)
            let space = min(selectedSpace, spaceCount)
            let visible = layout.windows.filter { $0.spaceIndex == nil || $0.spaceIndex == space }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if let field = nameField(for: target, inDetail: true) {
                                field.frame(maxWidth: 420)
                            } else {
                                Text(isSnapshot ? layout.snapshotLabel : layout.title)
                                    .font(.title2.weight(.semibold)).lineLimit(1)
                                    .onTapGesture(count: 2) { startRename(target, inDetail: true) }
                                    .help("Double-cliquez pour renommer")
                            }
                            Button { startRename(target, inDetail: true) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help(isSnapshot ? "Renommer cette sauvegarde" : "Renommer cette configuration")
                        }
                        Text("\(isSnapshot ? groupTitle : "Dernier état") · \(layout.windows.count) fenêtres · sauvegardée \(relative(layout.savedAt))")
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
                    Button(role: .destructive) { pendingDelete = target } label: { Label("Supprimer…", systemImage: "trash") }
                    Spacer()
                    if isCurrent {
                        Button { model.restore(layout) } label: { Label("Restaurer", systemImage: "arrow.counterclockwise") }
                            .disabled(!model.trusted || model.busy)
                        Button { startSnapshot() } label: { Label("Nouvelle sauvegarde", systemImage: "plus") }
                            .disabled(!model.trusted || model.busy)
                        if !isSnapshot {
                            Button { model.saveNow() } label: { Label("Sauvegarder maintenant", systemImage: "square.and.arrow.down") }
                                .keyboardShortcut("s")
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.trusted || model.busy)
                        }
                    } else {
                        Text("Restaurable quand ces écrans seront branchés").foregroundColor(.secondary).font(.callout)
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

// MARK: - Lignes de la colonne

private struct ConfigRow<Actions: View>: View {
    let layout: Layout
    let nameField: InlineNameField?
    let snapshotCount: Int
    let isCurrent: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Replier" : "Déplier les sauvegardes")
            Image(systemName: layout.displayCount > 1 ? "display.2" : "laptopcomputer")
                .font(.title3)
                .frame(width: 28)
                .foregroundColor(isSelected ? .white : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let field = nameField {
                    field
                } else {
                    Text(layout.title).font(.body.weight(.medium)).lineLimit(2)
                }
                Text(subtitle)
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
                    .help("Plus d'actions")
            }
        }
        .padding(.vertical, 8).padding(.leading, 6).padding(.trailing, 10)
        .foregroundColor(isSelected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor : Color.clear))
    }

    private var subtitle: String {
        var parts = ["\(snapshotCount + 1) sauvegarde\(snapshotCount > 0 ? "s" : "")"]
        if isCurrent { parts.append("actuelle") }
        return parts.joined(separator: " · ")
    }
}

private struct SnapshotRow<Actions: View>: View {
    let icon: String
    let title: String
    let nameField: InlineNameField?
    let subtitle: String
    let isSelected: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundColor(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                if let field = nameField {
                    field
                } else {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isSelected {
                Menu { actions() } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Plus d'actions")
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .foregroundColor(isSelected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor : Color.clear))
    }
}

// MARK: - Saisie d'un nom sur place

/// Entrée valide, Échap annule, cliquer ailleurs valide aussi (comme dans le Finder).
struct InlineNameField: View {
    let initial: String
    let placeholder: String
    let font: Font
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(font)
            .foregroundColor(.primary)
            .focused($focused)
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { isFocused in
                if !isFocused { finish(commit: true) }
            }
            .onAppear {
                finished = false
                text = initial
                DispatchQueue.main.async { focused = true }
            }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if commit { onCommit(text) } else { onCancel() }
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
