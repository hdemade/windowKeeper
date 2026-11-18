import SwiftUI
import Cocoa
import Combine

/// Intervalles proposés pour la sauvegarde automatique, en secondes.
enum AutoSaveInterval {
    static let choices: [TimeInterval] = [10, 30, 60, 120, 300, 600, 900]
    static let standard: TimeInterval = 30

    static func label(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) s" : "\(s / 60) min"
    }
}

// MARK: - Fenêtre de réglages

struct SettingsView: View {
    @ObservedObject var model: AppDelegate
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        Form {
            Section {
                Toggle("Sauvegarde automatique", isOn: Binding(get: { model.autoSave }, set: { model.autoSave = $0 }))
                Picker("Intervalle", selection: Binding(get: { model.autoSaveInterval }, set: { model.autoSaveInterval = $0 })) {
                    ForEach(AutoSaveInterval.choices, id: \.self) { seconds in
                        Text("Toutes les \(AutoSaveInterval.label(seconds))").tag(seconds)
                    }
                }
                .disabled(!model.autoSave)
            } header: {
                Text("Sauvegarde")
            } footer: {
                Text("La dernière sauvegarde faite avant un changement d'écrans est celle qui sera restaurée au retour. Un intervalle court suit mieux vos déplacements de fenêtres.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Restauration") {
                Toggle("Restaurer au changement d'écrans et au réveil",
                       isOn: Binding(get: { model.autoRestore }, set: { model.autoRestore = $0 }))
            }

            Section("Démarrage") {
                Toggle("Lancer à l'ouverture de session",
                       isOn: Binding(get: { model.loginItemEnabled }, set: { _ in model.toggleLoginItem() }))
            }

            Section("Mises à jour") {
                LabeledContent("Version installée", value: updater.currentVersion)
                Toggle("Vérifier automatiquement chaque jour",
                       isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
                updateStatus
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 560)
        // Garde l'état de l'ouverture de session à jour s'il change dans Réglages Système.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.revision += 1
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.status {
        case .available(let release):
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("WindowKeeper \(release.version) est disponible", systemImage: "arrow.down.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.body.weight(.medium))
                    Text(release.name).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Notes de version") { NSWorkspace.shared.open(release.pageURL) }
                Button("Télécharger") { updater.download(release) }
                    .buttonStyle(.borderedProminent)
            }
        default:
            HStack {
                statusText
                Spacer()
                if updater.status == .checking { ProgressView().controlSize(.small) }
                Button("Rechercher maintenant") { updater.check() }
                    .disabled(updater.status == .checking)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch updater.status {
        case .checking:
            Text("Recherche en cours…").foregroundColor(.secondary)
        case .upToDate:
            VStack(alignment: .leading, spacing: 2) {
                Text("WindowKeeper est à jour.")
                if let date = updater.lastCheck { lastCheckText(date) }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Label("Vérification impossible", systemImage: "exclamationmark.triangle").foregroundColor(.orange)
                Text(message).font(.caption).foregroundColor(.secondary)
            }
        default:
            if let date = updater.lastCheck {
                lastCheckText(date)
            } else {
                Text("Pas encore vérifié.").foregroundColor(.secondary)
            }
        }
    }

    private func lastCheckText(_ date: Date) -> some View {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return Text("Dernière vérification : \(formatter.string(from: date))")
            .font(.caption).foregroundColor(.secondary)
    }
}
