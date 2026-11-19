#!/usr/bin/env bash
# Builds build/Beckon.app (menu-bar app + the `beckon` hook CLI inside it), signed with "beckon Dev".
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also replace ~/Applications/Beckon.app, link ~/.local/bin/beckon, relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="beckon Dev"
# Never sign the real bundle ad-hoc: macOS records a notification-permission refusal per bundle ID,
# and that refusal sticks even after re-signing properly (seen in the signing spike).
if ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
  echo "no \"$IDENTITY\" signing identity — run scripts/make-signing-cert.sh first" >&2
  exit 1
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build/Beckon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# One version, written in Sources/BeckonCore/Paths.swift.
VERSION="$(sed -n 's/^public let beckonVersion = "\(.*\)"$/\1/p' Sources/BeckonCore/Paths.swift)"
[[ -n "$VERSION" ]] || { echo "could not read beckonVersion from Sources/BeckonCore/Paths.swift" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
cp "$BIN/BeckonApp" "$APP/Contents/MacOS/BeckonApp"
cp "$BIN/beckon" "$APP/Contents/MacOS/beckon"
# The VS Code extension rides inside the bundle, so an install that has no checkout of this repo (Homebrew)
# still has it; `beckon doctor` prints the command that installs it.
scripts/build-vscode.sh
mkdir -p "$APP/Contents/Resources"
cp vscode/beckon.vsix "$APP/Contents/Resources/beckon.vsix"
# Generated from Resources/AppIcon.svg (rsvg-convert + iconutil); committed so a build needs neither.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The MIT notice has to travel with every copy, and an installed app has no checkout beside it.
cp LICENSE "$APP/Contents/Resources/LICENSE"
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/beckon"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/Beckon.app"
  pkill -x BeckonApp || true
  # The app refuses to start while another copy runs, and SIGTERM ends it asynchronously: wait it out.
  for _ in $(seq 50); do pgrep -x BeckonApp >/dev/null || break; sleep 0.1; done
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  ln -sf "$DEST/Contents/MacOS/beckon" "$HOME/.local/bin/beckon"
  open "$DEST"
  echo "installed $DEST (CLI: ~/.local/bin/beckon)"
fi
