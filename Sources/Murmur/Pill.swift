import Cocoa
import SwiftUI

final class PillModel: ObservableObject {
    enum Mode: Equatable {
        case hidden
        case hold
        case handsFree
        case transcribing
        /// Mode commande : la parole est une consigne qui réécrit la sélection.
        case command
        /// Traitement en cours avec un libellé précis ("Réécriture", "Transcription locale"...).
        case working(String)
        case message(String, isError: Bool)
        /// Information neutre, avec son symbole (ex : texte copié faute de champ où coller).
        case notice(String, symbol: String)
    }
    @Published var mode: Mode = .hidden
    @Published var level: Double = 0
    @Published var elapsed: TimeInterval = 0
    var maxSeconds: TimeInterval = 300
}

/// Petit panneau flottant non activant : ne vole jamais le focus, ignore la souris, visible sur tous les Spaces.
final class PillController {
    let model = PillModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    var position = "bottom"
    var enabled = true

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    func show(_ mode: PillModel.Mode) {
        hideWork?.cancel()
        model.mode = mode
        if mode == .hold || mode == .command { model.elapsed = 0; model.level = 0 }
        guard enabled else { return }
        place()
        panel.orderFrontRegardless()
    }

    /// Affiche un court message, puis se masque.
    func flash(_ text: String, isError: Bool = false, seconds: Double = 1.6) {
        flash(.message(text, isError: isError), seconds: seconds)
    }

    func flash(_ mode: PillModel.Mode, seconds: Double) {
        show(mode)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        model.mode = .hidden
        panel.orderOut(nil)
    }

    private func place() {
        // Écran sous la souris, en général celui où l'utilisateur travaille.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = vf.midX - size.width / 2
        let y = position == "top" ? vf.maxY - size.height - 12 : vf.minY + 18
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if model.mode != .hidden {
                content
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: model.mode)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .hold:
            HStack(spacing: 8) {
                PulsingDot(color: .red)
                Text("J'écoute").pillText()
                Meter(level: model.level, color: .red)
            }
        case .handsFree:
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.orange)
                Text("Mains libres").pillText()
                Meter(level: model.level, color: .orange)
                Text(timeText).pillText(secondary: true).monospacedDigit()
            }
        case .command:
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .bold)).foregroundColor(.purple)
                Text("Commande").pillText()
                Meter(level: model.level, color: .purple)
            }
        case .transcribing:
            working("Transcription")
        case .working(let label):
            working(label)
        case .notice(let text, let symbol):
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundColor(.white.opacity(0.8))
                Text(text).pillText().lineLimit(1).truncationMode(.tail).frame(maxWidth: 250)
            }
        case .message(let text, let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11)).foregroundColor(isError ? .yellow : .gray)
                Text(text).pillText().lineLimit(1).truncationMode(.tail).frame(maxWidth: 250)
            }
        case .hidden:
            EmptyView()
        }
    }

    private func working(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            Text(label).pillText().lineLimit(1)
            Text("échap").pillText(secondary: true)
        }
    }

    private var timeText: String {
        // Compte à rebours pendant la dernière minute pour que l'arrêt automatique ne surprenne pas.
        let remaining = model.maxSeconds - model.elapsed
        let t = remaining <= 60 ? max(0, remaining) : model.elapsed
        let s = Int(t)
        return (remaining <= 60 ? "-" : "") + String(format: "%d:%02d", s / 60, s % 60)
    }
}

private extension Text {
    func pillText(secondary: Bool = false) -> some View {
        self.font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundColor(secondary ? .white.opacity(0.55) : .white)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = true } }
    }
}

private struct Meter: View {
    let level: Double
    let color: Color
    private let weights: [Double] = [0.55, 0.85, 1.0, 0.8, 0.5]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule().fill(color.opacity(0.9))
                    .frame(width: 3, height: 3 + 11 * min(1, level * weights[i] * 1.3))
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: level)
    }
}
