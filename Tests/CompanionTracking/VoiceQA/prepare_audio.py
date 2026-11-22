#!/usr/bin/env python3
"""Synthesize only shared test questions and capture Apple Speech callback timestamps."""

import argparse
import hashlib
import json
import subprocess
import tempfile
import wave
from pathlib import Path

RATE = 16_000
TAIL_MS = 2_900


def synthesize(question: str, recording: Path):
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        script = work / "question.txt"
        aiff = work / "question.aiff"
        script.write_text(question, encoding="utf-8")
        subprocess.run(["say", "-v", "Samantha", "-r", "150", "-f", str(script), "-o", str(aiff)], check=True)
        audio = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(aiff), "-ar", str(RATE), "-ac", "1", "-f", "s16le", "-"],
            capture_output=True,
            check=True,
        )
    with wave.open(str(recording), "wb") as wav:
        wav.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        wav.writeframes(audio.stdout + bytes(TAIL_MS * RATE * 2 // 1000))
    return {
        "speechDurationMsIncludingTTSTail": len(audio.stdout) // (RATE * 2 // 1000),
        "addedSilenceMs": TAIL_MS,
        "wavSHA256": hashlib.sha256(recording.read_bytes()).hexdigest(),
    }


def capture(clip_id: str, app: Path, output: Path, wav: Path):
    transcript = output / f"{clip_id}.jsonl"
    stderr = output / f"{clip_id}.stderr"
    status = output / f"{clip_id}.status"
    status.unlink(missing_ok=True)
    transcript.write_text("")
    stderr.write_text("")
    subprocess.run([
        "/usr/bin/open", "-n", "-W", "-a", str(app), "--stdout", str(transcript), "--stderr", str(stderr),
        "--env", f"TEXTREAM_PROBE_STATUS={status}", "--args", "file", "en-US", str(wav)
    ], check=True, timeout=40)
    code = status.read_text().strip() if status.exists() else "missing"
    if code != "0":
        raise SystemExit(f"Apple Speech returned {code} for {clip_id}. Check the local stderr file.")
    events = [
        json.loads(line) for line in transcript.read_text(encoding="utf-8").splitlines()
        if line.startswith("{")
    ]
    nonempty = [event for event in events if event["transcript"].strip()]
    if not nonempty or not any(event["isFinal"] for event in events):
        raise SystemExit(f"Apple Speech did not return a usable callback trace for {clip_id}.")
    return (len(events), events[-1]["atMs"], nonempty[-1]["transcript"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("probe_app", type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    app = args.probe_app.resolve(strict=True)
    binary = app / "Contents/MacOS/speech-probe"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    output.mkdir(parents=True, exist_ok=True)
    cases = json.loads(Path(__file__).with_name("cases.json").read_text(encoding="utf-8"))
    for case in cases:
        clip_id = case["id"]
        wave_path = output / f"{clip_id}.wav"
        case.update(synthesize(case["question"], wave_path))
        count, final_ms, last_nonempty = capture(clip_id, app, output, wave_path)
        case["callbacks"] = count
        case["fileFinalCallbackMs"] = final_ms
        case["lastNonemptyTranscript"] = last_nonempty
        case["callbackSHA256"] = hashlib.sha256((output / f"{clip_id}.jsonl").read_bytes()).hexdigest()
        print(f"{clip_id}: Apple Speech {count} callbacks, file final {final_ms} ms", flush=True)
    if hashlib.sha256(binary.read_bytes()).hexdigest() != binary_hash:
        raise SystemExit("The fixed Apple Speech probe changed during the test.")
    manifest = {"language": "en-US", "probeSHA256": binary_hash, "audioTextToSpeech": "Samantha, 150 wpm", "cases": cases}
    (output / "inputs.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
