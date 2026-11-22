#!/usr/bin/env python3
"""Launch the production-workspace replay with networking denied in that process only."""

import argparse
import json
import os
import shutil
import subprocess
import tempfile
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

PROFILE = "(version 1)(allow default)(deny network*)"


class Sentinel(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pptx", type=Path)
    parser.add_argument("annotation_json", type=Path)
    parser.add_argument("audio_dir", type=Path)
    parser.add_argument("apple_dir", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    project = directory.parents[2]
    args.output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="textream-offline-e2-") as temporary, HTTPServer(("127.0.0.1", 0), Sentinel) as sentinel:
        scratch = Path(temporary)
        port = sentinel.server_port
        thread = threading.Thread(target=sentinel.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{port}/health"
            client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with client.open(url, timeout=2) as response:
                assert response.status == 204
            (args.output / "network-control.json").write_text(json.dumps({
                "unrestrictedLoopbackHTTP": 204, "profile": PROFILE,
                "scope": "the replay executable and inherited processes; whole-Mac network unchanged",
            }, indent=2) + "\n")

            sources = scratch / "sources"
            shutil.copytree(project / "Textream" / "Textream", sources)
            executable = scratch / "offline-workspace"
            subprocess.run([
                "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-enable-bare-slash-regex",
                "-whole-module-optimization", "-D", "COMPANION_ACCEPTANCE", "-D", "LOCAL_COMPANION",
                *[str(path) for path in sorted(sources.rglob("*.swift"))],
                str(directory / "OfflineWorkspace.swift"), "-o", str(executable),
            ], check=True)
            traces = args.apple_dir.resolve(strict=True)
            with (args.output / "workbench.json").open("wb") as output, (args.output / "workbench.stderr").open("wb") as errors:
                subprocess.run([
                    "/usr/bin/sandbox-exec", "-p", PROFILE, str(executable), str(args.pptx.resolve(strict=True)),
                    str(args.annotation_json.resolve(strict=True)), str(args.audio_dir.resolve(strict=True)),
                    str(traces), str(scratch / "workspace"), str(port),
                ], check=True, timeout=200, stdout=output, stderr=errors, env=os.environ.copy())
        finally:
            sentinel.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
