"""Install the approved shared TTS service and Hermes command provider on macOS.

Run with the existing Qwen environment. Changes are backed up privately before
runtime/config updates; unrelated Hermes YAML sections remain byte-for-byte intact.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.request import build_opener, ProxyHandler
from zoneinfo import ZoneInfo
import yaml

LABEL = "com.mac20777.vibecodingplus.tts"


def bootstrap_agent(domain, path):
    for attempt in range(20):
        result = subprocess.run(["/bin/launchctl", "bootstrap", domain, str(path)], capture_output=True)
        if result.returncode == 0:
            return
        registered = subprocess.run(["/bin/launchctl", "print", f"{domain}/{LABEL}"], capture_output=True)
        if registered.returncode == 0:
            subprocess.run(["/bin/launchctl", "kickstart", f"{domain}/{LABEL}"], check=True)
            return
        time.sleep(0.5)
    raise RuntimeError("macOS 未能注册共享语音服务：" + result.stderr.decode(errors="replace").strip())


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def hermes_config(text, command):
    data = yaml.safe_load(text) or {}
    tts = data.get("tts", {}) or {}
    previous = tts.get("provider")
    tts["provider"] = "vibecoding-local"
    tts.setdefault("providers", {})["vibecoding-local"] = {
        "type": "command", "command": command, "output_format": "wav",
        "voice": "eira", "voice_compatible": True, "max_text_length": 1500, "timeout": 300,
    }
    block = yaml.safe_dump({"tts": tts}, allow_unicode=True, sort_keys=False)
    match = re.search(r"^tts:\s*(?:#.*)?$", text, re.MULTILINE)
    if match:
        following = re.search(r"^[A-Za-z_][\w-]*:", text[match.end():], re.MULTILINE)
        end = match.end() + following.start() if following else len(text)
        updated = text[:match.start()] + block + text[end:]
    else:
        updated = text.rstrip() + "\n" + block
    # Catch duplicate or malformed output before replacing the user's file.
    expected = dict(data)
    expected["tts"] = tts
    if yaml.safe_load(updated) != expected:
        raise RuntimeError("Hermes 配置校验失败，原文件保持不变")
    return updated, previous


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", default="/Applications/VibeCoding Plus.app")
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--backup-root", type=Path, required=True)
    parser.add_argument("--no-start", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    home = args.home
    support = home / "Library/Application Support/vibecoding-plus"
    directory = support / "shared-tts"
    agent = home / f"Library/LaunchAgents/{LABEL}.plist"
    resources = Path(args.app) / "Contents/Resources"
    values = {}
    for line in (support / "config.env").read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    root = home / "Documents/LLM & Tools/语音转换与生成"
    config = {
        "python": values.get("QWEN_TTS_PYTHON", str(root / "qwen-tts-mlx/.venv/bin/python")),
        "model": values.get("QWEN_TTS_MODEL", str(root / "tts-model-compare/qwen-base")),
        "reference_audio": values.get("QWEN_TTS_REFERENCE_AUDIO", str(root / "qwen-tts-mlx/reference-eira.wav")),
        "reference_text": values.get("QWEN_TTS_REFERENCE_TEXT", "嗯，听到了，这条测试也通了。"),
        "cache_directory": values.get("QWEN_TTS_CACHE_DIRECTORY", str(root / "qwen-tts-mlx/models")),
        "keep_warm": values.get("QWEN_TTS_KEEP_WARM") == "1",
        "idle_seconds": max(60, int(values.get("QWEN_TTS_IDLE_SECONDS", "300"))),
    }
    for key in ("python", "model", "reference_audio"):
        if not Path(config[key]).exists():
            raise RuntimeError(f"共享语音服务缺少 {key}")
    for name in ("local_tts_service.py", "qwen_tts_mlx_worker.py"):
        if not (resources / name).is_file():
            raise RuntimeError(f"应用缺少语音组件：{name}")
    command = f"{shlex.quote(config['python'])} {shlex.quote(str(directory / 'local_tts_service.py'))} --text-file {{input_path}} --output {{output_path}}"
    hermes_paths = [home / ".hermes/config.yaml"]
    # Profiles explicitly overriding TTS need the same provider; inherited profiles follow the main config.
    for profile in sorted((home / ".hermes/profiles").glob("*/config.yaml")):
        if "tts" in (yaml.safe_load(profile.read_text()) or {}):
            hermes_paths.append(profile)
    updates = {}
    previous = {}
    for path in hermes_paths:
        updated, old = hermes_config(path.read_text(), command)
        updates[path] = updated.encode()
        previous[str(path.relative_to(home))] = old
    args.backup_root.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y%m%d-%H%M%S")
    backup = Path(tempfile.mkdtemp(prefix=stamp + "-shared-tts-", dir=args.backup_root))
    for path in [support / "config.env", agent, *hermes_paths]:
        if path.is_file():
            destination = backup / path.relative_to(home)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
    if directory.exists():
        shutil.copytree(directory, backup / "shared-tts")
    (backup / "installation.json").write_text(json.dumps({"previous_tts_providers": previous, "label": LABEL}, ensure_ascii=False, indent=2))
    domain = f"gui/{os.getuid()}"
    if not args.no_start:
        subprocess.run(["/bin/launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True)
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    for name in ("local_tts_service.py", "qwen_tts_mlx_worker.py"):
        atomic_write(directory / name, (resources / name).read_bytes())
    atomic_write(directory / "settings.json", json.dumps(config, ensure_ascii=False, indent=2).encode())
    log = str(directory / "service.log")
    plist = {
        "Label": LABEL, "ProgramArguments": [config["python"], "-u", str(directory / "local_tts_service.py"),
                                              "--config", str(directory / "settings.json"), "--worker", str(directory / "qwen_tts_mlx_worker.py")],
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
        "WorkingDirectory": str(directory), "StandardOutPath": log, "StandardErrorPath": log,
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "PYTHONUNBUFFERED": "1"},
    }
    atomic_write(agent, plistlib.dumps(plist))
    try:
        if not args.no_start:
            bootstrap_agent(domain, agent)
            deadline = time.monotonic() + 30
            ready = False
            last_health_error = ""
            while time.monotonic() < deadline:
                try:
                    with build_opener(ProxyHandler({})).open("http://127.0.0.1:18643/health", timeout=1) as response:
                        ready = json.load(response).get("service") == LABEL
                    if ready:
                        break
                except Exception as exc:
                    last_health_error = str(exc)
                    registered = subprocess.run(["/bin/launchctl", "print", f"{domain}/{LABEL}"], capture_output=True)
                    if registered.returncode != 0:
                        subprocess.run(["/bin/launchctl", "bootstrap", domain, str(agent)], capture_output=True)
                    time.sleep(0.5)
            if not ready:
                raise RuntimeError("共享语音服务未就绪，Hermes 配置保持不变：" + last_health_error)
        for path, data in updates.items():
            atomic_write(path, data)
    except Exception:
        if (directory / "service.log").exists():
            shutil.copy2(directory / "service.log", backup / "failed-service.log")
        if not args.no_start:
            subprocess.run(["/bin/launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True)
        for path in hermes_paths:
            shutil.copy2(backup / path.relative_to(home), path)
        old_agent = backup / agent.relative_to(home)
        if old_agent.exists():
            shutil.copy2(old_agent, agent)
        else:
            agent.unlink(missing_ok=True)
        shutil.rmtree(directory)
        if (backup / "shared-tts").exists():
            shutil.copytree(backup / "shared-tts", directory)
            if not args.no_start and old_agent.exists():
                bootstrap_agent(domain, agent)
        raise
    print(f"Shared TTS installed: http://127.0.0.1:18643")
    print(f"Hermes provider: vibecoding-local ({len(updates)} configuration files)")
    print(f"Private backup: {backup}")


if __name__ == "__main__":
    main()
