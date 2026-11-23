"""Stream local Murmury transcripts to the presenter. PCM never crosses the network."""
import json
import os
from pathlib import Path
import sys
import threading

REVISION = "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
MODEL_SIZE = 1613977612

def emit(kind, **fields):
    print(json.dumps({"type": kind, **fields}), flush=True)

def model_folder():
    return Path.home() / "Library/Application Support/TextreamStudio/Whisper" / REVISION

def installed():
    folder = model_folder()
    weights = folder / "weights.safetensors"
    return (folder / "config.json").is_file() and weights.is_file() and weights.stat().st_size == MODEL_SIZE

def prepare():
    from huggingface_hub import snapshot_download
    from upstream import stt
    folder = model_folder()
    if not installed():
        emit("status", stage="downloading", message="正在下载 Whisper Turbo（约 1.6 GB）")
        snapshot_download(stt.MLX_MODEL, revision=REVISION, local_dir=folder,
                          allow_patterns=["config.json", "weights.safetensors"], token=False)
    stt.MLX_MODEL = str(folder)
    emit("status", stage="loading", message="Whisper Turbo 正在加载")

def wav_chunks(path):
    import wave
    import numpy as np
    import time
    with wave.open(path, "rb") as audio:
        if (audio.getframerate(), audio.getsampwidth(), audio.getnchannels()) != (16000, 2, 1):
            raise ValueError("Expected mono PCM16 at 16 kHz")
        start, count = time.monotonic(), 0
        while raw := audio.readframes(1440):
            samples = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768
            count += len(samples)
            time.sleep(max(0, start + count / 16000 - time.monotonic()))
            yield samples.tobytes()
        for _ in range(6):
            yield bytes(1440 * 4)


def main():
    if sys.argv[1:2] == ["inventory"]:
        emit("inventory", installed=installed())
        return 0
    # The pipe closes on cancellation, app exit or a host crash, including during model preparation.
    def watch_host():
        while os.read(0, 1):
            pass
        os._exit(0)
    threading.Thread(target=watch_host, daemon=True).start()
    model_loaded = False
    def loaded():
        nonlocal model_loaded
        model_loaded = True
        emit("modelLoaded")

    try:
        from upstream import listen, stt
        prepare()
        source, language = sys.argv[1:3]
        if source not in ("system", "mic", "wav"):
            raise ValueError("unknown audio source")
        stt.LANGUAGE = language.split("-")[0] if language != "auto" else None
        def level(value):
            emit("level", rms=value)

        transcriber = listen.StreamingTranscriber(source, partial_every=0.6 if source == "system" else 0.4,
                                                  fast_margin=0.2 if source == "system" else 0,
                                                  on_level=level if source != "system" else None)
        if source == "wav":
            listen.warm_up()
            loaded()
            events = transcriber.decode_chunks(wav_chunks(sys.argv[3]), on_ready=lambda: emit("ready"))
        else:
            events = transcriber.events(on_ready=lambda: emit("ready"), on_model_loaded=loaded)
        for event in events:
            emit("transcript", text=event.text, final=event.kind == "final")
    except Exception as error:
        reason = ("Whisper 的音频输入中断，请检查输入设备并重新开始。" if model_loaded
                  else "Whisper Turbo 加载失败。请检查模型下载和本机运行环境，或切换 Apple 听写。")
        emit("error", message=str(error) if isinstance(error, PermissionError) else reason)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
