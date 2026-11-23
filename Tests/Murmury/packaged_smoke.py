"""Exercise both packaged modes through the same local pipe protocol as the Mac app."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("executable", type=Path)
parser.add_argument("--wav", type=Path, help="Optional 16 kHz English sample; requires prepared model")
args = parser.parse_args()
executable = args.executable.resolve(strict=True)

def start(mode, *values):
    process = subprocess.Popen([str(executable), mode, *map(str,values)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               text=True, env={**os.environ, "QT_QPA_PLATFORM": "offscreen", "HF_HUB_OFFLINE": "1"})
    events = queue.Queue()
    def read():
        for line in process.stdout:
            events.put(json.loads(line))
        events.put(None)
    threading.Thread(target=read,daemon=True).start()
    return process, events

def stop(process):
    if not process.stdin.closed:
        process.stdin.close()
    try:
        return process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise

panel, events = start("panel")
try:
    assert events.get(timeout=35) == {"action":"ready"}
    panel.stdin.write(json.dumps({"type":"state","context":"offline","title":"Pilot","status":"已回答",
                                 "question":"North?","short":"North reached 37%.","sources":[]})+"\n")
    panel.stdin.flush()
finally:
    panel_status = stop(panel)
assert panel_status == 0, panel_status
print("PASS packaged Murmury opens, displays host state and exits on pipe close")

if args.wav:
    speech, events = start("speech", "wav", "en-US", args.wav)
    final = []
    ready = False
    try:
        deadline = time.monotonic() + 120
        while True:
            event = events.get(timeout=max(0.01, deadline-time.monotonic()))
            if event is None: break
            if event["type"] == "error": raise RuntimeError(event["message"])
            if event["type"] == "ready": ready=True
            if event.get("final"): final.append(event["text"])
        assert ready and final and speech.poll() in (None, 0), final
        print("PASS packaged offline Whisper decoded WAV:", " ".join(final))
    finally:
        stop(speech)
