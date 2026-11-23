# Xpresentext

English · [简体中文](README.zh-CN.md)

**A Mac teleprompter that follows your voice through a PowerPoint deck.** Leave PowerPoint running on the presentation computer and open the same PPTX on your own Mac. Your audience sees the slides. You see the sentence you’re speaking, the slide coming next, and the notes you’ll want when someone asks a question.

[Download for Apple Silicon](https://github.com/nxl801/Xpresentext/releases/download/v0.6.4/Xpresentext-0.6.4-macOS-arm64-AppleSpeech.zip) · [Release notes](https://github.com/nxl801/Xpresentext/releases/tag/v0.6.4) · [Build from source](#build-from-source)

## Take one slide for a rehearsal

1. **Drop in your deck.** Open a PPTX with English speaker notes. Pick a slide and edit a line until it sounds like something you would say. Your personal edits stay on your Mac.
2. **Read the last line aloud.** Start voice tracking and allow microphone and speech recognition access. As you reach the slide’s final sentence, the next slide moves into reading position. The previous slide and its last line remain in the lower left while you finish the thought.
3. **Try the same slide in your own words.** Switch to free speaking. Covered points fade as you speak and the remaining points stay bright. The slide stays put until you choose to advance. The full build adds local FineCat recognition for English paraphrases.

[Detailed presenter controls (简体中文)](docs/presenter-guide.zh-CN.md)

## When someone asks, “Which slide was that?”

Open live Q&A and enter the question. The answer includes slide references you can click to inspect the evidence. Checking a reference keeps your reading position. Choose **从本页讲稿继续** when you want to resume from the cited slide.

Configure DeepSeek with your API key or use a signed-in Grok CLI. Online Q&A sends the question and selected deck evidence to the configured provider.

## Choose your setup

| | AppleSpeech download | Full source build |
|---|---|---|
| Speech tracking | Apple speech recognition | Apple speech recognition or local Whisper Turbo |
| Free speaking | Original wording | Optional FineCat model for paraphrases |
| Live Q&A | Native question window | Additional Murmury overlay and meeting audio capture |
| Requirements | Apple Silicon, macOS 15+ | Apple Silicon for the optional engines, uv and Python 3.12 |

Unzip the download and open **Xpresentext.app**. The published app is locally signed and has not been notarized by Apple. The optional Whisper and FineCat models download separately (about 1.6 GB and 1.5 GB respectively).

## Build from source

On macOS 15 or later, install Xcode Command Line Tools and run these commands from the repository root. The first full build downloads its locked dependencies.

```sh
./Textream/build-local.sh
open "Textream/build/local/current/Xpresentext.app"
```

For slide rendering, use local LibreOffice or export a matching PDF from PowerPoint. To verify the build, run `Tests/verify-companion.sh` with a Python interpreter containing python-pptx, Pillow and lxml (set `DECK_PYTHON` if needed).

## License and credits

Xpresentext is released under [GPLv3](LICENSE). Its native teleprompter builds on [Textream](https://github.com/f/textream) by Fatih Kadir Akın ([MIT notice](LICENSES/Textream-MIT.txt)). The full build integrates [Murmury](https://github.com/GianlucaBave/murmury) by GianlucaBave and contributors for the Q&A overlay, audio capture and transcription ([modifications and rebuild instructions](Textream/Murmury/NOTICE.md)). See the [third-party notices](THIRD_PARTY_NOTICES.md) for redistribution, asset credits and dependency licenses.
