"""Regression tests for shared-model ownership, idle release and Hermes configuration."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import shlex
import struct
import subprocess
import wave
import io
from concurrent.futures import ThreadPoolExecutor
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler

ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


service = load_module("shared_tts", ROOT / "client/macos-native/Resources/local_tts_service.py")
installer = load_module("tts_installer", ROOT / "scripts/install-shared-tts.py")

FAKE_WORKER = '''import json, sys, wave, struct
print(json.dumps({"ready": True}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    value = 123 if request["reference_text"] == "shared voice" else 456
    with wave.open(request["path"], "wb") as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
        wav.writeframes(struct.pack("<h", value) * 160)
    print(json.dumps({"bytes": 364, "codec": "wav", "pcmSamples": 160}), flush=True)
'''


class SharedTTSTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.reference = self.directory / "reference.wav"
        self.reference.touch()
        self.config = {"python": sys.executable, "model": "fake", "reference_audio": str(self.reference),
                       "reference_text": "shared voice", "cache_directory": str(self.directory),
                       "idle_seconds": 1, "keep_warm": False}
        self.config_path = self.directory / "settings.json"
        self.write_config()
        worker = self.directory / "worker.py"
        worker.write_text(FAKE_WORKER)
        self.engine = service.TTSEngine(self.config_path, worker)
        self.server = service.TTSHTTPServer(0, self.engine)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.idle = threading.Thread(target=self.engine.idle_loop, daemon=True)
        self.idle.start()

    def tearDown(self):
        self.engine.closed.set()
        self.server.shutdown()
        self.thread.join()
        self.idle.join()
        self.engine.unload()
        self.server.server_close()
        self.temporary.cleanup()

    def write_config(self):
        installer.atomic_write(self.config_path, json.dumps(self.config).encode())

    def speech(self, **extra):
        payload = {"input": "test", "response_format": "wav", **extra}
        request = Request(self.url + "/v1/audio/speech", data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
        with build_opener(ProxyHandler({})).open(request, timeout=5) as response:
            self.assertEqual(response.headers["X-TTS-Voice"], "eira")
            return response.read()

    def test_two_callers_reuse_one_worker_and_ignore_voice_overrides(self):
        audio1 = self.speech(voice="another", ref_text="another", ref_audio="/wrong")
        first_pid = self.engine.status()["worker_pid"]
        audio2 = self.speech(model="another")
        self.assertEqual(audio1, audio2)
        self.assertEqual(first_pid, self.engine.status()["worker_pid"])
        self.assertEqual(self.engine.generation_count, 2)
        self.config["reference_text"] = "changed shared voice"
        self.write_config()
        self.assertNotEqual(audio1, self.speech())

    def test_concurrent_requests_are_serialized_into_one_model(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            audio = list(pool.map(lambda _: self.speech(), range(2)))
        self.assertEqual(audio[0], audio[1])
        self.assertEqual(self.engine.generation_count, 2)

    def test_idle_release_exits_worker_and_next_request_reloads(self):
        self.speech()
        process = self.engine.process
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline and self.engine.status()["model_loaded"]:
            time.sleep(0.05)
        self.assertFalse(self.engine.status()["model_loaded"])
        self.assertIsNotNone(process.poll())
        self.speech()
        self.assertNotEqual(process.pid, self.engine.status()["worker_pid"])

    def test_keep_warm_and_explicit_release(self):
        self.config["keep_warm"] = True
        self.write_config()
        self.speech()
        time.sleep(2)
        self.assertTrue(self.engine.status()["model_loaded"])
        self.engine.unload()
        self.assertFalse(self.engine.status()["model_loaded"])

    def test_browser_origin_is_rejected_and_bad_input_does_not_load(self):
        request = Request(self.url + "/v1/audio/speech", data=b'{"input":"test"}', headers={"Content-Type": "application/json", "Origin": "https://example.com"})
        with self.assertRaises(HTTPError) as error:
            build_opener(ProxyHandler({})).open(request)
        self.assertEqual(error.exception.code, 403)
        with self.assertRaises(HTTPError) as error:
            self.speech(input="")
        self.assertEqual(error.exception.code, 400)
        self.assertFalse(self.engine.status()["model_loaded"])

    def test_hermes_update_preserves_other_configuration(self):
        text = '# comment\nmodel:\n  provider: custom\n  token: private-value\ntts:\n  provider: minimax-cn\n  minimax:\n    region: cn\nstt:\n  provider: local\n# trailing comment\n'
        updated, previous = installer.hermes_config(text, "python client --text-file {input_path} --output {output_path}")
        self.assertEqual(previous, "minimax-cn")
        self.assertEqual(text.split("tts:")[0], updated.split("tts:")[0])
        self.assertEqual(text.split("stt:")[1], updated.split("stt:")[1])
        result = installer.yaml.safe_load(updated)
        self.assertEqual(result["tts"]["provider"], "vibecoding-local")
        self.assertEqual(result["tts"]["minimax"], {"region": "cn"})


@unittest.skipUnless(os.environ.get("SHARED_TTS_LIVE") == "1", "Set SHARED_TTS_LIVE=1 for the actual Qwen/Hermes integration")
class LiveSharedTTSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        directory = Path(cls.temporary.name)
        values = {}
        for line in (Path.home() / "Library/Application Support/vibecoding-plus/config.env").read_text().splitlines():
            if not line.lstrip().startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
        config = {key: values[env] for key, env in {
            "python": "QWEN_TTS_PYTHON", "model": "QWEN_TTS_MODEL",
            "reference_audio": "QWEN_TTS_REFERENCE_AUDIO", "reference_text": "QWEN_TTS_REFERENCE_TEXT",
            "cache_directory": "QWEN_TTS_CACHE_DIRECTORY"}.items()}
        config.update(keep_warm=True, idle_seconds=300)
        settings = directory / "settings.json"
        settings.write_text(json.dumps(config))
        cls.engine = service.TTSEngine(settings, ROOT / "client/macos-native/Resources/qwen_tts_mlx_worker.py")
        cls.server = service.TTSHTTPServer(service.SERVICE_PORT, cls.engine)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.engine.unload()
        cls.server.server_close()
        cls.temporary.cleanup()

    def test_real_model_wave_and_note4_packets_share_worker(self):
        path = Path(self.temporary.name) / "eira.wav"
        service.client_synthesize("你好，我是 Eira。", path)
        worker = self.engine.process.pid
        with wave.open(str(path), "rb") as wav:
            self.assertEqual(wav.getframerate(), 16000)
            pcm = wav.readframes(wav.getnframes())
            samples = struct.unpack(f"<{len(pcm)//2}h", pcm)
            self.assertGreater(max(abs(value) for value in samples), 100)
        request = Request(service.BASE_URL + "/v1/audio/speech", data=json.dumps({"input": "共享语音已接通。", "response_format": "opuspack"}).encode(), headers={"Content-Type": "application/json"})
        with build_opener(ProxyHandler({})).open(request, timeout=300) as response:
            packed = response.read()
            self.assertGreater(int(response.headers["X-PCM-Samples"]), 1600)
        offset = 0
        count = 0
        while offset < len(packed):
            size = int.from_bytes(packed[offset:offset+2], "little")
            self.assertTrue(0 < size <= 1275)
            offset += size + 2
            count += 1
        self.assertEqual(offset, len(packed))
        self.assertGreater(count, 1)
        self.assertEqual(worker, self.engine.process.pid)
        print(f"\nActual Qwen verified: one worker {worker}, WAV + {count} Note 4 Opus packets", flush=True)

    def test_hermes_official_command_provider_reaches_service(self):
        candidates = list((Path.home() / ".hermes/installs").glob("*/environments/*"))
        environment = Path(os.environ["HERMES_TEST_ENVIRONMENT"]) if os.environ.get("HERMES_TEST_ENVIRONMENT") else max(candidates, key=lambda path: path.stat().st_mtime)
        self.assertTrue((environment / "venv/bin/python").exists())
        output = Path(self.temporary.name) / "hermes.wav"
        command = f"{shlex.quote(sys.executable)} {shlex.quote(str(ROOT / 'client/macos-native/Resources/local_tts_service.py'))} --text-file {{input_path}} --output {{output_path}}"
        code = ('import json,sys; from tools.tts_command_provider import _generate_command_tts; '
                'cfg=json.loads(sys.argv[1]); print(_generate_command_tts("Hermes 本地语音测试。", sys.argv[2], "vibecoding-local", cfg, {}))')
        result = subprocess.run([str(environment / "venv/bin/python"), "-c", code,
                                 json.dumps({"command": command, "output_format": "wav", "timeout": 300}), str(output)],
                                cwd=environment / "workspace", capture_output=True, text=True, timeout=360)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        self.assertTrue(output.read_bytes().startswith(b"RIFF"))
        print("\nHermes official command-TTS -> shared service -> actual Eira WAV: passed", flush=True)


@unittest.skipUnless(os.environ.get("SHARED_TTS_INSTALLED") == "1", "Set SHARED_TTS_INSTALLED=1 to verify the formal installation")
class InstalledSharedTTSTests(unittest.TestCase):
    def test_configured_hermes_tool_and_client_share_the_installed_service(self):
        candidates = list((Path.home() / ".hermes/installs").glob("*/environments/*"))
        environment = Path(os.environ["HERMES_TEST_ENVIRONMENT"]) if os.environ.get("HERMES_TEST_ENVIRONMENT") else max(candidates, key=lambda path: path.stat().st_mtime)
        output = ROOT.parents[1] / "artifacts/shared-tts/eira-hermes.wav"
        output.parent.mkdir(parents=True, exist_ok=True)
        code = ('import sys; from tools.tts_tool import text_to_speech_tool; '
                'print(text_to_speech_tool("你好，我是 Eira。Hermes 和 VibeCoding 现在共用我的声音。", output_path=sys.argv[1]))')
        result = subprocess.run([str(environment / "venv/bin/python"), "-c", code, str(output)],
                                cwd=environment / "workspace", capture_output=True, text=True, timeout=360)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        envelope = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertTrue(envelope.get("success"), envelope)
        self.assertEqual(envelope["provider"], "vibecoding-local")
        with wave.open(envelope["file_path"], "rb") as wav:
            self.assertEqual(wav.getframerate(), 16000)
            seconds = wav.getnframes() / wav.getframerate()
            pcm = wav.readframes(wav.getnframes())
        samples = struct.unpack(f"<{len(pcm)//2}h", pcm)
        self.assertGreater(max(abs(value) for value in samples), 100)
        with build_opener(ProxyHandler({})).open(service.BASE_URL + "/health", timeout=3) as response:
            first = json.load(response)
        request = Request(service.BASE_URL + "/v1/audio/speech", data=json.dumps({"input": "Note 4 共享音色验证。", "response_format": "opuspack"}).encode(), headers={"Content-Type": "application/json"})
        with build_opener(ProxyHandler({})).open(request, timeout=300) as response:
            self.assertEqual(response.headers["X-TTS-Voice"], "eira")
            self.assertGreater(len(response.read()), 0)
        with build_opener(ProxyHandler({})).open(service.BASE_URL + "/health", timeout=3) as response:
            second = json.load(response)
        self.assertEqual(first["worker_pid"], second["worker_pid"])
        report = {"hermes_provider": envelope["provider"], "voice": "eira", "wav_seconds": round(seconds, 2),
                  "same_model_worker": True, "worker_pid": second["worker_pid"], "idle_seconds": second["idle_seconds"],
                  "audio_path": envelope["file_path"], "service_status": second["status"]}
        (output.parent / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print("\n" + json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
