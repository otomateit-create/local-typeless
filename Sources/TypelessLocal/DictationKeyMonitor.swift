import AppKit
import CoreGraphics

final class DictationKeyMonitor {
    // Code touche du bouton "Dictée" (icône micro, F5) sur ce clavier.
    // Identifié empiriquement : ce n'est pas un keyCode ADB standard (0-127)
    // ni un événement média (NX_SYSDEFINED) — juste un keyDown/keyUp normal
    // avec un keyCode étendu.
    static let dictationKeyCode: Int64 = 176

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Appelé sur le thread principal à chaque appui sur la touche Dictée (toggle).
    var onToggle: (() -> Void)?

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        // Le tap HID est le seul point où la touche Dictée est visible avant que
        // macOS ne la consomme. On tente d'abord ce niveau ; si le système le
        // refuse, on retombe sur le niveau session (moins privilégié).
        let candidates: [(CGEventTapLocation, String)] = [
            (.cghidEventTap, "HID"),
            (.cgSessionEventTap, "session")
        ]

        for (location, label) in candidates {
            guard let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, cgEvent, refcon in
                    let monitor = Unmanaged<DictationKeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                    return monitor.handle(type: type, cgEvent: cgEvent)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                print("Tap \(label) refusé par le système.")
                continue
            }

            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("✅ DictationKeyMonitor actif (tap \(label)) — appuie sur F5.")
            return
        }

        print("""
        ❌ Aucun CGEventTap n'a pu être créé.
           Input Monitoring : \(Permissions.inputMonitoringStatus())
           Accessibilité : \(Permissions.isAccessibilityGranted(prompt: false) ? "accordée" : "refusée")
           Si les deux sont 'accordée', c'est que l'autorisation enregistrée ne
           correspond plus à la signature actuelle du binaire : lancer
           `tccutil reset ListenEvent com.raphaeliksil.typelesslocal` puis relancer.
        """)
    }

    private func handle(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // Le système désactive le tap s'il juge le callback trop lent : le réactiver.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(cgEvent)
        }

        let keyCode = cgEvent.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.dictationKeyCode else {
            return Unmanaged.passRetained(cgEvent)
        }

        if type == .keyDown {
            DispatchQueue.main.async { [weak self] in
                self?.onToggle?()
            }
        }
        // On avale keyDown ET keyUp pour cette touche : elle ne doit jamais
        // atteindre macOS (sinon la Dictée native se déclenche en parallèle).
        return nil
    }
}
