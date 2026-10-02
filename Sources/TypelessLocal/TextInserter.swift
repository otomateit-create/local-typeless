import AppKit

/// Insère le texte à l'emplacement du curseur via un collage simulé.
///
/// C'est l'approche retenue par VoiceInk/Handy : contrairement à l'API
/// Accessibility (AXUIElement), elle fonctionne dans quasiment toutes les apps
/// et tous les champs de saisie, y compris les zones web.
enum TextInserter {
    private static let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        // Laisser à l'app cible le temps de lire le presse-papiers avant restauration.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let previous else { return }
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
