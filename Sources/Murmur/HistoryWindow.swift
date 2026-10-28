import Cocoa
import SwiftUI

/// Fenêtre « Historique » : relire et corriger ses dictées, voir les corrections apprises et les
/// statistiques. Une seule instance, recréée seulement si elle a été fermée.
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?
    private let store = HistoryStore()

    func show(config: Config) {
        store.threshold = config.history.learnThreshold
        store.historyEnabled = config.history.enabled
        store.reload()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Historique Murmur"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 720, height: 460)
            w.contentView = NSHostingView(rootView: HistoryRoot(store: store))
            w.center()
            window = w
        }
        // App de barre de menus : sans activation explicite, la fenêtre resterait derrière les autres.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class HistoryStore: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var learned: [LearnedCorrection] = []
    @Published var failures = 0
    var threshold = 3
    var historyEnabled = true

    func reload() {
        entries = History.loadForEditing().reversed()
        learned = Learning.load().sorted { $0.lastSeen > $1.lastSeen }
        failures = Self.countFailures()
    }

    /// Enregistre une correction et renvoie le message à afficher sous l'éditeur.
    func save(_ entry: HistoryEntry, text: String) -> String {
        guard let id = entry.id else { return "Entrée introuvable" }
        let shown = entry.shown
        guard text != shown else { return "Aucune modification" }
        let touched = Learning.record(original: shown, edited: text, threshold: threshold)
        guard History.update(id: id, edited: text) else { return "Cette dictée n'est plus dans l'historique" }
        reload()
        if touched.isEmpty { return "Correction enregistrée (aucun mot remplacé à apprendre)" }
        return touched.map { c in
            c.applied ? "« \(c.wrong) » → « \(c.right) » : appris, appliqué désormais"
                      : "« \(c.wrong) » → « \(c.right) » : \(c.count)/\(threshold)"
        }.joined(separator: "\n")
    }

    func forget(_ item: LearnedCorrection) {
        Learning.forget(item)
        reload()
    }

    private static func countFailures() -> Int {
        guard let log = try? String(contentsOf: Paths.logFile, encoding: .utf8) else { return 0 }
        return log.components(separatedBy: "Échec de la dictée").count - 1
    }
}

// MARK: - Vues

private struct HistoryRoot: View {
    @ObservedObject var store: HistoryStore

    var body: some View {
        TabView {
            DictationsTab(store: store).tabItem { Text("Dictées") }
            LearnedTab(store: store).tabItem { Text("Corrections apprises") }
            StatsTab(store: store).tabItem { Text("Statistiques") }
        }
        .padding(12)
        .frame(minWidth: 700, minHeight: 440)
    }
}

private struct DictationsTab: View {
    @ObservedObject var store: HistoryStore
    @State private var search = ""
    @State private var appFilter = ""
    @State private var selection: String?

    private var apps: [String] {
        Array(Set(store.entries.map(\.appName).filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [HistoryEntry] {
        let q = TextMatch.fold(search.trimmingCharacters(in: .whitespaces))
        return store.entries.filter { e in
            (appFilter.isEmpty || e.appName == appFilter)
                && (q.isEmpty || TextMatch.fold(e.shown).contains(q))
        }
    }

    var body: some View {
        if !store.historyEnabled {
            Text("L'historique est désactivé : mets \"history\": { \"enabled\": true } dans config.json.")
                .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                VStack(spacing: 8) {
                    HStack {
                        TextField("Rechercher", text: $search).textFieldStyle(.roundedBorder)
                        Picker("", selection: $appFilter) {
                            Text("Toutes les apps").tag("")
                            ForEach(apps, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 160)
                    }
                    List(filtered, id: \.uid, selection: $selection) { e in
                        EntryRow(entry: e)
                    }
                    Text("\(filtered.count) dictée(s)").font(.caption).foregroundColor(.secondary)
                }
                .frame(minWidth: 300, idealWidth: 360)

                Group {
                    if let id = selection, let entry = store.entries.first(where: { $0.uid == id }) {
                        EntryEditor(store: store, entry: entry).id(id)
                    } else {
                        Text("Choisis une dictée pour la relire ou la corriger.")
                            .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 340)
            }
        }
    }
}

private struct EntryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Format.date(entry.date)).font(.caption).foregroundColor(.secondary)
                Text(entry.appName).font(.caption.weight(.medium))
                Spacer()
                if entry.edited != nil {
                    Image(systemName: "pencil").font(.caption).foregroundColor(.accentColor)
                }
            }
            Text(entry.shown).lineLimit(2).font(.callout)
        }
        .padding(.vertical, 2)
    }
}

