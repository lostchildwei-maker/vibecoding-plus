#include "lan_mic_app.h"
#include "opus_decoder.h"

#include <esp_log.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

namespace {
constexpr char kTag[] = "LanSpeaker";
constexpr size_t kHeaderSize = 5;
constexpr size_t kMaxReplyPcmBytes = 1536 * 1024;
constexpr size_t kPlaybackChunkSamples = 16000;
constexpr int kQueueDepth = 4;
constexpr int kSpeakerWarmupMs = 250;
constexpr int kDmaTailMs = 120;

size_t ReadU32(const uint8_t* bytes) {
    return static_cast<size_t>(bytes[0]) |
        (static_cast<size_t>(bytes[1]) << 8) |
        (static_cast<size_t>(bytes[2]) << 16) |
        (static_cast<size_t>(bytes[3]) << 24);
}

bool DecodeOpusReply(const uint8_t* data, size_t size,
                     size_t pre_skip_samples, std::vector<int16_t>& pcm) {
    OpusDecoderWrapper decoder(16000, 1, 60);
    size_t offset = 0;
    size_t written = 0;
    while (offset < size) {
        if (size - offset < 2) return false;
        const size_t packet_size = static_cast<size_t>(data[offset]) |
            (static_cast<size_t>(data[offset + 1]) << 8);
        offset += 2;
        if (packet_size == 0 || packet_size > 1275 || packet_size > size - offset) return false;
        std::vector<uint8_t> packet(data + offset, data + offset + packet_size);
        offset += packet_size;
        std::vector<int16_t> decoded;
        if (!decoder.Decode(std::move(packet), decoded)) return false;
        const size_t skipped = std::min(pre_skip_samples, decoded.size());
        pre_skip_samples -= skipped;
        const size_t usable = decoded.size() - skipped;
        const size_t copy_count = std::min(usable, pcm.size() - written);
        if (copy_count > 0) {
            memcpy(pcm.data() + written, decoded.data() + skipped,
                   copy_count * sizeof(int16_t));
            written += copy_count;
        }
    }
    return written == pcm.size();
}
}  // namespace

bool LanMicApp::StartSpeakerDownlink() {
    speaker_frame_queue_ = xQueueCreate(kQueueDepth, sizeof(PendingSpeakerFrame));
    if (speaker_frame_queue_ == nullptr) return false;
    // Opus decoding needs the same stack allowance as AudioService's
    // existing opus_codec task; the earlier PCM-only 4 KB stack overflows.
    if (xTaskCreate(SpeakerTaskEntry, "lan_speaker", 2048 * 13, this, 4,
                    &speaker_task_handle_) != pdPASS) {
        vQueueDelete(speaker_frame_queue_);
        speaker_frame_queue_ = nullptr;
        return false;
    }
    return true;
}

void LanMicApp::StopSpeakerDownlink() {
    CancelSpeakerPlayback();
    if (speaker_task_handle_ != nullptr) {
        vTaskDelete(speaker_task_handle_);
        speaker_task_handle_ = nullptr;
    }
    if (speaker_frame_queue_ != nullptr) {
        PendingSpeakerFrame frame;
        while (xQueueReceive(speaker_frame_queue_, &frame, 0) == pdPASS) {
            free(frame.data);
        }
        vQueueDelete(speaker_frame_queue_);
        speaker_frame_queue_ = nullptr;
    }
    if (codec_ != nullptr) codec_->EnableOutput(false);
    speaker_output_owned_.store(false, std::memory_order_release);
}

void LanMicApp::CancelSpeakerPlayback() {
    speaker_accepting_.store(false, std::memory_order_release);
    speaker_generation_.fetch_add(1, std::memory_order_acq_rel);
}

