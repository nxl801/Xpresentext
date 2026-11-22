#!/usr/bin/env python3
"""Capture Apple callbacks through the already-authorized app without asking for permissions."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path


def launch(app, work, key, *arguments):
    output = work / f"{key}.jsonl"
    errors = work / f"{key}.stderr"
    status = work / f"{key}.status"
    status.unlink(missing_ok=True)
    output.write_text("")
    errors.write_text("")
    subprocess.run([
        "/usr/bin/open", "-g", "-n", "-W", "-a", str(app), "--stdout", str(output),
        "--stderr", str(errors), "--env", f"TEXTREAM_PROBE_STATUS={status}", "--args", *arguments
    ], check=True, timeout=75)
    return (status.read_text().strip() if status.exists() else "missing", output, errors)


def main():
    app, audio, output = [Path(value).resolve() for value in sys.argv[1:]]
    output.mkdir(parents=True, exist_ok=True)
    binary = app / "Contents/MacOS/speech-probe"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    code, lines, _ = launch(app, output, "authorized-status", "status")
    if code != "0" or "Speech authorization: 3" not in lines.read_text():
        raise SystemExit("The existing app did not report Apple Speech authorization. No permissions were requested.")
    excluded = "en-GB"
    code, _, errors = launch(app, output, "unavailable-language", "file", excluded, str(audio / "read-through-3-pages.wav"))
    if code != "2" or "does not have on-device speech recognition" not in errors.read_text():
        raise SystemExit("The preselected missing locale was not confirmed. No permissions were requested.")
    print(f"{excluded}: confirmed unavailable with the same authorized file probe", flush=True)
    clips = [
        ("read-through-3-pages", "en-US"), ("answer-then-natural-resume", "en-US"),
        ("slow-question-repeats-next-line", "en-US"), ("chinese-question-english-terms", "zh-CN"),
    ]
    report = {"signedProbeSHA256": digest, "captureScope": "Apple Speech requires on-device recognition; process networking unchanged", "clips": []}
    for key, locale in clips:
        wave = audio / f"{key}.wav"
        code, lines, _ = launch(app, output, key, "file", locale, str(wave))
        events = [json.loads(line) for line in lines.read_text().splitlines() if line.startswith("{")]
        if code != "0" or not any(event["isFinal"] for event in events):
            raise SystemExit(f"{key} did not finish through the authorized Apple probe")
        report["clips"].append({
            "id": key, "locale": locale, "events": len(events),
            "firstCallbackMs": events[0]["atMs"], "lastCallbackMs": events[-1]["atMs"],
            "wavSHA256": hashlib.sha256(wave.read_bytes()).hexdigest(),
            "traceSHA256": hashlib.sha256(lines.read_bytes()).hexdigest(),
        })
        print(f"{key}: {len(events)} callbacks", flush=True)
    if hashlib.sha256(binary.read_bytes()).hexdigest() != digest:
        raise SystemExit("The fixed speech probe changed.")
    (output / "capture.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
