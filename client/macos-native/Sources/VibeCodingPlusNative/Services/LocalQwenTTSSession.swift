import Foundation

enum LocalTTSError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

struct LocalQwenAudio: Sendable {
    let packets: Data
    let pcmSamples: Int
    let preSkipSamples: Int
}

/// Keeps the Qwen3-TTS model loaded between Eira replies.
final class LocalQwenTTSSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mac20777.vibecodingplus.qwen-tts", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var outputBuffer = Data()
    private var configuration = ""
    private let errorLock = NSLock()
    private var errorTail = ""

    func prepare(python: String, model: String, cacheDirectory: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.ensureWorker(python: python, model: model, cacheDirectory: cacheDirectory)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func synthesize(_ text: String, python: String, model: String,
                    referenceAudio: String, referenceText: String,
                    cacheDirectory: String) async throws -> LocalQwenAudio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let audio = try self.synthesizeBlocking(text, python: python, model: model,
                                                            referenceAudio: referenceAudio,
                                                            referenceText: referenceText,
                                                            cacheDirectory: cacheDirectory)
                    continuation.resume(returning: audio)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.resetWorker()
                continuation.resume()
            }
        }
    }

    deinit {
        if process?.isRunning == true { process?.terminate() }
    }

    private func synthesizeBlocking(_ text: String, python: String, model: String,
                                    referenceAudio: String, referenceText: String,
                                    cacheDirectory: String) throws -> LocalQwenAudio {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoding-tts-\(UUID().uuidString).opuspack")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try ensureWorker(python: python, model: model, cacheDirectory: cacheDirectory)
        let request = ["text": text, "reference_audio": referenceAudio,
                       "reference_text": referenceText, "path": temporaryURL.path]
        let payload = try JSONSerialization.data(withJSONObject: request) + Data([0x0a])
        do {
            try input?.write(contentsOf: payload)
            guard let worker = process else { throw LocalTTSError.failed("本地语音进程未启动") }
            let response = try readResponse(from: worker, timeout: 180)
            if let error = response["error"] as? String { throw LocalTTSError.failed(error) }
            guard let count = response["bytes"] as? Int, count > 0,
                  response["codec"] as? String == "opus",
                  let pcmSamples = response["pcmSamples"] as? Int,
                  pcmSamples > 0, pcmSamples <= 786_432,
                  let preSkipSamples = response["preSkipSamples"] as? Int,
                  (0...10_000).contains(preSkipSamples) else {
                throw LocalTTSError.failed("本地语音进程没有返回有效音频")
            }
            let packets = try Data(contentsOf: temporaryURL)
            guard packets.count == count else {
                throw LocalTTSError.failed("本地语音音频不完整")
            }
            return LocalQwenAudio(packets: packets, pcmSamples: pcmSamples,
                                  preSkipSamples: preSkipSamples)
        } catch {
            resetWorker()
            throw error
        }
    }

    private func ensureWorker(python: String, model: String, cacheDirectory: String) throws {
        let executable = Shell.findExecutable(python.trimmingCharacters(in: .whitespacesAndNewlines))
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachePath = cacheDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else { throw LocalTTSError.failed("找不到本地语音 Python：\(python)") }
        guard !modelName.isEmpty, !cachePath.isEmpty else {
            throw LocalTTSError.failed("本地语音模型或存储目录未配置")
        }
        guard let workerURL = Bundle.main.url(forResource: "qwen_tts_mlx_worker", withExtension: "py") else {
            throw LocalTTSError.failed("应用缺少本地 Qwen 语音组件")
        }

        let signature = [executable, modelName, cachePath].joined(separator: "\u{0}")
        if process?.isRunning == true && configuration == signature { return }
        resetWorker()
        try FileManager.default.createDirectory(atPath: cachePath, withIntermediateDirectories: true)

        let worker = Process()
        let requestPipe = Pipe()
        let responsePipe = Pipe()
        let errorPipe = Pipe()
        worker.executableURL = URL(fileURLWithPath: executable)
        worker.arguments = ["-u", workerURL.path, modelName]
        worker.environment = Shell.environment(extra: [
            "HF_HOME": cachePath,
            "HF_HUB_OFFLINE": "1",
            "PYTHONUNBUFFERED": "1"
        ])
        worker.standardInput = requestPipe
        worker.standardOutput = responsePipe
        worker.standardError = errorPipe
        errorLock.lock()
        errorTail = ""
        errorLock.unlock()
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty, let message = String(data: chunk, encoding: .utf8) else { return }
            self.errorLock.lock()
            self.errorTail = String((self.errorTail + message).suffix(2000))
            self.errorLock.unlock()
        }
        do {
            try worker.run()
            process = worker
            input = requestPipe.fileHandleForWriting
            output = responsePipe.fileHandleForReading
            errorOutput = errorPipe.fileHandleForReading
            configuration = signature
            let ready = try readResponse(from: worker, timeout: 180)
            if let error = ready["error"] as? String { throw LocalTTSError.failed(error) }
            guard ready["ready"] as? Bool == true else {
                throw LocalTTSError.failed("本地语音进程未报告就绪")
            }
        } catch {
            resetWorker()
            throw error
        }
    }

    private func readResponse(from worker: Process, timeout: TimeInterval) throws -> [String: Any] {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if worker.isRunning { worker.terminate() } }
        timer.resume()
        defer { timer.cancel() }

        while true {
            if let newline = outputBuffer.firstIndex(of: 0x0a) {
                let line = Data(outputBuffer[..<newline])
                outputBuffer.removeSubrange(...newline)
                let value = try JSONSerialization.jsonObject(with: line)
                guard let object = value as? [String: Any] else {
                    throw LocalTTSError.failed("本地语音进程返回了无效数据")
                }
                return object
            }
            guard let chunk = output?.availableData, !chunk.isEmpty else {
                errorLock.lock()
                let detail = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
                errorLock.unlock()
                throw LocalTTSError.failed(detail.isEmpty ? "本地语音进程已退出或超时" : detail)
            }
            outputBuffer.append(chunk)
        }
    }

    private func resetWorker() {
        if process?.isRunning == true { process?.terminate() }
        errorOutput?.readabilityHandler = nil
        input = nil
        output = nil
        errorOutput = nil
        outputBuffer.removeAll()
        process = nil
        configuration = ""
    }
}
