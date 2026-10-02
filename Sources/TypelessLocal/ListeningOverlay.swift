import AppKit
import SwiftUI

enum OverlayState {
    /// Enregistrement : les barres suivent le niveau du micro.
    case listening
    /// Transcription + appel LLM : arc qui tourne sur le pourtour.
    case processing
}

/// Petite orbe flottante affichée pendant tout le cycle de dictée.
///
/// Contrainte clé : la fenêtre ne doit jamais devenir "key" ni activer l'app,
/// sinon le champ de texte dans lequel l'utilisateur veut écrire perdrait le
/// focus — et l'insertion finale du texte irait au mauvais endroit.
@MainActor
final class ListeningOverlay {
    private var panel: NSPanel?
    private let model = OverlayModel()

    func show(_ state: OverlayState) {
        model.state = state
        if state == .processing {
            model.level = 0
        }

        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Sans cela, NSHostingView peint un fond opaque derrière l'orbe.
        let hosting = NSHostingView(rootView: OverlayContent(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        positionJustAboveDock(panel)
        panel.orderFrontRegardless()

        self.panel = panel
    }

    /// Niveau micro normalisé (0…1), pour l'animation des barres.
    func updateLevel(_ level: CGFloat) {
        model.level = level
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        model.level = 0
    }

    /// `visibleFrame` exclut déjà le Dock : son bord bas correspond donc au
    /// sommet du Dock, ce qui place l'orbe juste au-dessus.
    private func positionJustAboveDock(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 8
        ))
    }
}

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .listening
    @Published var level: CGFloat = 0
}

private struct OverlayContent: View {
    @ObservedObject var model: OverlayModel

    private let diameter: CGFloat = 34

    var body: some View {
        ZStack {
            // Corps noir : très légèrement dégradé pour garder du volume
            // sans jamais éclaircir le disque.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.13), .black],
                        center: UnitPoint(x: 0.35, y: 0.3),
                        startRadius: 0.5,
                        endRadius: diameter * 0.75
                    )
                )

            // Liseré lumineux : c'est le seul élément clair, et il ne déborde
            // pas du disque (pas de halo projeté sur l'écran).
            Circle()
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0.55), location: 0.00),
                            .init(color: .white.opacity(0.08), location: 0.30),
                            .init(color: .white.opacity(0.04), location: 0.55),
                            .init(color: .white.opacity(0.32), location: 0.82),
                            .init(color: .white.opacity(0.55), location: 1.00),
                        ]),
                        center: .center,
                        angle: .degrees(215)
                    ),
                    lineWidth: 0.9
                )

            switch model.state {
            case .listening:
                LevelBars(level: model.level)
            case .processing:
                ProcessingArc(diameter: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Barres pilotées par le niveau réel du micro : elles ne bougent que si
/// l'application entend effectivement quelque chose.
private struct LevelBars: View {
    let level: CGFloat

    /// Sensibilité propre à chaque barre, pour éviter un mouvement en bloc.
    private let factors: [CGFloat] = [0.62, 0.88, 1.0, 0.80, 0.55]
    private let minHeight: CGFloat = 2.5
    private let maxHeight: CGFloat = 21

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(factors.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: 2, height: height(for: factors[index]))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func height(for factor: CGFloat) -> CGFloat {
        minHeight + (maxHeight - minHeight) * min(1, level * factor)
    }
}

private struct ProcessingArc: View {
    let diameter: CGFloat

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: diameter - 3, height: diameter - 3)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
