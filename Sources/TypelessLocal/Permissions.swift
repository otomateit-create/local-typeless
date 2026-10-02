import AppKit
import IOKit.hid

enum Permissions {
    /// État de l'autorisation "Surveillance des saisies" (Input Monitoring).
    static func inputMonitoringStatus() -> String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "accordée"
        case kIOHIDAccessTypeDenied: return "refusée"
        default: return "non demandée"
        }
    }

    static func isInputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Déclenche le dialogue système d'Input Monitoring si nécessaire.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func isAccessibilityGranted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Journalise l'état réel des deux autorisations et déclenche les demandes manquantes.
    static func auditAndRequest() {
        let bundlePath = Bundle.main.bundlePath
        print("Bundle exécuté : \(bundlePath)")
        print("Input Monitoring : \(inputMonitoringStatus())")
        print("Accessibilité : \(isAccessibilityGranted(prompt: false) ? "accordée" : "refusée")")

        if !isInputMonitoringGranted() {
            print("→ demande d'Input Monitoring (une fenêtre système peut s'ouvrir)...")
            requestInputMonitoring()
        }
        if !isAccessibilityGranted(prompt: false) {
            print("→ demande d'Accessibilité (une fenêtre système peut s'ouvrir)...")
            _ = isAccessibilityGranted(prompt: true)
        }
    }
}
