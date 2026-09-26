"""Private line-oriented bridge for local Qwen3-TTS synthesis on Apple MLX."""

import contextlib
import json
import subprocess
import sys
from pathlib import Path


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def extract_opus_packets(ogg_data):
    packets = []
    current = bytearray()
    offset = 0
    while offset < len(ogg_data):
        if ogg_data[offset:offset + 4] != b"OggS" or offset + 27 > len(ogg_data):
            raise ValueError("Opus 容器格式无效")
        count = ogg_data[offset + 26]
        header_end = offset + 27 + count
        if header_end > len(ogg_data):
            raise ValueError("Opus 容器头部不完整")
        laces = ogg_data[offset + 27:header_end]
        page_end = header_end + sum(laces)
        if page_end > len(ogg_data):
            raise ValueError("Opus 容器数据不完整")
        cursor = header_end
        for length in laces:
            current.extend(ogg_data[cursor:cursor + length])
            cursor += length
            if length < 255:
                packets.append(bytes(current))
                current.clear()
        offset = page_end
    if current or len(packets) < 3 or not packets[0].startswith(b"OpusHead") or not packets[1].startswith(b"OpusTags"):
        raise ValueError("Opus 音频包不完整")
    if len(packets[0]) < 12 or packets[0][9] != 1:
        raise ValueError("只支持单声道 Opus")
    pre_skip_48k = int.from_bytes(packets[0][10:12], "little")
    packed = bytearray()
    for packet in packets[2:]:
        if not 0 < len(packet) <= 1275:
            raise ValueError("Opus 音频包长度无效")
        packed.extend(len(packet).to_bytes(2, "little"))
        packed.extend(packet)
    return bytes(packed), (pre_skip_48k + 1) // 3


try:
    import mlx.core as mx
    import numpy as np
    import soxr
    import imageio_ffmpeg
    from mlx_audio.tts.utils import load_model

    with contextlib.redirect_stdout(sys.stderr):
        model = load_model(sys.argv[1])
    send({"ready": True})
except Exception as exc:
    send({"error": f"本地 Qwen 语音模型加载失败：{exc}"})
    raise SystemExit(1)


for line in sys.stdin:
    try:
        request = json.loads(line)
        text = request["text"].strip()
        if not text:
            raise ValueError("语音回复内容为空")
        output_path = Path(request["path"])
        raw_path = output_path.with_suffix(".pcm")
        ogg_path = output_path.with_suffix(".opus")
        pieces = []
        sample_rate = None
        with contextlib.redirect_stdout(sys.stderr):
            for result in model.generate_custom_voice(
                text=text,
                speaker=request.get("speaker") or "Serena",
                language="Chinese",
                stream=False,
            ):
                mx.eval(result.audio)
                pieces.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
                sample_rate = int(result.sample_rate)
        if not pieces or not any(piece.size for piece in pieces):
            raise ValueError("模型没有生成语音")
        audio = np.concatenate(pieces)
        if sample_rate != 16000:
            audio = soxr.resample(audio, sample_rate, 16000)
        pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2")
        try:
            raw_path.write_bytes(pcm.tobytes())
            command = [
                imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-loglevel", "error",
                "-y", "-f", "s16le", "-ar", "16000", "-ac", "1",
                "-i", str(raw_path), "-c:a", "libopus", "-b:a", "32000",
                "-application", "voip", "-frame_duration", "20", "-f", "ogg",
                str(ogg_path),
            ]
            subprocess.run(command, check=True, capture_output=True, timeout=30)
            packed, pre_skip = extract_opus_packets(ogg_path.read_bytes())
            output_path.write_bytes(packed)
            send({"bytes": len(packed), "codec": "opus", "pcmSamples": int(pcm.size),
                  "preSkipSamples": pre_skip})
        finally:
            raw_path.unlink(missing_ok=True)
            ogg_path.unlink(missing_ok=True)
    except Exception as exc:
        send({"error": f"本地 Qwen 语音合成失败：{exc}"})
