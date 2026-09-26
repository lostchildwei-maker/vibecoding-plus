"""Private line-oriented bridge between the macOS app and mlx-qwen3-asr."""

import contextlib
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


try:
    from mlx_qwen3_asr import Session

    with contextlib.redirect_stdout(sys.stderr):
        session = Session(model=sys.argv[1])
    send({"ready": True})
except Exception as exc:
    send({"error": f"本地 Qwen 加载失败：{exc}"})
    raise SystemExit(1)

for line in sys.stdin:
    try:
        request = json.loads(line)
        language = request.get("language") or None
        context = request.get("context") or ""
        with contextlib.redirect_stdout(sys.stderr):
            result = session.transcribe(request["path"], language=language, context=context)
        send({"text": result.text})
    except Exception as exc:
        send({"error": f"本地 Qwen 转写失败：{exc}"})
