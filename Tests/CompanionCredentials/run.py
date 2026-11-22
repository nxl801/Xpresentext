#!/usr/bin/env python3
"""Exercise fresh macOS Keychain and preference namespaces with outbound IP denied."""
from pathlib import Path
import os
import select
import shutil
import subprocess
import tempfile
import uuid

here = Path(__file__).resolve().parent
product = here.parents[1] / "Textream/Textream/Companion"
run_id = uuid.uuid4().hex
namespace = f"local.xpresentext.keychain-acceptance.{run_id}."
preferences = f"local.xpresentext.keychain-preferences-acceptance.{run_id}"
environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR") if key in os.environ}
policy = '(version 1) (allow default) (deny network-outbound (remote ip "*:*"))'

with tempfile.TemporaryDirectory(prefix="textream-credential-check-") as directory:
    work = Path(directory)
    copied = work / "StudioCredentials.swift"
    source = (product / "Workspace/StudioCredentials.swift").read_text()
    isolated = {
        '"local.xpresentext.companion."': f'"{namespace}"',
        '"local.xpresentext.companion"': f'"{preferences}"',
    }
    for original, replacement in isolated.items():
        if source.count(original) != 1:
            raise RuntimeError("Could not isolate the service and preference domain; stopped before using Keychain")
        source = source.replace(original, replacement)
    copied.write_text(source)
    first, second = work / "release-one", work / "release-two"
    first.mkdir()
    second.mkdir()
    executable = "TextreamKeychainCheck"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", *sorted((product / "QA").glob("*.swift")),
                    copied, here / "KeychainCheck.swift", "-o", first / executable], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", first / executable], check=True)
    shutil.copy2(first / executable, second / executable)
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier",
                    "local.xpresentext.acceptance.next", second / executable], check=True)
    current = work / "current"
    current.symlink_to(first)

    def command(release, mode):
        return ["/usr/bin/sandbox-exec", "-p", policy, release / executable, mode, namespace, preferences]

    def verify(mode, release=first, setup=None):
        subprocess.run(command(release, mode), check=True, timeout=20, env={**environment, **(setup or {})})

    try:
        with subprocess.Popen(command(current, "running"), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              text=True, env=environment) as running:
            try:
                if not select.select([running.stdout], [], [], 10)[0] or running.stdout.readline().strip() != "ready":
                    raise RuntimeError("Could not start isolated credential writer")
                new = work / "new"
                new.symlink_to(second)
                os.replace(new, current)
                running.communicate(input="publish\n", timeout=15)
                if running.returncode:
                    raise RuntimeError("The older release could not save or update its isolated item")
            finally:
                if running.poll() is None:
                    running.kill()
        verify("reopen")
        verify("status", current)
        print("PASS unmarked standard entry remains available across the release link switch", flush=True)
        verify("mark")
        verify("missing-marked", setup={"BIGMODEL_API_KEY": "disposable-legacy-env"})
        verify("explicit-standard-environment", setup={
            "BIGMODEL_API_KEY": "disposable-legacy-env",
            "BIGMODEL_STANDARD_API_KEY": "disposable-explicit-standard-env",
            "DEEPSEEK_API_KEY": "disposable-deepseek-env",
        })
        verify("save-marked-standard", setup={"BIGMODEL_API_KEY": "disposable-legacy-env"})
        verify("reopen-marked", current)
        verify("grok-cli")
    finally:
        verify("cleanup")
