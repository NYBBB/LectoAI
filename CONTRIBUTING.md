# Contributing to LectoAI

Thanks for your interest! LectoAI is an early-stage project maintained in spare time, so please open an issue to discuss larger changes before writing code.

## Setup

See [README.md](README.md#build-and-run). You need an Apple Silicon Mac on macOS 26+, Xcode 27 and XcodeGen.

## Guidelines

- `project.yml` is the source of truth for the Xcode project. Run `./Scripts/bootstrap.sh` after changing it, and never commit the generated `LectoAI.xcodeproj`.
- Put business logic in the `LectoAICore` package, with unit tests. The app target should only contain UI and system integration.
- The code uses Swift 6 strict concurrency. Never do I/O or wait on the network or models inside real-time audio callbacks.
- Code comments are written in Chinese. English comments in contributions are fine.
- Never commit recordings, transcripts from real classes, model weights, API keys or signing material.
- New dependencies must have a GPL-3.0-compatible license and be added to `LectoAI/Resources/ThirdPartyNotices.txt`.

## Before opening a pull request

```bash
swift test --package-path LectoAICore
xcodebuild -project LectoAI.xcodeproj -scheme LectoAI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build test
```

If you touch the UI, run the `LectoAI-UI` scheme as well, but not while LectoAI is recording, because the tests terminate the app. Mention anything you could only check by hand, such as permission prompts, the floating panel over full-screen apps, or a real lecture.

## License

By contributing, you agree that your contributions are licensed under the [GPL-3.0](LICENSE).
