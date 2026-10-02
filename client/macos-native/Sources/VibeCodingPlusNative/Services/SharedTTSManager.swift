import Foundation

struct SharedTTSStatus: Decodable {
    let service: String
    let status: String
    let model_loaded: Bool
    let worker_pid: Int?
    let voice: String
    let keep_warm: Bool
    let idle_seconds: Int
    let last_error: String
    let generation_count: Int
    let last_generation_seconds: Double

    var label: String {
        switch status {
        case "generating": "正在生成声音"
        case "loaded": "模型已加载"
        default: "待命 · 模型未加载"
        }
    }
}

enum SharedTTSManager {
    static let label = "com.mac20777.vibecodingplus.tts"
    static var directory: URL {
        SettingsStore().configDirectory.appendingPathComponent("shared-tts", isDirectory: true)
    }
    static var logURL: URL { directory.appendingPathComponent("service.log") }
    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var domain: String { "gui/\(getuid())" }
    static var installed: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    static var runtimeNeedsUpdate: Bool {
        for resource in ["local_tts_service", "qwen_tts_mlx_worker"] {
            guard let source = Bundle.main.url(forResource: resource, withExtension: "py"),
                  let packaged = try? Data(contentsOf: source),
                  let installed = try? Data(contentsOf: directory.appendingPathComponent("\(resource).py")),
                  packaged == installed else { return true }
        }
        return false
    }

    static func configure(_ config: AppConfig) throws {
        let fm = FileManager.default
        let python = Shell.findExecutable(config.qwenTTSPython)
        guard !python.isEmpty else { throw LocalTTSError.failed("找不到 Qwen 语音运行环境") }
        guard fm.fileExists(atPath: config.qwenTTSReferenceAudio),
              !config.qwenTTSReferenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fm.fileExists(atPath: config.qwenTTSModel) else {
            throw LocalTTSError.failed("请先配置有效的模型、参考音频和参考文字")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for resource in ["local_tts_service", "qwen_tts_mlx_worker"] {
            guard let source = Bundle.main.url(forResource: resource, withExtension: "py") else {
                throw LocalTTSError.failed("应用缺少共享语音组件：\(resource)")
            }
            let destination = directory.appendingPathComponent("\(resource).py")
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        let settings: [String: Any] = [
            "python": python, "model": config.qwenTTSModel,
            "reference_audio": config.qwenTTSReferenceAudio, "reference_text": config.qwenTTSReferenceText,
            "cache_directory": config.qwenTTSCacheDirectory,
            "idle_seconds": max(60, config.qwenTTSIdleSeconds), "keep_warm": config.qwenTTSKeepWarm
        ]
        let settingsURL = directory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            .write(to: settingsURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [python, "-u", directory.appendingPathComponent("local_tts_service.py").path,
                                 "--config", settingsURL.path,
                                 "--worker", directory.appendingPathComponent("qwen_tts_mlx_worker.py").path],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
            "WorkingDirectory": directory.path,
            "StandardOutPath": logURL.path, "StandardErrorPath": logURL.path,
            "EnvironmentVariables": ["PATH": Shell.toolPath(), "PYTHONUNBUFFERED": "1"]
        ]
        try fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            .write(to: agentURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentURL.path)
    }

    static func start(_ config: AppConfig) async throws {
        try configure(config)
        let loaded = await Shell.run("/bin/launchctl", arguments: ["print", "\(domain)/\(label)"])
        var result: (code: Int32, output: String)
        if loaded.code == 0 {
            result = await Shell.run("/bin/launchctl", arguments: ["kickstart", "\(domain)/\(label)"])
        } else {
            result = await Shell.run("/bin/launchctl", arguments: ["bootstrap", domain, agentURL.path])
            // launchd can still be removing a job immediately after bootout.
            for _ in 0..<10 where result.code != 0 {
                try await Task.sleep(for: .milliseconds(500))
                let registered = await Shell.run("/bin/launchctl", arguments: ["print", "\(domain)/\(label)"])
                if registered.code == 0 {
                    result = await Shell.run("/bin/launchctl", arguments: ["kickstart", "\(domain)/\(label)"])
                } else {
                    result = await Shell.run("/bin/launchctl", arguments: ["bootstrap", domain, agentURL.path])
                }
            }
        }
        guard result.code == 0 else { throw LocalTTSError.failed("语音服务启动失败：\(result.output)") }
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if (try? await status(timeout: 0.5)) != nil { return }
            // A recently booted-out registration may disappear after kickstart
            // returned success. Re-register once launchd finishes removing it.
            let registered = await Shell.run("/bin/launchctl", arguments: ["print", "\(domain)/\(label)"])
            if registered.code != 0 {
                _ = await Shell.run("/bin/launchctl", arguments: ["bootstrap", domain, agentURL.path])
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LocalTTSError.failed("语音服务尚未就绪，请查看日志")
    }

    static func stop() async throws {
        let loaded = await Shell.run("/bin/launchctl", arguments: ["print", "\(domain)/\(label)"])
        guard loaded.code == 0 else { return }
        let result = await Shell.run("/bin/launchctl", arguments: ["bootout", "\(domain)/\(label)"])
        guard result.code == 0 else { throw LocalTTSError.failed("语音服务停止失败：\(result.output)") }
        for _ in 0..<60 {
            let registered = await Shell.run("/bin/launchctl", arguments: ["print", "\(domain)/\(label)"])
            if registered.code != 0 { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LocalTTSError.failed("语音服务正在停止，请稍后再试")
    }

    static func restart(_ config: AppConfig) async throws {
        try await stop()
        try await start(config)
    }

    static func status(timeout: TimeInterval = 2) async throws -> SharedTTSStatus {
        let (data, _) = try await SharedTTSClient.request("health", timeout: timeout)
        let value = try JSONDecoder().decode(SharedTTSStatus.self, from: data)
        guard value.service == label else { throw LocalTTSError.failed("本地端口被其他服务占用") }
        return value
    }

    static func releaseModel() async throws {
        _ = try await SharedTTSClient.request("control/unload", body: [:])
    }

    static func testVoice() async throws -> URL {
        let (data, _) = try await SharedTTSClient.request("v1/audio/speech", body: [
            "input": "你好，我是 Eira。VibeCoding 和 Hermes 现在共用我的声音。",
            "model": "eira", "response_format": "wav"
        ])
        let url = directory.appendingPathComponent("preview.wav")
        try data.write(to: url, options: .atomic)
        return url
    }
}
