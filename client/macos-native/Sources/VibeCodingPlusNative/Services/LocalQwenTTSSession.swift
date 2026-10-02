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

/// HTTP client only: the independent service owns the single MLX model process.
enum SharedTTSClient {
    static let baseURL = URL(string: "http://127.0.0.1:18643")!

    static func request(_ path: String, body: [String: Any]? = nil,
                        timeout: TimeInterval = 300) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw LocalTTSError.failed("无法连接共享语音服务，请在设置中启动：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalTTSError.failed("共享语音服务返回无效响应")
        }
        guard http.statusCode == 200 else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw LocalTTSError.failed(object?["error"] as? String ?? "共享语音服务请求失败（\(http.statusCode)）")
        }
        return (data, http)
    }

    static func synthesize(_ text: String) async throws -> LocalQwenAudio {
        let (data, http) = try await request("v1/audio/speech", body: [
            "input": text, "model": "eira", "voice": "eira", "response_format": "opuspack"
        ])
        guard http.value(forHTTPHeaderField: "X-TTS-Voice") == "eira",
              let samples = Int(http.value(forHTTPHeaderField: "X-PCM-Samples") ?? ""),
              samples > 0, samples <= 786_432,
              let preSkip = Int(http.value(forHTTPHeaderField: "X-Opus-PreSkip") ?? ""),
              (0...10_000).contains(preSkip), !data.isEmpty else {
            throw LocalTTSError.failed("共享语音服务返回的音频无效或过长")
        }
        return LocalQwenAudio(packets: data, pcmSamples: samples, preSkipSamples: preSkip)
    }
}
