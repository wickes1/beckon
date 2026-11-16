#!/usr/bin/env bash
# Everything from a fresh clone: signing identity, app + CLI, Claude Code hooks, VS Code extension, then doctor.
#   scripts/install.sh
# Safe to run again after a `git pull`. Sessions already running keep their old hooks until restarted.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
scripts/make-signing-cert.sh
scripts/build-app.sh --install
scripts/hooks.sh install
if command -v code >/dev/null; then
  scripts/build-vscode.sh --install
else
  echo "VS Code's 'code' command not found: skipping the extension (clicks will only bring VS Code forward)"
fi

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: ~/.local/bin is not on your PATH; the CLI is at ~/.local/bin/beckon" ;; esac
sleep 1  # let the app open its socket
"$HOME/Applications/Beckon.app/Contents/MacOS/beckon" doctor