void LanMicApp::EnqueueSpeakerFrame(const char* data, size_t len) {
    if (speaker_frame_queue_ == nullptr || data == nullptr || len < kHeaderSize ||
        memcmp(data, "TTS", 3) != 0 ||
        (data[3] != '1' && data[3] != '2')) return;

    const char command = data[4];
    if (command == 'C') {
        CancelSpeakerPlayback();
        return;
    }
    if (command == 'S') {
        if (len != kHeaderSize + (data[3] == '2' ? 10 : 4)) return;
        speaker_generation_.fetch_add(1, std::memory_order_acq_rel);
        speaker_accepting_.store(true, std::memory_order_release);
        speaker_output_owned_.store(true, std::memory_order_release);
        ESP_LOGI(kTag, "Audio start frame, generation=%lu",
                 static_cast<unsigned long>(speaker_generation_.load(std::memory_order_acquire)));
    } else if (command == 'F') {
        if (!speaker_accepting_.load(std::memory_order_acquire) ||
            len <= kHeaderSize || len > kHeaderSize + kMaxReplyPcmBytes ||
            (data[3] == '1' && (len - kHeaderSize) % sizeof(int16_t) != 0)) {
            CancelSpeakerPlayback();
            return;
        }
        speaker_accepting_.store(false, std::memory_order_release);
        ESP_LOGI(kTag, "Complete audio message received: %u bytes",
                 static_cast<unsigned>(len - kHeaderSize));
    } else {
        return;
    }

    auto* copy = static_cast<uint8_t*>(malloc(len));
    if (copy == nullptr) {
        ESP_LOGW(kTag, "No memory for speaker frame");
        CancelSpeakerPlayback();
        return;
    }
    memcpy(copy, data, len);
    PendingSpeakerFrame frame{copy, len,
        speaker_generation_.load(std::memory_order_acquire)};
    if (xQueueSend(speaker_frame_queue_, &frame, 0) != pdPASS) {
        free(copy);
        ESP_LOGW(kTag, "Speaker frame queue full; cancelling playback");
        CancelSpeakerPlayback();
        SendJson("{\"type\":\"tts_state\",\"state\":\"error\",\"error\":\"buffer_full\"}");
    }
}

void LanMicApp::SpeakerTaskEntry(void* arg) {
    static_cast<LanMicApp*>(arg)->SpeakerTask();
    vTaskDelete(nullptr);
}

