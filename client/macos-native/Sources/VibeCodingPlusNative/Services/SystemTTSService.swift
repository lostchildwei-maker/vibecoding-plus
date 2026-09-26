import AVFoundation
import Foundation

enum SystemTTSError: LocalizedError {
    case emptyAudio
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .emptyAudio: "系统语音没有生成音频"
        case .unsupportedFormat: "系统语音返回了不支持的音频格式"
        }
    }
}

/// Produces 16 kHz mono PCM16 for Note 4's existing ES8311 output path.
@MainActor
enum SystemTTSService {
    static func synthesize(_ text: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let job = SpeechSynthesisJob(continuation: continuation)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            job.synthesizer.write(utterance) { [job] buffer in
                job.consume(buffer)
            }
        }
    }
}

private final class SpeechSynthesisJob: @unchecked Sendable {
    let synthesizer = AVSpeechSynthesizer()
    private let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var finished = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func consume(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            complete(.failure(SystemTTSError.unsupportedFormat))
            return
        }
        let count = Int(pcm.frameLength)
        if count == 0 {
            guard !samples.isEmpty, sampleRate > 0 else {
                complete(.failure(SystemTTSError.emptyAudio))
                return
            }
            complete(.success(Self.toPCM16(samples, sampleRate: sampleRate)))
            return
        }
        let format = pcm.format
        if sampleRate == 0 { sampleRate = format.sampleRate }
        guard sampleRate == format.sampleRate else {
            complete(.failure(SystemTTSError.unsupportedFormat))
            return
        }
        let channels = Int(format.channelCount)
        guard channels > 0 else {
            complete(.failure(SystemTTSError.unsupportedFormat))
            return
        }
        let interleaved = format.isInterleaved
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<channels {
                let index = interleaved ? frame * channels + channel : frame
                let pointerIndex = interleaved ? 0 : channel
                switch format.commonFormat {
                case .pcmFormatFloat32:
                    guard let data = pcm.floatChannelData else {
                        complete(.failure(SystemTTSError.unsupportedFormat)); return
                    }
                    sum += data[pointerIndex][index]
                case .pcmFormatInt16:
                    guard let data = pcm.int16ChannelData else {
                        complete(.failure(SystemTTSError.unsupportedFormat)); return
                    }
                    sum += Float(data[pointerIndex][index]) / Float(Int16.max)
                default:
                    complete(.failure(SystemTTSError.unsupportedFormat)); return
                }
            }
            samples.append(sum / Float(channels))
        }
    }

    private func complete(_ result: Result<Data, Error>) {
        finished = true
        samples.removeAll()
        continuation.resume(with: result)
    }

    private static func toPCM16(_ input: [Float], sampleRate: Double) -> Data {
        let outputRate = 16_000.0
        let count = max(1, Int(Double(input.count) * outputRate / sampleRate))
        var result = Data(capacity: count * MemoryLayout<Int16>.size)
        for index in 0..<count {
            let source = Double(index) * sampleRate / outputRate
            let lower = min(Int(source), input.count - 1)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(source - Double(lower))
            let value = input[lower] * (1 - fraction) + input[upper] * fraction
            let bounded = max(-1, min(1, value))
            var sample = Int16((bounded * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &sample) { result.append(contentsOf: $0) }
        }
        return result
    }
}
