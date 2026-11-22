# Xpresentext · Textream Studio (functional preview)

A local macOS presentation workspace based on [Textream](https://github.com/f/textream). This snapshot contains the functional presentation-companion line, not the separate lunar UI experiment. The application currently displays the name **Textream Studio**.

## Features

- Import PPTX speaker notes into a page-oriented local workspace.
- Render slide previews with locally installed LibreOffice, or repair previews using a matching PDF.
- Edit and retain private speaker drafts locally; choose preview and follow-ahead ranges.
- Follow a talk using speech recognition, and capture questions using voice or typed input.
- Optional online question-answer and speech services configured by the user; keys are stored using macOS Keychain.
- Keep original Textream teleprompter features available.

## Requirements and build

macOS 15+, Apple Silicon or Intel, and Xcode Command Line Tools (`xcode-select --install`) or Xcode. The local build targets the current machine's architecture; it is not a universal binary. Install Python 3 and ensure `python3` is on PATH. LibreOffice is optional for automatic slide rendering and is not bundled.

```sh
bash Textream/build-local.sh
```

Open the application path printed by the script. The build uses an **ad-hoc signature**, not an Apple Developer ID signature or notarization. A downloaded preview may be blocked by Gatekeeper; prefer building from reviewed source. Do not disable system security protections globally.

## Deterministic tests

Use a virtual environment, with `python-pptx`, `Pillow`, and `lxml` installed:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install python-pptx Pillow lxml
DECK_PYTHON="$PWD/.venv/bin/python" bash Tests/verify-companion.sh
```

Tests generate synthetic presentations in temporary directories. No real company presentation is required or distributed. Some optional speech trials require user-granted microphone/speech permissions or explicit online-provider configuration. Deterministic tests are not proof of live recognition accuracy.

## Privacy and safe use

Presentation files and local drafts can contain sensitive material. Review the selected provider and the material sent before enabling online functions. Local storage alone does not imply every optional online feature is local. Do not commit credentials, private presentations, exported previews, app data, or logs. Provider accounts, pricing, network availability, and API compatibility are external dependencies.

## Release status

This is a functional **preview**, with runtime bundle version 0.5.0. It is not the upstream App Store release. See [release notes](RELEASE_NOTES.md) and [third-party notices](THIRD_PARTY_NOTICES.md). Test results and packaging checks are maintained separately from this source snapshot.

## License and lineage

Derived from `f/textream`; the upstream MIT license and copyright notice are preserved in [LICENSE](LICENSE). This distribution does not claim upstream endorsement. The original Textream app icon, project names and bundled assets remain attributed to the upstream project; review branding before public promotion.
