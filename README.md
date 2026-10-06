# LectoAI

English | [简体中文](README.zh-CN.md)

A native macOS app for Chinese-speaking students taking classes taught in English. During class it shows live English captions with Chinese translation. You can mark the moment you got lost, see what the lecture is about right now, or ask a quick question. After class it hands the transcript, translation, notes and summaries to a course folder you own, ready for review with your own study tools (Claude, Codex, or plain Markdown).

- **On-device recognition and translation.** Apple SpeechAnalyzer and Apple Translation are used by default. An offline WhisperKit model can be downloaded when system recognition is unavailable. Audio never leaves your Mac.
- **Optional AI assistant, bring your own key.** Connect any OpenAI-compatible Chat Completions endpoint to get live lecture notes, a running summary, polished paragraph translations and Q&A. Only bounded transcript text is sent. Keys live in the Keychain.
- **Course folders without setup.** Pick a folder the first time a class ends and a course is created. Later lessons are matched to courses by their meeting times and handed off automatically. Files you have edited are never overwritten.

> **Status:** 0.5.0, early preview. **The user interface is currently Chinese only.** It has not yet been validated across full real-world lectures, and there is no signed or notarized release yet.

## Requirements

- Apple Silicon (arm64)
- macOS 26 or later
- To build: Xcode 27 (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44+

## Build and run

```bash
brew install xcodegen
./Scripts/bootstrap.sh          # generates LectoAI.xcodeproj from project.yml and restores pinned dependencies
swift test --package-path LectoAICore
xcodebuild -project LectoAI.xcodeproj -scheme LectoAI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/LectoAI.app
```

Debug builds are ad-hoc signed, so no Apple Developer account is required. `./Scripts/package.sh` produces a local test DMG.

The UI tests (`LectoAI-UI` scheme) launch and terminate processes with the app's bundle id. **Do not run them while you are recording a class with LectoAI.** Doing so will end the recording.

## Repository layout

| Path | Contents |
|---|---|
| `LectoAI/` | The app: `Runtime/` (audio capture, speech pipeline, app model, course handoff), `UI/` (SwiftUI views), `Diagnostics/` |
| `LectoAICore/` | Swift package: lesson data and append-only event log, sentence and paragraph segmentation, prompts for translation and notes, course and handoff logic, plus unit tests |
| `LectoAIBench/` | Command-line benchmark (Apple file recognition, WhisperKit chunking simulation) |
| `LectoAIUITests/` | UI tests, run against isolated demo data (`--demo*` launch arguments) |
| `Config/`, `Scripts/` | Build settings, pinned `Package.resolved`, bootstrap, packaging and signature verification scripts |
| `docs/` | Selected design documents (Chinese) |

`project.yml` is the single source of truth for the Xcode project. Do not edit `.pbxproj` directly.

## Privacy

- Recordings, transcripts and notes stay on your Mac. There is no account, analytics or telemetry.
- Transcript text is sent only to an AI service **you configure**, and only for the features you turn on. Audio is never sent.
- Apple may download language resources the first time recognition or translation is used. The optional offline speech model is downloaded from Hugging Face and verified against pinned revisions and checksums.

## A note on recording

Before recording a class, check your school's, course's and instructor's policies on recording, and ask for permission where required. Keep recordings and transcripts for your own study.

## Known limitations

- Not yet validated across full 75-minute lectures or edge cases such as closing the lid, unplugging devices or running out of disk space. The offline fallback model needs more real-world testing.
- UI strings are not yet localized into English.
- Imported audio is processed at 1× speed.
- No signed or notarized release and no update feed yet. Sparkle is integrated; see `Config/Update.example.xcconfig`.

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first. To report a security issue, see [SECURITY.md](SECURITY.md).

## License

LectoAI is licensed under the [GNU General Public License v3.0](LICENSE). Third-party components (WhisperKit, Sparkle, swift-argument-parser and others) are listed with their licenses in [`ThirdPartyNotices.txt`](LectoAI/Resources/ThirdPartyNotices.txt) and [`Sparkle-LICENSE.txt`](LectoAI/Resources/Sparkle-LICENSE.txt).