private struct EntryEditor: View {
    @ObservedObject var store: HistoryStore
    let entry: HistoryEntry
    @State private var draft = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Label(Format.date(entry.date), systemImage: "calendar")
                Label(entry.appName.isEmpty ? "?" : entry.appName, systemImage: "app")
                Label(String(format: "%.1f s", entry.audioSeconds), systemImage: "waveform")
            }
            .font(.caption).foregroundColor(.secondary)

            Text("Corrige le texte ci-dessous. Un mot corrigé \(store.threshold) fois de la même façon est appris : Murmur l'écrira ensuite toujours ainsi.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $draft)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Button("Enregistrer la correction") { message = store.save(entry, text: draft) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft == entry.shown)
                Button("Annuler les modifications") { draft = entry.shown; message = "" }
                    .disabled(draft == entry.shown)
                Spacer()
                Button("Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft, forType: .string)
                    message = "Copié dans le presse-papiers"
                }
            }
            if !message.isEmpty {
                Text(message).font(.callout).foregroundColor(.accentColor).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Transcription brute") {
                Text(entry.raw).font(.callout).foregroundColor(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .padding(.leading, 8)
        .onAppear { draft = entry.shown }
    }
}

private struct LearnedTab: View {
    @ObservedObject var store: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chaque mot que tu corriges dans l'onglet Dictées est compté. À \(store.threshold) corrections identiques, la règle entre dans vocabulary.txt et s'applique à chaque dictée.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.learned.isEmpty {
                Text("Aucune correction pour l'instant.").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.learned) { c in
                    HStack {
                        Text(c.wrong).strikethrough().foregroundColor(.secondary)
                        Image(systemName: "arrow.right").foregroundColor(.secondary)
                        Text(c.right).fontWeight(.medium)
                        Spacer()
                        if c.applied {
                            Label("Appliquée", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                        } else {
                            Text("\(c.count)/\(store.threshold)").monospacedDigit().foregroundColor(.orange)
                        }
                        Button("Oublier") { store.forget(c) }
                    }
                }
            }
        }
    }
}

private struct StatsTab: View {
    @ObservedObject var store: HistoryStore

    private var stats: Stats { Stats(store.entries) }

    var body: some View {
        let s = stats
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Tile(value: Format.int(s.words), label: "mots dictés")
                    Tile(value: Format.int(s.wordsToday), label: "aujourd'hui")
                    Tile(value: Format.duration(s.savedSeconds), label: "gagnées vs clavier (40 mots/min)")
                    Tile(value: String(format: "%.1f s", s.medianLatency), label: "latence médiane")
                    Tile(value: String(format: "%.1f s", s.p90Latency), label: "latence p90")
                    Tile(value: "\(store.failures)", label: "échecs (journal)")
                }
                Bars(title: "Mots par jour, 14 derniers jours", rows: s.perDay)
                Bars(title: "Dictées par app", rows: s.perApp)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct Tile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundColor(.secondary).lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

private struct Bars: View {
    let title: String
    let rows: [(label: String, value: Int)]
    var body: some View {
        let top = max(1, rows.map(\.value).max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text(rows[i].label).font(.caption).frame(width: 130, alignment: .trailing).lineLimit(1)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(2, g.size.width * CGFloat(rows[i].value) / CGFloat(top)))
                    }
                    .frame(height: 12)
                    Text(Format.int(rows[i].value)).font(.caption).monospacedDigit().frame(width: 56, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Calculs

private struct Stats {
    var words = 0
    var wordsToday = 0
    var savedSeconds = 0.0
    var medianLatency = 0.0
    var p90Latency = 0.0
    var perDay: [(label: String, value: Int)] = []
    var perApp: [(label: String, value: Int)] = []

    /// Vitesse de frappe de référence pour estimer le temps gagné.
    static let typingWordsPerMinute = 40.0

    init(_ entries: [HistoryEntry]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var byDay: [Date: Int] = [:]
        var byApp: [String: Int] = [:]
        var spent = 0.0
        for e in entries {
            let n = e.shown.split(whereSeparator: { $0.isWhitespace }).count
            words += n
            spent += e.audioSeconds + e.totalSeconds
            byApp[e.appName.isEmpty ? "?" : e.appName, default: 0] += 1
            if let d = Format.parse(e.date) {
                let day = cal.startOfDay(for: d)
                byDay[day, default: 0] += n
                if day == today { wordsToday += n }
            }
        }
        savedSeconds = max(0, Double(words) / Self.typingWordsPerMinute * 60 - spent)
        let latencies = entries.map(\.totalSeconds).sorted()
        if !latencies.isEmpty {
            medianLatency = latencies[latencies.count / 2]
            p90Latency = latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.9))]
        }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        f.locale = Locale(identifier: "fr_FR")
        perDay = (0..<14).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (f.string(from: day), byDay[day] ?? 0)
        }
        perApp = byApp.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }
    }
}

private enum Format {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        f.locale = Locale(identifier: "fr_FR")
        return f
    }()

    static func parse(_ s: String) -> Date? { iso.date(from: s) }
    static func date(_ s: String) -> String { parse(s).map { display.string(from: $0) } ?? s }

    static func int(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "fr_FR")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
    }
}
