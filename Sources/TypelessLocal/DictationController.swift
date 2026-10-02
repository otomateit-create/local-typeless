import AVFoundation
import AppKit

/// Orchestre le cycle complet : écoute → transcription locale → nettoyage LLM → insertion.
@MainActor
final class DictationController {
    /// L'ouverture d'une session est asynchrone (permissions, éventuelle
    /// installation du modèle système). Sans état `.starting` explicite, un
    /// second appui pendant cette phase relançait une session au lieu d'arrêter
    /// la première.
    private enum State {
        case idle
        case starting
        case recording
        case processing
    }

    private let recorder = AudioRecorder()
    private let openRouter = OpenRouterClient()
    private let overlay = ListeningOverlay()

    private var state: State = .idle
    private var stopRequestedDuringStart = false
    private var transcription: SpeechTranscriptionService?
    private var startedAt: Date?

    /// Durée en dessous de laquelle on considère qu'il n'y a rien à transcrire.
    private let minimumDuration: TimeInterval = 0.4

    func toggle() {
        switch state {
        case .idle:
            startSession()
        case .starting:
            // La session n'est pas encore prête : on note l'intention d'arrêter,
            // elle sera honorée dès l'ouverture terminée.
            stopRequestedDuringStart = true
        case .recording:
            stopAndProcess()
        case .processing:
            break
        }
    }

    // MARK: - Démarrage

    private func startSession() {
        state = .starting
        stopRequestedDuringStart = false
        overlay.show(.listening) // retour visuel immédiat

        Task { @MainActor in
            do {
                guard await Self.microphoneGranted() else {
                    print("❌ Accès au micro refusé (Réglages Système > Confidentialité et sécurité > Microphone).")
                    return abortStart()
                }
                guard await SpeechTranscriptionService.requestPermission() else {
                    print("❌ Accès à la reconnaissance vocale refusé.")
                    return abortStart()
                }

                let service = SpeechTranscriptionService()
                let format = try await service.start()
                print("🔊 Format moteur vocal : \(format.commonFormat.rawValue == 1 ? "Float32" : "entiers/autre") — \(Int(format.sampleRate)) Hz")

                try recorder.start(outputFormat: format) { [weak self] buffer in
                    let level = buffer.normalizedLevel()
                    Task { @MainActor in
                        self?.overlay.updateLevel(level)
                    }
                    service.append(buffer)
                }

                transcription = service
                startedAt = Date()
                state = .recording
                print("🎙️ Écoute démarrée")

                // L'utilisateur a ré-appuyé pendant la préparation.
                if stopRequestedDuringStart {
                    stopRequestedDuringStart = false
                    stopAndProcess()
                }
            } catch {
                print("❌ Démarrage impossible : \(error.localizedDescription)")
                abortStart()
            }
        }
    }

    private func abortStart() {
        recorder.stop()
        transcription = nil
        startedAt = nil
        stopRequestedDuringStart = false
        state = .idle
        overlay.hide()
    }

    private static func microphoneGranted() async -> Bool {
        await withCheckedContinuation { continuation in
            AudioRecorder.requestPermission { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Arrêt et traitement

    private func stopAndProcess() {
        recorder.stop()

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        print("⏹️ Écoute arrêtée (\(String(format: "%.1f", duration)) s)")

        guard let service = transcription else {
            abortStart()
            return
        }
        transcription = nil

        guard duration >= minimumDuration else {
            print("⚠️ Trop court, on annule.")
            state = .idle
            overlay.hide()
            Task { _ = try? await service.finish() }
            return
        }

        state = .processing
        overlay.show(.processing)

        Task { @MainActor in
            defer {
                state = .idle
                overlay.hide()
            }
            do {
                let raw = try await service.finish()
                print("📝 Brut : \(raw)")

                guard !raw.isEmpty else {
                    print("⚠️ Transcription vide.")
                    return
                }

                let text: String
                do {
                    text = try await openRouter.cleanup(transcript: raw)
                    print("✨ Propre : \(text)")
                } catch {
                    // L'utilisateur a parlé : mieux vaut coller la dictée brute que de
                    // ne rien insérer du tout. Le garde de sortie refuse désormais un
                    // nettoyage douteux, ce qui rend ce repli beaucoup plus fréquent.
                    print("⚠️ Nettoyage indisponible (\(error.localizedDescription)) — insertion du texte brut.")
                    text = raw
                }

                overlay.hide()
                TextInserter.insert(text)
            } catch {
                print("❌ Échec du traitement : \(error.localizedDescription)")
            }
        }
    }
}

extension AVAudioPCMBuffer {
    /// Niveau sonore normalisé (0…1) pour l'animation.
    ///
    /// Le buffer est celui converti au format du moteur vocal, qui peut être en
    /// entiers 16 bits : ne lire que `floatChannelData` renverrait alors
    /// toujours 0, d'où des barres figées.
    func normalizedLevel() -> CGFloat {
        let frames = Int(frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        if let channel = floatChannelData?[0] {
            for index in 0..<frames {
                let sample = channel[index]
                sum += sample * sample
            }
        } else if let channel = int16ChannelData?[0] {
            for index in 0..<frames {
                let sample = Float(channel[index]) / 32768
                sum += sample * sample
            }
        } else {
            return 0
        }

        let rms = (sum / Float(frames)).squareRoot()
        guard rms > 0 else { return 0 }

        // Échelle en décibels : la voix couvre une plage dynamique que le RMS
        // linéaire écrase visuellement (un chuchotement et une voix normale
        // finissent au même endroit). -55 dBFS → 0, -15 dBFS → 1.
        let decibels = 20 * log10(rms)
        return CGFloat(min(1, max(0, (decibels + 55) / 40)))
    }
}
