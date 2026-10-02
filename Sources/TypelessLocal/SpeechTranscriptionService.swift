import AVFoundation
import Speech

enum TranscriptionError: Error, LocalizedError {
    case noCompatibleAudioFormat
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noCompatibleAudioFormat:
            return "Aucun format audio compatible avec le moteur de dictée."
        case .permissionDenied:
            return "Accès à la reconnaissance vocale refusé."
        }
    }
}

/// Transcription locale via le moteur on-device de macOS 26 (`SpeechAnalyzer`),
/// celui-là même qui alimente la dictée native du système.
///
/// Aucun modèle tiers à télécharger et aucun audio ne quitte la machine. La
/// transcription se fait en streaming *pendant* que l'utilisateur parle : au
/// moment où il arrête l'enregistrement, le texte est déjà quasiment prêt.
///
/// `@unchecked Sendable` : `append(_:)` est appelé depuis le thread audio, mais
/// il n'écrit rien — il ne fait que transmettre au `continuation`, lui-même sûr
/// vis-à-vis de la concurrence. Le cycle start/finish reste sur le main actor.
final class SpeechTranscriptionService: @unchecked Sendable {
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<String, Never>?

    init(locale: Locale = Locale(identifier: "fr-FR")) {
        self.locale = locale
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Ouvre une session et retourne le format audio attendu par l'analyseur.
    func start() async throws -> AVAudioFormat {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        self.transcriber = transcriber

        try await installModelIfNeeded(for: transcriber)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noCompatibleAudioFormat
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        // Accumule les résultats définitifs au fil de l'eau. Les résultats
        // volatils (hypothèses intermédiaires) sont ignorés : seuls les
        // segments finaux constituent la transcription.
        collector = Task {
            var text = AttributedString()
            do {
                for try await result in transcriber.results where result.isFinal {
                    text += result.text
                }
            } catch {
                print("⚠️ Flux de résultats interrompu : \(error.localizedDescription)")
            }
            return String(text.characters)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)

        return format
    }

    /// Alimente l'analyseur. Appelé depuis le thread audio.
    func append(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Clôt la session et retourne le texte transcrit.
    func finish() async throws -> String {
        continuation?.finish()
        continuation = nil

        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = await collector?.value ?? ""

        analyzer = nil
        transcriber = nil
        collector = nil

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Locales déjà provisionnées durant cette exécution : sans ce cache, la
    /// vérification était relancée à chaque dictée.
    private static var provisionedLocales = Set<String>()

    /// Les modèles de dictée sont fournis par le système ; ils ne sont
    /// installés que si la langue n'est pas déjà disponible.
    private func installModelIfNeeded(for transcriber: SpeechTranscriber) async throws {
        guard !Self.provisionedLocales.contains(locale.identifier) else { return }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("⏳ Installation du modèle de dictée (\(locale.identifier)) par le système…")
            try await request.downloadAndInstall()
            print("✅ Modèle de dictée prêt.")
        }
        Self.provisionedLocales.insert(locale.identifier)
    }
}
