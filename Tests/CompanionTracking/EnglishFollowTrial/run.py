#!/usr/bin/env python3
"""Prepare self-authored test WAVs, collect local Apple callbacks, or compare saved callbacks."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import wave


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2] / "Textream" / "Textream"
CASES = SOURCE / "EnglishFollowSamples" / "cases.json"


def examples():
    return json.loads(CASES.read_text())["cases"]


def prepare(output):
    output.mkdir(parents=True, exist_ok=True)
    manifest = {}
    with tempfile.TemporaryDirectory(prefix="textream-follow-audio-") as temporary:
        for example in examples():
            name = example["id"]
            intermediate = Path(temporary) / (name + ".aiff")
            wav = output / (name + ".wav")
            subprocess.run(["/usr/bin/say", "-v", "Samantha", "-r", "150", "-o", str(intermediate),
                            example["transcript"]], check=True)
            subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                            str(intermediate), str(wav)], check=True)
            with wave.open(str(wav), "rb") as audio:
                assert audio.getnchannels() == 1 and audio.getframerate() == 16000 and audio.getsampwidth() == 2
                manifest[name] = {
                    "sha256": hashlib.sha256(wav.read_bytes()).hexdigest(),
                    "durationMs": round(audio.getnframes() / 16),
                }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def collect_apple(audio, output, probe):
    output.mkdir(parents=True, exist_ok=True)
    for example in examples():
        name = example["id"]
        wav = (audio / (name + ".wav")).resolve(strict=True)
        stdout = output / (name + ".jsonl")
        stderr = output / (name + ".stderr")
        marker = output / (name + ".status")
        stdout.write_text("")
        stderr.write_text("")
        marker.unlink(missing_ok=True)
        # The specified probe must already be authorized. File mode has no
        # permission request, microphone capture, speaker playback or cloud path.
        subprocess.run(["/usr/bin/open", "-g", "-n", "-W", "-a", str(probe), "--stdout", str(stdout),
                        "--stderr", str(stderr), "--env", f"TEXTREAM_PROBE_STATUS={marker}",
                        "--args", "file", "en-US", str(wav)], check=True, timeout=40)
        if not marker.exists() or marker.read_text().strip() != "0":
            raise SystemExit(f"Apple replay failed for {name}. See {stderr}.")


def compare(include_text, streams):
    if not include_text and not streams:
        raise SystemExit("Specify --text or at least one --trace LABEL DIRECTORY.")
    inputs = ["reference-text", "-"] if include_text else []
    for label, directory in streams:
        inputs.extend([label, str(Path(directory).resolve(strict=True))])
    with tempfile.TemporaryDirectory(prefix="textream-follow-compare-") as temporary:
        program = Path(temporary) / "follow-compare"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-O",
                        str(SOURCE / "SpeechTextAlignment.swift"),
                        str(SOURCE / "Companion/Tracking/CompanionTrackingMatcher.swift"),
                        str(HERE / "Replay.swift"), "-o", str(program)], check=True)
        subprocess.run([str(program), str(CASES), *inputs], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    phases = parser.add_subparsers(required=True, dest="phase")
    sample = phases.add_parser("prepare")
    sample.add_argument("output", type=Path)
    apple = phases.add_parser("apple")
    apple.add_argument("audio", type=Path)
    apple.add_argument("output", type=Path)
    apple.add_argument("probe", type=Path, help="existing authorized Textream Speech Probe.app")
    comparison = phases.add_parser("compare")
    comparison.add_argument("--text", action="store_true", help="add the accurate fixture text without ASR timing")
    comparison.add_argument("--trace", nargs=2, action="append", default=[], metavar=("LABEL", "DIRECTORY"),
                            help="one .jsonl per case with atMs, transcript, and isFinal; label states provenance")
    args = parser.parse_args()
    if args.phase == "prepare":
        prepare(args.output.resolve())
    elif args.phase == "apple":
        collect_apple(args.audio, args.output.resolve(), args.probe.resolve(strict=True))
    else:
        compare(args.text, args.trace)


if __name__ == "__main__":
    main()
