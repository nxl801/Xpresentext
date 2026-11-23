The upstream directory contains the Murmury floating window, theme, controls, audio capture and Whisper transcription from GianlucaBave/murmury, commit 2c68a030e494deba1a619b65618117927fde29a9, under GPL-3.0. The presenter adapter runs as a separate local process. Changes include host-managed questions, settings, capture lifecycle and local model loading. See upstream/LICENSE.

The Python presenter adapter, packaging recipe and modified Murmury sources in this directory are distributed under the same GPL-3.0 license. Rebuild the helper with ../build-murmury.sh on an Apple Silicon Mac. Python runtime packages are pinned in uv.lock and retain their individual licenses.

Xpresentext integration updated 2026-11-22. The presenter window identifies the host, and the packaging recipe discovers MLX modules without requiring a GPU at build time.

Since Xpresentext 0.6.1 the helper also runs English point coverage in a separate process. Checkpoint provenance and verification are documented in english_coverage/NOTICE.md.
