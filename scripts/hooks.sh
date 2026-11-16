#!/usr/bin/env bash
# Wires beckon into Claude Code hooks.
#   scripts/hooks.sh print [settings-file]   print a settings file containing only beckon's hooks (for `claude --settings`)
#   scripts/hooks.sh install                 merge into ~/.claude/settings.json (backup first)
#   scripts/hooks.sh uninstall               remove beckon's entries from ~/.claude/settings.json (backup first)
# Merging keeps every other hook and setting; beckon's own entries are recognised by the CLI path.
# Besides the hooks it sets env.CLAUDE_CLIENT_PRESENCE_FILE, so Claude Code skips phone pushes while the screen
# is unlocked (beckon keeps that file there exactly then).
set -euo pipefail

CLI="$HOME/Applications/Beckon.app/Contents/MacOS/beckon"
SETTINGS="$HOME/.claude/settings.json"
PRESENCE="$HOME/Library/Application Support/beckon/present"

# Exec form (command + args): no shell between Claude Code and the CLI.
# PermissionRequest waits for the user, so it gets an hour; the terminal dialog stays usable the whole time.
# Stop is asyncRewake: it returns at once as far as the turn is concerned and stays in the background for an
# hour, listening for a reply typed on the Done card (exit 2 wakes the idle session with it). `--rewake` is what
# makes the CLI wait, so the two always travel together.
# Keep this list in step with plugin/hooks/hooks.json.
hooks_json() {
  jq -n --arg cli "$CLI" '
    def h($event; $timeout): {hooks: [{type: "command", command: $cli, args: ["hook", $event], timeout: $timeout}]};
    def m($event; $timeout): {matcher: "*"} + h($event; $timeout);
    {
      PermissionRequest:  [m("PermissionRequest"; 3600)],
      PostToolUse:        [m("PostToolUse"; 5)],
      PostToolUseFailure: [m("PostToolUseFailure"; 5)],
      UserPromptSubmit:   [h("UserPromptSubmit"; 5)],
      Stop:               [{hooks: [{type: "command", command: $cli, args: ["hook", "Stop", "--rewake"], timeout: 3600, asyncRewake: true}]}],
      StopFailure:        [h("StopFailure"; 5)],
      SubagentStop:       [h("SubagentStop"; 5)],
      SessionEnd:         [h("SessionEnd"; 5)]
    }'
}

strip_ours() {
  jq --arg cli "$CLI" '
    if .hooks then
      .hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command != $cli))) | map(select(.hooks | length > 0))))
                 | with_entries(select(.value | length > 0)))
    else . end'
}

backup() {
  local b="$SETTINGS.beckon-backup-$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS" "$b"
  echo "backup: $b"
}

case "${1:-}" in
  print)
    out="${2:-/dev/stdout}"
    jq -n --argjson h "$(hooks_json)" --arg p "$PRESENCE" '{env: {CLAUDE_CLIENT_PRESENCE_FILE: $p}, hooks: $h}' > "$out"
    ;;
  install)
    [[ -x "$CLI" ]] || { echo "missing $CLI — run scripts/build-app.sh --install first" >&2; exit 1; }
    backup
    tmp="$(mktemp)"
    strip_ours < "$SETTINGS" | jq --argjson h "$(hooks_json)" --arg p "$PRESENCE" '
      .hooks = ((.hooks // {}) as $old | reduce ($h | keys[]) as $k ($old; .[$k] = ((.[$k] // []) + $h[$k])))
      | .env.CLAUDE_CLIENT_PRESENCE_FILE = $p' > "$tmp"
    jq -e . "$tmp" >/dev/null
    mv "$tmp" "$SETTINGS"
    echo "installed beckon hooks into $SETTINGS"
    ;;
  uninstall)
    backup
    tmp="$(mktemp)"
    strip_ours < "$SETTINGS" | jq --arg p "$PRESENCE" 'if .env.CLAUDE_CLIENT_PRESENCE_FILE == $p then del(.env.CLAUDE_CLIENT_PRESENCE_FILE) else . end' > "$tmp"
    jq -e . "$tmp" >/dev/null
    mv "$tmp" "$SETTINGS"
    echo "removed beckon hooks from $SETTINGS"
    ;;
  *)
    sed -n '2,8p' "$0"; exit 2 ;;
esac
