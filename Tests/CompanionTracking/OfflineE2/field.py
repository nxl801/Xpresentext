#!/usr/bin/env python3
"""Prepare or run the acoustic, whole-Mac offline acceptance trial."""

import argparse
import errno
import hashlib
import json
import os
import platform
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
APP_NAME = "Textream Field Check"
FLAGS = ["-parse-as-library", "-swift-version", "5", "-enable-bare-slash-regex",
         "-whole-module-optimization", "-D", "COMPANION_ACCEPTANCE", "-D", "LOCAL_COMPANION"]


def build_app():
    source_root = REPO / "Textream" / "Textream"
    files = sorted(source_root.rglob("*.swift")) + [HERE / name for name in (
        "FieldConditions.swift", "FieldRecognitionTrace.swift", "FieldTrial.swift")]
    sources = [(path.relative_to(REPO), path.read_bytes()) for path in files]
    compiler = subprocess.check_output(["xcrun", "swiftc", "--version"])
    sdk = subprocess.check_output(["xcrun", "--show-sdk-build-version"])
    digest = hashlib.sha256(Path(__file__).read_bytes() + compiler + sdk + platform.machine().encode())
    for path, contents in sources:
        digest.update(str(path).encode() + b"\0" + hashlib.sha256(contents).digest())

    cache = REPO / "build" / "verification" / "field-runners"
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / digest.hexdigest()
    if not target.exists():
        with tempfile.TemporaryDirectory(prefix=".stage-", dir=cache) as staging:
            stage = Path(staging)
            publish = stage / "publish"
            app = publish / (APP_NAME + ".app")
            binary = app / "Contents" / "MacOS" / "field-check"
            binary.parent.mkdir(parents=True)
            paths = []
            for relative, contents in sources:
                local = stage / "sources" / relative
                local.parent.mkdir(parents=True, exist_ok=True)
                local.write_bytes(contents)
                paths.append(str(local))
            info = dict(CFBundleIdentifier="local.xpresentext.field-check", CFBundleName=APP_NAME,
                        CFBundleDisplayName=APP_NAME, CFBundleExecutable=binary.name,
                        CFBundlePackageType="APPL", CFBundleVersion="1", LSUIElement=True,
                        NSMicrophoneUsageDescription="现场验收时通过麦克风听取扬声器播放的测试录音。",
                        NSSpeechRecognitionUsageDescription="在这台 Mac 上识别现场验收的测试语音。")
            (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
            subprocess.run(["xcrun", "swiftc", *FLAGS, *paths, "-o", str(binary)], check=True)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
            try:
                publish.rename(target)
            except OSError as error:
                if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not target.is_dir():
                    raise
    app = target / (APP_NAME + ".app")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    return app


def stage_presentation(pptx, output):
    """Keep the confirmed copy available offline without later access to Downloads."""
    digest = hashlib.sha256(pptx.read_bytes()).hexdigest()
    folder = output / "inputs" / digest
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = folder / pptx.name
    if not target.exists():
        with tempfile.NamedTemporaryFile(dir=folder, delete=False) as staged, pptx.open("rb") as source:
            shutil.copyfileobj(source, staged)
        staging = Path(staged.name)
        try:
            if hashlib.sha256(staging.read_bytes()).hexdigest() != digest:
                raise ValueError("复制期间 PPT 内容发生变化，请重新运行准备检查。")
            staging.replace(target)
        finally:
            staging.unlink(missing_ok=True)
    if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
        raise ValueError("准备好的 PPT 与源文件不一致。")
    return target


def write_launcher(app, mode, pptx, corpus, audio, output):
    launcher = output / ("复测英文跟读.command" if mode == "follow" else "开始断网麦克风验收.command")
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), mode,
                          str(pptx), str(corpus), str(audio), str(output), "--prepared-app", str(app)])
    with tempfile.NamedTemporaryFile(dir=output, mode="w", delete=False) as staged:
        staged.write("#!/bin/zsh\nexec " + command + "\n")
    os.chmod(staged.name, 0o700)
    os.replace(staged.name, launcher)
    return launcher


def run_bundle(app, mode, pptx, corpus, audio, run):
    log, errors = run / "stdout.log", run / "stderr.log"
    log.touch()
    errors.touch()

    def cancel(signum, frame):
        (run / "abort").write_text("已取消现场验收。")

    previous = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)}
    try:
        command = ["/usr/bin/open", "-g", "-n", "-W", "-a", str(app),
                   "--stdout", str(log), "--stderr", str(errors), "--args", "--" + mode,
                   str(pptx), str(corpus), str(audio), str(run)]
        scenes = {"read-through-3-pages": "英文跨页跟读", "answer-then-natural-resume": "问答后自然接回",
                  "slow-question-repeats-next-line": "英文复述问题", "chinese-question-english-terms": "中英混合复述问题"}
        if mode == "prepare":
            scenes.clear()
        with subprocess.Popen(command, start_new_session=True) as process:
            while process.poll() is None:
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
                for scene, title in list(scenes.items()):
                    evidence = run / (scene + ".json")
                    if evidence.exists():
                        result = json.loads(evidence.read_bytes())
                        print(title + ("已通过" if result["passed"] else "已记录，需要复核"), flush=True)
                        del scenes[scene]
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, command)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        if mode != "prepare":
            print("本次现场测试已结束，可以恢复网络。", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "field", "follow"))
    parser.add_argument("pptx", type=Path)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("audio", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--prepared-app", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    pptx, corpus, audio = [p.resolve(strict=True) for p in (args.pptx, args.corpus, args.audio)]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.prepared_app is None:
        app = build_app()
    else:
        app = args.prepared_app.resolve(strict=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    if args.mode == "prepare":
        pptx = stage_presentation(pptx, output)
    run = Path(tempfile.mkdtemp(prefix=args.mode + "-", dir=output))
    print(f"本次结果保存在 {run}", flush=True)
    if args.mode == "field":
        print("本机将播放四段样音。请保持扬声器可外放，完成提示出现后即可恢复网络。", flush=True)
    elif args.mode == "follow":
        print("本次只播放约 39 秒的英文连续跟读录音。请保持扬声器可外放。", flush=True)
    run_bundle(app, args.mode, pptx, corpus, audio, run)
    marker = run / "status"
    if not marker.is_file():
        print(f"程序未正常结束。现有记录保留在 {run}。", file=sys.stderr)
        return 1
    status = int(marker.read_text().strip())
    if status != 0:
        details = (run / "abort").read_text().strip() if (run / "abort").is_file() else (run / "stderr.log").read_text().strip()
        print(details or "测试有未完成或未通过的项目。", file=sys.stderr)
        return status
    if args.mode == "prepare":
        for mode in ("field", "follow"):
            print(write_launcher(app, mode, pptx, corpus, audio, output))
    else:
        print("逐项结果已保存在本机。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
