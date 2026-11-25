# Contributing

Thank you for helping improve Brightery Clipboard. Open an issue for substantial changes, then fork the repository and submit a focused pull request. Keep the app native, dependency-free where practical, local-first, and accessible.

## Validation

Run `./test.sh` and `./build.sh` on macOS 13 or later with a current Xcode SDK. Verify both architectures with `lipo -archs 'build/Brightery Clipboard.app/Contents/MacOS/Brightery Clipboard'`. Run `./package-dmg.sh` if changing distribution.

Manual checks: copy two clips in TextEdit; invoke ⌘⇧V; single-click to paste; edit with both keep-original and update-history choices; confirm timestamps, search, pagination, deletion, pause, retention, and login settings. Test missing Accessibility access and destination switching. Test macOS 13 and later where possible. Use synthetic text rather than real clipboard secrets in reports.

## Pull requests

Describe the change, tests actually run, macOS/SDK versions and any limitations. Avoid unrelated formatting and binary artifacts. Contributions are under the MIT license.
