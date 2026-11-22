#!/usr/bin/env python3
"""Build the test harness and publish immutable, signed live runners."""

import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SOURCE = REPO / "Textream/Textream"
QA_TESTS = REPO / "Tests/CompanionQA"
CACHE = REPO / "build/verification/voice-qa-runners"
NAME = "Textream QA Check"
SIGN_ID = "local.xpresentext.qa-check"
FLAGS = ["-O", "-swift-version", "6", "-D", "COMPANION_QA_EXTERNAL_MAIN", "-module-name", "TextreamQACheck"]


def swift_sources():
    return sorted([
        *(SOURCE / "Companion/QA").glob("*.swift"),
        *(SOURCE / "Companion/Tracking").glob("*.swift"),
        SOURCE / "SpeechTextAlignment.swift",
        SOURCE / "VoiceActivityDetector.swift",
        SOURCE / "Companion/Workspace/StudioCredentials.swift",
        *QA_TESTS.glob("*.swift"),
        HERE.parent / "LiveTrialProvider.swift",
        HERE / "VoiceQABenchmark.swift",
    ])


def captured_inputs(directory: Path, definition: bytes):
    names = ["inputs.json"]
    for case in json.loads(definition):
        names += [case["id"] + ".wav", case["id"] + ".jsonl"]
    return {name: (directory / name).read_bytes() for name in names}


def inputs_for_build():
    files = {str(path.relative_to(REPO)): path.read_bytes() for path in swift_sources()}
    samples = (HERE / "cases.json").read_bytes()
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    return files, samples, sdk


def version_for(files, samples, sdk, inputs):
    configuration = {
        "format": 1,
        "flags": FLAGS + ["-sdk", sdk],
        "compiler": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True, stderr=subprocess.STDOUT).strip(),
        "sdkBuild": subprocess.check_output(["xcrun", "--show-sdk-build-version"], text=True).strip(),
        "arch": platform.machine(),
        "signingIdentifier": SIGN_ID,
        "name": NAME,
    }
    entries = {
        "configuration": json.dumps(configuration, sort_keys=True).encode(),
        "cases.json": samples,
        **{f"source/{name}": content for name, content in files.items()},
        **{f"sample/{name}": content for name, content in inputs.items()},
    }
    digest = hashlib.sha256()
    for name, content in sorted(entries.items()):
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(content).digest())
    return digest.hexdigest()


def build(work, publish, name, files, samples, sdk, sign=False):
    sources = work / "sources"
    for relative, contents in files.items():
        destination = sources / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(contents)
    publish.mkdir()
    (publish / "cases.json").write_bytes(samples)
    binary = publish / name
    subprocess.run([
        "xcrun", "swiftc", *FLAGS, "-sdk", sdk,
        *(str(sources / relative) for relative in files), "-o", str(binary)
    ], check=True, stdout=sys.stderr)
    if sign:
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", SIGN_ID, str(binary)],
                       check=True, stdout=sys.stderr)
        verify_signature(binary)
    return binary


def verify_signature(binary):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True, stdout=sys.stderr)


def cached_live_runner(input_dir, files, samples, sdk):
    digest = version_for(files, samples, sdk, captured_inputs(input_dir, samples))
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / digest
    if not target.exists():
        with tempfile.TemporaryDirectory(prefix=".stage-", dir=CACHE) as stage:
            work = Path(stage)
            publish = work / "ready"
            build(work, publish, NAME, files, samples, sdk, sign=True)
            try:
                # A published target is a nonempty directory. Concurrent builds
                # may lose the race, but rename never replaces that directory.
                publish.rename(target)
            except OSError as error:
                if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not target.is_dir():
                    raise

    binary = target / NAME
    if (target / "cases.json").read_bytes() != samples:
        raise RuntimeError("Saved verification fixtures do not match this version.")
    verify_signature(binary)
    return binary


def main():
    args = sys.argv[1:]
    mode = args[0] if args else ""
    if mode in ("live", "build-live") and len(args) < 2:
        print("A verification input directory is required.", file=sys.stderr)
        return 2
    if mode == "build-live" and len(args) != 2:
        print("Usage: run.sh build-live INPUT_DIR", file=sys.stderr)
        return 2
    files, samples, sdk = inputs_for_build()
    if mode in ("live", "build-live"):
        binary = cached_live_runner(Path(args[1]).resolve(strict=True), files, samples, sdk)
        if mode == "build-live":
            print(binary)
            return 0
        os.execv(binary, [str(binary), *args])

    with tempfile.TemporaryDirectory(prefix="textream-qa-check-") as stage:
        work = Path(stage)
        binary = build(work, work / "runner", "voice-qa", files, samples, sdk)
        return subprocess.run([str(binary), *args]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
