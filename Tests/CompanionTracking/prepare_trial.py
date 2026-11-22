#!/usr/bin/env python3
"""Synthesize a locally annotated audio suite and capture shared offline transcripts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import wave

RATE = 16_000
DEFAULT_GAP_MS = 450
RECOGNITION_SLACK_MS = 160


def write_audio(text, voice, rate, destination):
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "phrase.txt"
        source.write_text(text, encoding="utf-8")
        audio = Path(tmp) / "phrase.aiff"
        subprocess.run(["say", "-v", voice, "-r", str(rate), "-f", str(source), "-o", str(audio)], check=True)
        pcm = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(audio), "-ar", str(RATE), "-ac", "1", "-f", "s16le", "-"],
            check=True, capture_output=True,
        ).stdout
    destination.extend(pcm)


def make_clip(clip, output):
    pcm = bytearray()
    events = []
    for phrase in clip["phrases"]:
        voice = phrase.get("voice", clip.get("voice", "Samantha"))
        rate = phrase.get("rate", clip.get("rate", 150))
        write_audio(phrase["text"], voice, rate, pcm)
        reference = len(pcm) // (RATE * 2 // 1000)
        gap = phrase.get("pauseAfterMs", DEFAULT_GAP_MS)
        pcm.extend(bytes(gap * RATE * 2 // 1000))
        events.append({
            "cutoffMs": reference + min(gap, RECOGNITION_SLACK_MS),
            "referenceMs": reference,
            "expected": phrase["expected"],
            "kind": phrase.get("kind", "hold"),
        })
    audio = output / (clip["id"] + ".wav")
    with wave.open(str(audio), "wb") as wav:
        wav.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        wav.writeframes(pcm)
    return {
        "id": clip["id"],
        "locale": clip.get("locale", "en"),
        "start": clip["start"],
        "phase": clip.get("phase", "following"),
        "audioFile": audio.name,
        "audioSha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
        "events": events,
    }


def transcribe_whisper(trial, audio_folder, model):
    # Enforce offline execution after the public model weights have been installed.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
    import mlx_whisper
    import numpy as np

    for clip in trial["clips"]:
        with wave.open(str(audio_folder / clip["audioFile"]), "rb") as wav:
            samples = np.frombuffer(wav.readframes(wav.getnframes()), dtype=np.int16).astype(np.float32) / 32768
        for event in clip["events"]:
            prefix = samples[: event["cutoffMs"] * RATE // 1000]
            started = time.monotonic()
            result = mlx_whisper.transcribe(
                prefix,
                path_or_hf_repo=str(model.resolve(strict=True)),
                language=clip["locale"],
                temperature=0.0,
                condition_on_previous_text=False,
            )
            event["recognitionMs"] = round((time.monotonic() - started) * 1000)
            event["transcript"] = result["text"].strip()
        print(f"{clip['id']}: {len(clip['events'])} local transcript snapshots", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--local-whisper-model", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reuse-audio", action="store_true", help="read the existing manifest and WAVs")
    args = parser.parse_args()

    if args.reuse_audio:
        trial = json.loads(args.output.read_text(encoding="utf-8"))
    else:
        plan = json.loads(args.plan.read_text(encoding="utf-8"))
        args.audio.mkdir(parents=True, exist_ok=True)
        trial = {key: value for key, value in plan.items() if key != "clips"}
        trial["clips"] = [make_clip(clip, args.audio) for clip in plan["clips"]]
    if args.local_whisper_model:
        transcribe_whisper(trial, args.audio, args.local_whisper_model)
        trial["transcription"] = "Local mlx-whisper on real PCM prefixes, one snapshot per annotated boundary"
    args.output.write_text(json.dumps(trial, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