void LanMicApp::SpeakerTask() {
    uint32_t active_generation = 0;
    bool output_enabled = false;
    bool stream_started = false;
    bool compressed = false;
    bool wifi_boosted = false;
    std::vector<int16_t> reply_pcm;
    std::vector<int16_t> output_chunk;
    size_t expected_bytes = 0;
    size_t expected_samples = 0;
    size_t pre_skip_samples = 0;
    size_t received_bytes = 0;
    while (true) {
        if (stream_started && active_generation !=
                speaker_generation_.load(std::memory_order_acquire)) {
            if (output_enabled) codec_->EnableOutput(false);
            if (wifi_boosted) board_.SetPowerSaveLevel(PowerSaveLevel::BALANCED);
            output_enabled = false;
            wifi_boosted = false;
            stream_started = false;
            std::vector<int16_t>().swap(reply_pcm);
            SendJson("{\"type\":\"tts_state\",\"state\":\"cancelled\"}");
        }
        if (!stream_started && !speaker_accepting_.load(std::memory_order_acquire) &&
            uxQueueMessagesWaiting(speaker_frame_queue_) == 0) {
            speaker_output_owned_.store(false, std::memory_order_release);
        }

        PendingSpeakerFrame frame;
        if (xQueueReceive(speaker_frame_queue_, &frame, pdMS_TO_TICKS(20)) != pdPASS) continue;
        const uint32_t current = speaker_generation_.load(std::memory_order_acquire);
        if (frame.generation == current) {
            switch (frame.data[4]) {
                case 'S':
                    if (output_enabled) codec_->EnableOutput(false);
                    std::vector<int16_t>().swap(reply_pcm);
                    active_generation = current;
                    output_enabled = false;
                    compressed = frame.data[3] == '2';
                    expected_samples = compressed ? ReadU32(frame.data + 5) :
                        ReadU32(frame.data + 5) / sizeof(int16_t);
                    expected_bytes = compressed ? ReadU32(frame.data + 9) :
                        ReadU32(frame.data + 5);
                    pre_skip_samples = compressed ?
                        static_cast<size_t>(frame.data[13]) |
                            (static_cast<size_t>(frame.data[14]) << 8) : 0;
                    received_bytes = 0;
                    stream_started = expected_bytes > 0 &&
                        expected_bytes <= kMaxReplyPcmBytes &&
                        expected_samples > 0 &&
                        expected_samples <= kMaxReplyPcmBytes / sizeof(int16_t);
                    ESP_LOGI(kTag, "Allocating complete reply: %u PCM bytes, %u wire bytes",
                             static_cast<unsigned>(expected_samples * sizeof(int16_t)),
                             static_cast<unsigned>(expected_bytes));
                    if (stream_started) {
                        try {
                            reply_pcm.resize(expected_samples);
                        } catch (const std::bad_alloc&) {
                            stream_started = false;
                        }
                    }
                    if (!stream_started) {
                        CancelSpeakerPlayback();
                        SendJson("{\"type\":\"tts_state\",\"state\":\"error\",\"error\":\"audio_allocation\"}");
                    } else {
                        board_.SetPowerSaveLevel(PowerSaveLevel::PERFORMANCE);
                        wifi_boosted = true;
                        ESP_LOGI(kTag, "Wi-Fi power saving disabled for complete audio transfer");
                    }
                    break;
                case 'F':
                    if (stream_started && active_generation == current) {
                        const size_t bytes = frame.len - kHeaderSize;
                        if (bytes != expected_bytes || (frame.data[3] == '2') != compressed) {
                            CancelSpeakerPlayback();
                            SendJson("{\"type\":\"tts_state\",\"state\":\"error\",\"error\":\"audio_size\"}");
                            break;
                        }
                        if (compressed) {
                            if (!DecodeOpusReply(frame.data + kHeaderSize, bytes,
                                                 pre_skip_samples, reply_pcm)) {
                                CancelSpeakerPlayback();
                                SendJson("{\"type\":\"tts_state\",\"state\":\"error\",\"error\":\"opus_decode\"}");
                                break;
                            }
                        } else {
                            memcpy(reply_pcm.data(), frame.data + kHeaderSize, bytes);
                        }
                        received_bytes = bytes;
                        ESP_LOGI(kTag, "Complete reply stored: %u bytes",
                                 static_cast<unsigned>(received_bytes));
                        if (wifi_boosted) board_.SetPowerSaveLevel(PowerSaveLevel::BALANCED);
                        wifi_boosted = false;
                        codec_->EnableOutput(true);
                        output_enabled = true;
                        // The amplifier needs a brief lead-in after it is enabled.
                        // Feed silence through I2S so the first spoken phoneme
                        // is not lost while the output path settles.
                        output_chunk.assign(16000 * kSpeakerWarmupMs / 1000, 0);
                        codec_->OutputData(output_chunk);
                        ESP_LOGI(kTag, "Speaker enabled, starting playback");
                        SendJson("{\"type\":\"tts_state\",\"state\":\"playing\"}");
                        for (size_t offset = 0; offset < reply_pcm.size();
                             offset += kPlaybackChunkSamples) {
                            if (speaker_generation_.load(std::memory_order_acquire) != current) break;
                            const size_t end = std::min(offset + kPlaybackChunkSamples, reply_pcm.size());
                            output_chunk.assign(reply_pcm.begin() + offset, reply_pcm.begin() + end);
                            codec_->OutputData(output_chunk);
                            ESP_LOGI(kTag, "Playback progress: %u/%u samples",
                                     static_cast<unsigned>(end),
                                     static_cast<unsigned>(reply_pcm.size()));
                        }
                        if (speaker_generation_.load(std::memory_order_acquire) == current) {
                            vTaskDelay(pdMS_TO_TICKS(kDmaTailMs));
                            if (output_enabled) codec_->EnableOutput(false);
                            output_enabled = false;
                            stream_started = false;
                            std::vector<int16_t>().swap(reply_pcm);
                            speaker_output_owned_.store(false, std::memory_order_release);
                            SendJson("{\"type\":\"tts_state\",\"state\":\"done\"}");
                            ESP_LOGI(kTag, "Playback complete");
                        }
                    }
                    break;
            }
        } else if (frame.data[4] == 'S' || frame.data[4] == 'F') {
            ESP_LOGW(kTag, "Discarding stale %c frame: generation=%lu current=%lu",
                     frame.data[4], static_cast<unsigned long>(frame.generation),
                     static_cast<unsigned long>(current));
        }
        free(frame.data);
    }
}
