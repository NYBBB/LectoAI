# Security Policy

Please do **not** report security issues in public issues.

Use GitHub's [private vulnerability reporting](../../security/advisories/new) for this repository instead. Include the affected version, steps to reproduce and the impact you expect.

Areas of particular interest:

- Handling of AI service API keys (stored in the macOS Keychain)
- Data sent to user-configured AI endpoints
- File writes into user-selected course folders (security-scoped bookmarks)
- The update path (Sparkle)

Only the latest release is supported.
