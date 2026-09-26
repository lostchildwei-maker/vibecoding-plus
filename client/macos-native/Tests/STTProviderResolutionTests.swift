import XCTest
@testable import VibeCodingPlusNative

final class STTProviderResolutionTests: XCTestCase {

    func testConfigProviderOverridesKeyInference() {
        var config = ServerConfig()
        config.sttProvider = "openai"
        config.openaiApiKey = "sk-test"
        config.qwenAsrApiKey = "qwen-test"
        let service = STTService(config: config)
        XCTAssertEqual(service.resolveProvider(), .openai)
    }

    func testKeyInferencePrefersWhisperWhenConfigured() {
        var config = ServerConfig()
        config.sttProvider = ""
        config.whisperCppModelPath = "/tmp/model.bin"
        config.openaiApiKey = "sk-test"
        let service = STTService(config: config)
        XCTAssertEqual(service.resolveProvider(), .whisperCpp)
    }

    func testLocalQwenSelectionDoesNotUseOnlineQwenRoute() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-mlx-config-\(UUID().uuidString).env")
        try "STT_PROVIDER=qwen_mlx\nQWEN_ASR_API_KEY=online-key\nQWEN_MLX_MODEL=Qwen/Qwen3-ASR-1.7B\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configURL) }
        var config = ServerConfig.load(from: configURL.path)
        XCTAssertEqual(config.resolvedSttProvider, "qwen_mlx")
        XCTAssertEqual(config.qwenMlxModel, "Qwen/Qwen3-ASR-1.7B")
        XCTAssertEqual(STTService(config: config).resolveProvider(), .qwenMlx)

        config.sttProvider = "qwen_asr"
        XCTAssertEqual(STTService(config: config).resolveProvider(), .qwenAsr)
    }

    func testLocalQwenWorkerTranscribesRepeatedlyWhenFixtureIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let wavPath = environment["QWEN_MLX_TEST_WAV"],
              let python = environment["QWEN_MLX_TEST_PYTHON"],
              let cache = environment["QWEN_MLX_TEST_CACHE"] else {
            throw XCTSkip("Set QWEN_MLX_TEST_WAV, QWEN_MLX_TEST_PYTHON and QWEN_MLX_TEST_CACHE for the local MLX integration check")
        }
        let audio = try Data(contentsOf: URL(fileURLWithPath: wavPath))
        let session = LocalQwenMLXSession()
        do {
            let first = try await session.transcribe(
                wavData: audio, python: python, model: "Qwen/Qwen3-ASR-0.6B",
                language: "Chinese", cacheDirectory: cache
            )
            let second = try await session.transcribe(
                wavData: audio, python: python, model: "Qwen/Qwen3-ASR-0.6B",
                language: "Chinese", cacheDirectory: cache
            )
            XCTAssertFalse(first.isEmpty)
            XCTAssertEqual(second, first)
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }
}
