import AVFoundation

/// Capture du micro et conversion vers le format demandé par le moteur de
/// transcription, buffer par buffer.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Permission micro

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Enregistrement

    func start(outputFormat: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.outputFormat = outputFormat
        self.onBuffer = onBuffer

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        // 1024 images ≈ 23 ms : assez court pour que l'indicateur de niveau
        // suive la voix sans à-coups.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.forward(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        onBuffer = nil
    }

    private func forward(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat, let onBuffer else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // Le closure d'entrée n'est appelé qu'une fois par buffer : au second
        // appel on signale l'absence de données, sinon le converter boucle.
        var alreadyProvided = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if alreadyProvided {
                status.pointee = .noDataNow
                return nil
            }
            alreadyProvided = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, output.frameLength > 0 else { return }
        onBuffer(output)
    }
}
