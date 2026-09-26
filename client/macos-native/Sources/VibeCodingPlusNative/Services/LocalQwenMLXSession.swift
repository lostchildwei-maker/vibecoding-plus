import Foundation

/// Keeps one MLX model in a local Python worker for repeated Note 4 recordings.
/// Requests are serialized because a Session owns mutable decoder state.
final class LocalQwenMLXSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mac20777.vibecodingplus.qwen-mlx", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var outputBuffer = Data()
    private var configuration = ""
    private let errorLock = NSLock()
    private var errorTail = ""

    func transcribe(wavData: Data, python: String, model: String,
                    language: String, cacheDirectory: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let text = try self.transcribeBlocking(
                        wavData: wavData, python: python, model: model,
                        language: language, cacheDirectory: cacheDirectory
                    )
                    continuation.resume(returning: text)
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

    private func transcribeBlocking(wavData: Data, python: String, model: String,
                                    language: String, cacheDirectory: String) throws -> String {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoding-qwen-\(UUID().uuidString).wav")
        try wavData.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try ensureWorker(python: python, model: model, cacheDirectory: cacheDirectory)
        let request: [String: String] = [
            "path": temporaryURL.path,
            "language": language.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        let payload = try JSONSerialization.data(withJSONObject: request) + Data([0x0a])
        do {
            try input?.write(contentsOf: payload)
            guard let worker = process else { throw STTError.processFailed("本地 Qwen 进程未启动") }
            let response = try readResponse(from: worker, timeout: 90)
            if let error = response["error"] as? String {
                throw STTError.processFailed(error)
            }
            let text = (response["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw STTError.emptyTranscript }
            return text
        } catch {
            // A failed request can leave a partial line in the pipe. Start clean next time.
            resetWorker()
            throw error
        }
    }

    private func ensureWorker(python: String, model: String, cacheDirectory: String) throws {
        let pythonPath = python.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachePath = cacheDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else { throw STTError.processFailed("本地 Qwen 模型未填写") }
        guard !cachePath.isEmpty else { throw STTError.processFailed("模型存储目录未填写") }
        let executable = Shell.findExecutable(pythonPath)
        guard !executable.isEmpty else { throw STTError.processFailed("找不到可运行的 Python：\(pythonPath)") }
        guard let workerURL = Bundle.main.url(forResource: "qwen_mlx_worker", withExtension: "py") else {
            throw STTError.processFailed("应用缺少本地 Qwen 转写组件")
        }

        let signature = [executable, modelName, cachePath].joined(separator: "\u{0}")
        if process?.isRunning == true && configuration == signature { return }
        resetWorker()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: cachePath, isDirectory: true),
            withIntermediateDirectories: true
        )

        let worker = Process()
        let requestPipe = Pipe()
        let responsePipe = Pipe()
        let errorPipe = Pipe()
        worker.executableURL = URL(fileURLWithPath: executable)
        worker.arguments = ["-u", workerURL.path, modelName]
        worker.environment = Shell.environment(extra: ["HF_HOME": cachePath, "PYTHONUNBUFFERED": "1"])
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
            if let error = ready["error"] as? String {
                throw STTError.processFailed(error)
            }
            guard ready["ready"] as? Bool == true else {
                throw STTError.processFailed("本地 Qwen 进程未报告就绪")
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
                    throw STTError.processFailed("本地 Qwen 返回了无效数据")
                }
                return object
            }
            // availableData returns when the worker writes a short JSON line;
            // read(upToCount:) may wait for the full requested length on a pipe.
            guard let chunk = output?.availableData, !chunk.isEmpty else {
                errorLock.lock()
                let detail = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
                errorLock.unlock()
                throw STTError.processFailed(detail.isEmpty ? "本地 Qwen 进程已退出或超时" : detail)
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
