# Adapted from Murmury's packaging recipe. The host owns the documents and model service.
import os
from importlib.util import find_spec
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, collect_data_files, collect_dynamic_libs, copy_metadata

datas = [("upstream/LICENSE", "."), ("NOTICE.md", ".")]
binaries = [(os.environ["MURMURY_AUDIO_BINARY"], ".")]
hidden = ["tiktoken_ext.openai_public"]
# MLX initializes Metal on import. Discover the pinned modules from disk so a
# build worker can package Whisper even when it has no accessible GPU.
hidden.append("mlx.core")
for package in ("mlx", "mlx_whisper"):
    root = Path(next(iter(find_spec(package).submodule_search_locations)))
    datas += collect_data_files(package)
    binaries += collect_dynamic_libs(package)
    for source in sorted(root.rglob("*.py")):
        parts = list(source.relative_to(root).with_suffix("").parts)
        if parts[-1] == "__init__":
            parts.pop()
        hidden.append(".".join([package, *parts]))
for distribution in ("mlx", "mlx-metal", "mlx-whisper"):
    datas += copy_metadata(distribution)
for package in ("tiktoken", "tiktoken_ext"):
    data, binary, modules = collect_all(package)
    datas += data
    binaries += binary
    hidden.extend(modules)
a = Analysis(["presenter.py"], pathex=[SPECPATH], binaries=binaries, datas=datas, hiddenimports=hidden,
             excludes=["torch", "numba", "llvmlite", "scipy", "mlx_whisper.torch_whisper", "tkinter",
                       "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets", "PySide6.QtQml", "PySide6.QtQuick"])
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="MurmuryPresenter", console=True, upx=False)
coll = COLLECT(exe, a.binaries, a.datas, name="MurmuryPresenter", upx=False)
app = BUNDLE(coll, name="MurmuryPresenter.app", bundle_identifier="local.xpresentext.murmury",
             info_plist=dict(LSMinimumSystemVersion="15.0", LSUIElement=True,
                NSMicrophoneUsageDescription="用本机麦克风跟随英文讲稿。",
                NSAudioCaptureUsageDescription="在会议声音模式下收取观众提问。"))
