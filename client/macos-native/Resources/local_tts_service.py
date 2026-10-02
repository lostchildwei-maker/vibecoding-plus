"""Shared loopback TTS service. One MLX worker, one voice, timed process release.

The worker uses the existing MLX-Audio API; this lightweight coordinator owns
configuration, serialization and lifetime without importing MLX into the listener.
Also provides the client command for Hermes's official command-TTS integration.
"""
import argparse
import json
import logging
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, build_opener, ProxyHandler

SERVICE_ID = "com.mac20777.vibecodingplus.tts"
SERVICE_PORT = 18643
BASE_URL = f"http://127.0.0.1:{SERVICE_PORT}"
LOG = logging.getLogger("vibecoding.tts")


class TTSEngine:
    def __init__(self, config_path, worker_path):
        self.config_path = Path(config_path)
        self.worker_path = str(worker_path)
        self.lock = threading.Lock()
        self.process = None
        self.signature = None
        self.busy = False
        self.last_used = time.monotonic()
        self.last_error = ""
        self.generation_count = 0
        self.last_seconds = 0.0
        self.closed = threading.Event()

    def config(self):
        config = json.loads(self.config_path.read_text(encoding="utf-8"))
        for key in ("python", "model", "reference_audio", "reference_text", "cache_directory"):
            if not isinstance(config.get(key), str) or not config[key].strip():
                raise ValueError(f"语音服务配置缺少 {key}")
        if not Path(config["reference_audio"]).expanduser().is_file():
            raise ValueError("Eira 参考音频不存在")
        return config

    def status(self):
        config = self.config()
        process = self.process
        loaded = process is not None and process.poll() is None
        return {"service": SERVICE_ID, "status": "generating" if self.busy else "loaded" if loaded else "standby",
                "model_loaded": loaded, "worker_pid": process.pid if loaded else None,
                "voice": "eira", "model": config["model"], "keep_warm": bool(config.get("keep_warm", False)),
                "idle_seconds": int(config.get("idle_seconds", 300)), "last_error": self.last_error,
                "generation_count": self.generation_count, "last_generation_seconds": round(self.last_seconds, 2)}

    def stop_worker(self):
        process, self.process = self.process, None
        self.signature = None
        if process:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for stream in (process.stdin, process.stdout):
                if stream:
                    stream.close()
            LOG.info("模型进程已释放")

    def read_response(self, timeout=180):
        # Binary unbuffered stdout avoids readline blocking past the deadline.
        result = bytearray()
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                events = selector.select(max(0, deadline - time.monotonic()))
                if not events:
                    break
                chunk = os.read(self.process.stdout.fileno(), 1)
                if not chunk:
                    raise RuntimeError("本地语音模型进程已退出，请查看语音服务日志")
                if chunk == b"\n":
                    value = json.loads(result)
                    if "error" in value:
                        raise RuntimeError(value["error"])
                    return value
                result.extend(chunk)
                if len(result) > 65536:
                    raise RuntimeError("语音进程返回的数据过长")
        raise TimeoutError("本地语音模型加载或生成超时")

    def ensure_worker(self, config):
        signature = tuple(config[key] for key in ("python", "model", "cache_directory"))
        if self.process and self.process.poll() is None and self.signature == signature:
            return
        self.stop_worker()
        environment = {key: os.environ[key] for key in ("HOME", "PATH", "LANG", "TMPDIR") if key in os.environ}
        environment.update(HF_HOME=config["cache_directory"], HF_HUB_OFFLINE="1", PYTHONUNBUFFERED="1")
        self.process = subprocess.Popen([config["python"], "-u", self.worker_path, config["model"]],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=None, env=environment, bufsize=0)
        self.signature = signature
        if not self.read_response().get("ready"):
            raise RuntimeError("本地语音模型未报告就绪")
        LOG.info("模型已加载，worker=%s", self.process.pid)

    def synthesize(self, text, output_format):
        if not isinstance(text, str) or not text.strip() or len(text) > 4000:
            raise ValueError("语音文字必须为 1–4000 个字符")
        if output_format not in ("wav", "mp3", "ogg", "opus", "opuspack"):
            raise ValueError("不支持的音频格式")
        with self.lock:
            self.busy = True
            started = time.monotonic()
            try:
                config = self.config()
                self.ensure_worker(config)
                with tempfile.TemporaryDirectory(prefix="vibecoding-shared-tts-") as directory:
                    suffix = "ogg" if output_format == "opus" else output_format
                    path = Path(directory) / f"speech.{suffix}"
                    request = {"text": text.strip(), "reference_audio": config["reference_audio"],
                               "reference_text": config["reference_text"], "path": str(path), "format": output_format}
                    self.process.stdin.write(json.dumps(request, ensure_ascii=False).encode() + b"\n")
                    self.process.stdin.flush()
                    metadata = self.read_response()
                    audio = path.read_bytes()
                    if not audio or len(audio) != metadata.get("bytes"):
                        raise RuntimeError("语音模型返回的音频不完整")
                self.last_error = ""
                self.generation_count += 1
                self.last_seconds = time.monotonic() - started
                LOG.info("语音生成完成，format=%s duration=%.2fs bytes=%s", output_format, self.last_seconds, len(audio))
                return audio, metadata
            except Exception as exc:
                self.last_error = str(exc)
                self.stop_worker()
                raise
            finally:
                self.last_used = time.monotonic()
                self.busy = False

    def unload(self):
        with self.lock:
            self.stop_worker()

    def idle_loop(self):
        while not self.closed.wait(1):
            if not self.lock.acquire(blocking=False):
                continue
            try:
                config = self.config()
                if not config.get("keep_warm", False) and time.monotonic() - self.last_used >= max(1, int(config.get("idle_seconds", 300))):
                    self.stop_worker()
            except Exception as exc:
                self.last_error = str(exc)
            finally:
                self.lock.release()


class TTSHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port, engine):
        self.engine = engine
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(("127.0.0.1", port), TTSHandler)


class TTSHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # Never log reply text or request payloads.

    def send_json(self, status, value):
        self.send_bytes(status, json.dumps(value, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def send_bytes(self, status, data, content_type, metadata=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if metadata:
            self.send_header("X-PCM-Samples", str(metadata.get("pcmSamples", 0)))
            self.send_header("X-Opus-PreSkip", str(metadata.get("preSkipSamples", 0)))
            self.send_header("X-Audio-Sample-Rate", "16000")
            self.send_header("X-TTS-Voice", "eira")
        self.end_headers()
        self.wfile.write(data)

    def local_request(self):
        host = self.headers.get("Host", "").split(":")[0]
        if self.headers.get("Origin") or host not in ("127.0.0.1", "localhost"):
            self.send_json(403, {"error": "语音服务仅接受本机应用调用"})
            return False
        return True

    def do_GET(self):
        if not self.local_request():
            return
        try:
            if self.path == "/health":
                self.send_json(200, self.server.engine.status())
            elif self.path == "/v1/models":
                self.send_json(200, {"object": "list", "data": [{"id": "eira", "object": "model", "owned_by": "vibecoding"}]})
            else:
                self.send_json(404, {"error": "未知接口"})
        except Exception as exc:
            self.send_json(503, {"error": str(exc)})

    def do_POST(self):
        if not self.local_request():
            return
        if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            self.send_json(415, {"error": "需要 application/json"})
            return
        if not self.server.slots.acquire(blocking=False):
            self.send_json(503, {"error": "语音请求过多，请稍后重试"})
            return
        try:
            self.connection.settimeout(10)
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 65536:
                raise ValueError("请求大小无效")
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict):
                raise ValueError("请求必须为 JSON 对象")
            if self.path == "/control/unload":
                self.server.engine.unload()
                self.send_json(200, self.server.engine.status())
            elif self.path == "/v1/audio/speech":
                output_format = request.get("response_format", "wav")
                # Model/voice/ref overrides are intentionally ignored: all callers share the configured voice.
                audio, metadata = self.server.engine.synthesize(request.get("input"), output_format)
                content_type = {"wav": "audio/wav", "mp3": "audio/mpeg", "ogg": "audio/ogg", "opus": "audio/ogg", "opuspack": "application/octet-stream"}[output_format]
                self.send_bytes(200, audio, content_type, metadata)
            else:
                self.send_json(404, {"error": "未知接口"})
        except (ValueError, json.JSONDecodeError) as exc:
            self.send_json(400, {"error": str(exc)})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            LOG.error("语音请求失败：%s", exc)
            self.send_json(503, {"error": str(exc)})
        finally:
            self.server.slots.release()


def client_synthesize(text, output_path, base_url=BASE_URL):
    request = Request(base_url + "/v1/audio/speech", data=json.dumps({"model": "eira", "voice": "eira", "input": text, "response_format": "wav"}).encode(), headers={"Content-Type": "application/json"})
    with build_opener(ProxyHandler({})).open(request, timeout=300) as response:
        audio = response.read()
    if len(audio) < 44 or audio[:4] != b"RIFF":
        raise RuntimeError("语音服务未返回有效 WAV 音频")
    Path(output_path).write_bytes(audio)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    parser.add_argument("--worker")
    parser.add_argument("--port", type=int, default=SERVICE_PORT)
    parser.add_argument("--text-file")
    parser.add_argument("--output")
    args = parser.parse_args()
    if args.text_file:
        if not args.output:
            parser.error("--text-file requires --output")
        client_synthesize(Path(args.text_file).read_text(encoding="utf-8"), args.output)
        return
    if not args.config or not args.worker:
        parser.error("--config and --worker are required for the server")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    engine = TTSEngine(args.config, args.worker)
    engine.config()  # Validate before claiming the port, without loading the model.
    server = TTSHTTPServer(args.port, engine)
    idle = threading.Thread(target=engine.idle_loop, daemon=True)
    idle.start()

    def shutdown(signum, frame):
        engine.closed.set()
        # Interrupt a synthesis promptly; the request's cleanup closes pipes.
        if engine.process and engine.process.poll() is None:
            engine.process.terminate()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        LOG.info("共享语音服务待命：127.0.0.1:%s", args.port)
        server.serve_forever()
    finally:
        engine.closed.set()
        engine.unload()
        server.server_close()


if __name__ == "__main__":
    main()
