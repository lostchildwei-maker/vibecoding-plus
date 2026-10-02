import XCTest
@testable import VibeCodingPlusNative

final class SharedTTSClientTests: XCTestCase {
    func testInstalledSharedServiceGeneratesNote4OpusAudio() async throws {
        guard ProcessInfo.processInfo.environment["QWEN_SHARED_TTS_TEST"] == "1" else {
            throw XCTSkip("Set QWEN_SHARED_TTS_TEST=1 with the shared service running for real-model validation")
        }
        let audio = try await SharedTTSClient.synthesize("你好，我是 Eira。")
        XCTAssertGreaterThan(audio.packets.count, 0)
        XCTAssertGreaterThan(audio.pcmSamples, 1600)
        XCTAssertLessThanOrEqual(audio.pcmSamples, 786_432)
        var offset = 0
        var packetCount = 0
        while offset < audio.packets.count {
            XCTAssertLessThanOrEqual(offset + 2, audio.packets.count)
            guard offset + 2 <= audio.packets.count else { return }
            let size = Int(audio.packets[offset]) | Int(audio.packets[offset + 1]) << 8
            XCTAssertGreaterThan(size, 0)
            XCTAssertLessThanOrEqual(size, 1275)
            offset += 2 + size
            packetCount += 1
        }
        XCTAssertEqual(offset, audio.packets.count)
        XCTAssertGreaterThan(packetCount, 1)
    }
}
