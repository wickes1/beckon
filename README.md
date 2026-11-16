<p align="center"><img src="docs/images/hero.png" alt="beckon. Claude Code is waiting: answer without switching windows. The panel sits at the top right of the screen with an approval card for a database migration, and a plan review, two questions and a finished task waiting below it"></p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#what-appears-on-the-panel">Cards</a> ·
  <a href="#what-works-where">Supported apps</a> ·
  <a href="#commands">Commands</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="license: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
</p>

A floating panel for Claude Code on macOS. When Claude Code needs you, answer on the card, or click it to land on the exact terminal or browser tab where Claude is waiting.

## Features

- **Answer on the card.** Approve a tool call (or add a "don't ask again" rule), answer AskUserQuestion, approve or revise a plan, reply to a finished turn. The terminal dialog stays live; whichever you answer first wins.
- **Land on the exact place.** Click a card to reach the VS Code window and terminal, the Ghostty tab or the Terminal.app tab where Claude is waiting, even when it is buried under other windows.
- **Get sent where you're needed.** A skill runs `beckon notify` to point you at a Brave tab or any URL — a web page, or an app via `file:///Applications/….app` — and `beckon dismiss` once it sees you're done.
- **Stays out of your way.** The panel never takes the keyboard unless you click a field, shows nothing for the session you're already looking at, and lets phone pushes through only while the screen is locked.
- **Safe by default.** Decisions go through Claude Code's own permission system; beckon has no allow rules of its own. If the app isn't running, every hook exits at once and Claude Code behaves as if beckon weren't installed.
- **Light.** The hook adds 2.8 ms at p90 (measured), with no runtime dependencies.

<p align="center"><img src="docs/images/demo.webp" width="880" alt="Demo: approving a command, answering two questions, approving a plan, replying to a finished task, clicking a card to land on the exact Ghostty tab, and a skill sending the user to a sign-in tab in Brave"></p>

<p align="center"><sub>Recorded from the real app with made-up sessions. <a href="docs/images/demo.mp4">HD video</a></sub></p>

## Install via your AI agent

Paste this into Claude Code (or another coding agent):

> Install beckon from https://github.com/wickes1/beckon on this Mac. Read https://raw.githubusercontent.com/wickes1/beckon/main/README.md first.
> 1. Run `brew install --cask wickes1/tap/beckon`, then `open -a Beckon`.
> 2. Run `claude plugin marketplace add wickes1/beckon` and `claude plugin install beckon@beckon`.
> 3. If the `code` command exists, run `code --install-extension /Applications/Beckon.app/Contents/Resources/beckon.vsix`.
> 4. In `~/.claude/settings.json`, add `"CLAUDE_CLIENT_PRESENCE_FILE": "<my home directory>/Library/Application Support/beckon/present"` to the `env` block. Change nothing else in the file.
> 5. Run `beckon doctor` and show me the output. No line may start with ✗.
>
> Stop and ask me if anything is ambiguous; do not guess.

## Install

Needs macOS 14 or later and Claude Code.

### Homebrew

```sh
brew install --cask wickes1/tap/beckon
open -a Beckon
claude plugin marketplace add wickes1/beckon
claude plugin install beckon@beckon
beckon doctor
```

Restart Claude Code sessions that were already running.

| Also | How |
|---|---|
| Start with the Mac | menu bar icon → Open at Login |
| Exact VS Code window and terminal | `code --install-extension /Applications/Beckon.app/Contents/Resources/beckon.vsix` — VS Code keeps extensions per profile, so add `--profile "<name>"` for each profile other than the default |
| Phone pushes only while the screen is locked | the `env` line `beckon doctor` prints (see "Phone pushes") |
| After `brew upgrade` | `open -a Beckon` — an upgrade quits the app |

Beckon.app is self-signed, not notarized. The cask clears the download quarantine flag after installing; without that, Gatekeeper refuses the app. A zip downloaded by hand from the releases page stays blocked, so install through Homebrew or from source.

### From source

Needs the Swift toolchain (Xcode or Command Line Tools) and `jq`.

```sh
git clone https://github.com/wickes1/beckon && cd beckon
scripts/install.sh
```

`scripts/install.sh` creates a self-signed signing identity (`beckon Dev`), builds and installs `~/Applications/Beckon.app`, links `~/.local/bin/beckon`, merges the hooks and the presence line into `~/.claude/settings.json` (a backup is written next to it), installs the VS Code extension if `code` is on PATH, and runs `beckon doctor`. This route writes the hooks itself: do not add the plugin on top, or every prompt arrives twice.

Never run an ad-hoc-signed build: macOS ties permission grants to the signing identity and remembers a refusal per bundle ID.

### Permissions macOS will ask for

The first time you click through to Ghostty, Terminal.app or Brave, macOS asks whether beckon may control that app. Until you allow it, beckon can only bring the app forward and assumes you're looking at the session whenever that app is in front.

### Uninstall

| Installed with | Remove with |
|---|---|
| Homebrew | `brew uninstall --zap --cask beckon`, `claude plugin uninstall beckon@beckon` |
| Source | `scripts/hooks.sh uninstall`, then `pkill -x BeckonApp; rm -rf ~/Applications/Beckon.app ~/.local/bin/beckon ~/Library/Application\ Support/beckon` |
| VS Code extension | `code --uninstall-extension wickend.beckon` |

## What works where

Cards appear, and can be answered, for a session in any terminal. What differs by app is how precisely a click lands. Seen working on one Mac (macOS 26, Claude Code 2.1.322); the record of what was checked and how is in [docs/plan.md](docs/plan.md) under "Verification".

| Surface | A click lands on |
|---|---|
| VS Code integrated terminal, Claude Code side panel | the exact window and terminal (needs the extension) |
| Ghostty | the exact tab |
| Brave | the exact tab, for `beckon notify --brave-tab` |
| Any URL, for `beckon notify --url` | whatever macOS opens it with: a web page in the default browser, `file:///Applications/<App>.app` starts or brings up that app |
| Terminal.app | the exact tab — written, not yet run |
| Cursor, VSCodium, VS Code Insiders | the exact window and terminal, as VS Code (needs the extension) — written, not yet run |
| Any other terminal (iTerm2, Warp, kitty, WezTerm, …) | the app, brought forward, not the tab — written, not yet run. A card for a session there is also held back whenever that app is in front, whichever tab you are on |
| Other browsers | no exact tab; `--url` opens a page in the default one |

## What appears on the panel

| Card | When | What you do |
|---|---|---|
| Approval | Claude Code asks permission for a tool call | `Yes`, `Yes, and don't ask again …`, or type what Claude should do instead |
| Question | Claude calls AskUserQuestion | pick per question (or type your own); the last single-select pick sends, typed or multi-select answers use `Send` |
| Plan review | Claude leaves plan mode | approve (auto-accept edits, or review each edit), or type what to change |
| Action needed | a skill ran `beckon notify` | follow the steps; `Open in Brave` jumps to the exact tab |
| Done | a turn you started has ended | click the card to go to that session (the card goes away), or type a reply to wake the idle session |
| Stopped | a turn ended on an API error | read the error; click the card to go to the session |

<table>
  <tr>
    <td width="50%" valign="top"><img src="docs/images/card-approval.png" alt="Approval card for a Bash command, with Yes, Yes and don't ask again, and No options"></td>
    <td width="50%" valign="top"><img src="docs/images/card-edit.png" alt="Approval card for a file edit, showing the diff"></td>
  </tr>
  <tr>
    <td align="center"><sub>Approval: a command</sub></td>
    <td align="center"><sub>Approval: an edit, with its diff</sub></td>
  </tr>
  <tr>
    <td valign="top"><img src="docs/images/card-question.png" alt="Question card: question 1 of 2 with three options and a field for your own answer"></td>
    <td valign="top"><img src="docs/images/card-plan.png" alt="Plan review card: the plan in a scrolling box, approve or keep planning"></td>
  </tr>
  <tr>
    <td align="center"><sub>Question</sub></td>
    <td align="center"><sub>Plan review</sub></td>
  </tr>
  <tr>
    <td valign="top"><img src="docs/images/card-done.png" alt="Done card: Claude's summary of the finished task and a reply field"></td>
    <td valign="top"><img src="docs/images/card-notify.png" alt="Action needed card: numbered sign-in steps, I've done it and Open in Browser buttons"></td>
  </tr>
  <tr>
    <td align="center"><sub>Done, with a reply field</sub></td>
    <td align="center"><sub>Action needed, from <code>beckon notify</code></sub></td>
  </tr>
</table>

Rules that hold for every card:

- The terminal dialog stays live. Whichever is answered first wins; the other clears itself.
- No card while you are looking at that session's terminal. A prompt held back this way is still counted in the menu bar (the number beside the icon) and appears when you look away.
- A card makes a sound when it comes onto the panel: Glass when Claude is waiting on you, Tink for Done / Stopped. Menu bar icon → Sounds picks another system sound or None for each, or mutes both.
- The × on a prompt card only hides it: Claude keeps waiting in the terminal and the item stays in the menu bar list.
- Clicking the top of any card (its header and title) takes you to that session, and every card of that session leaves the panel: news goes away, a prompt is hidden as with ×. Another session's cards, and a skill's other "Action needed" cards, stay.
- Only one copy of the app runs at a time; a second one quits at once instead of taking over the socket.
- The panel never takes the keyboard unless you click one of its text fields, and hands it back when you send.
- Every answer given in the panel is logged to `~/Library/Logs/beckon.log`.
- If the app isn't running, every hook exits at once and Claude Code behaves as if beckon weren't installed.
- Headless runs (`claude -p`, the SDK) are ignored.

## Commands

```sh
beckon doctor
beckon notify --title "Log in to Example Bank" --step "Sign in" --step "Tick “Remember this device”" --brave-tab 1234567 --key bank-login
beckon dismiss --key bank-login
```

| Command | Flags | Does |
|---|---|---|
| `beckon doctor` | | checks the app, its signature, the hooks, the presence file, VS Code windows and Automation permissions; exits 1 if a check fails |
| `beckon notify` | `--title <text>` (required), `--message <text>`, `--step <text>` (repeatable), `--brave-tab <id>` or `--url <url>`, `--key <name>` | shows an "Action needed" card for the current session; exits 1 if the app isn't running, so the caller can fall back |
| `beckon dismiss` | `--key <name>` (required) | takes that card down |
| `beckon hook <Event>` | `--rewake` (Stop only) | run by Claude Code's hooks; reads the hook JSON on stdin and always exits 0 when the app can't be reached |
| `beckon --version` | | prints the version |

`notify` is for skills that need you to do something outside the terminal. It returns at once; the skill keeps watching for the result itself and calls `dismiss` when it sees it. `--brave-tab` takes the tab id the claude-in-chrome tools report.

## Phone pushes

beckon keeps a presence file in place while the screen is unlocked and removes it on lock. Point Claude Code at it with `CLAUDE_CLIENT_PRESENCE_FILE` in the `env` block of `~/.claude/settings.json` (`scripts/hooks.sh install` writes it; a plugin cannot, so after a Homebrew install `beckon doctor` prints the line to add) and Claude Code's Remote Control pushes reach your phone only when you can't see the panel.

## Layout

- `Sources/beckon` — the hook CLI. Darwin only, no Foundation; forwards the hook JSON plus process ancestry and terminal env vars to the app, prints the decision, fails open on any error.
- `Sources/BeckonApp` — menu-bar agent: socket server, intake of hook events, store, panel, focus, presence, doctor.
- `Sources/BeckonCore` — paths and version shared by both.
- `vscode/` — the VS Code extension (plain JavaScript, one file). The build packs it into `Beckon.app/Contents/Resources/beckon.vsix`.
- `plugin/` + `.claude-plugin/marketplace.json` — the same hooks as a Claude Code plugin, for installs where `beckon` is on PATH.
- `packaging/beckon.rb.in` — Homebrew cask template.
- `prototype/panel.swift` — the look-and-feel prototype the panel was designed in.
- `Resources/AppIcon.svg` — the icon. `Resources/AppIcon.icns` is generated from it (`rsvg-convert` at each iconset size, then `iconutil -c icns`) and committed, so a build needs neither tool.
- `docs/images/` — README screenshots and demo, taken from the real app fed made-up hook events.

## Development

```sh
scripts/test.sh                     # unit tests (Swift Testing; works with Command Line Tools only)
scripts/build-app.sh --install      # rebuild, re-sign, replace the installed app, relaunch
scripts/hooks.sh print hooks.json   # hooks-only settings file: claude --setting-sources project,local --settings hooks.json
scripts/build-vscode.sh --install   # repack and reinstall the extension
scripts/release.sh                  # universal build → dist/Beckon-<version>.zip + dist/beckon.rb
```

The version lives in one place, `Sources/BeckonCore/Paths.swift`. `plugin/hooks/hooks.json` must list the same hooks as `scripts/hooks.sh`. Release steps: [docs/releasing.md](docs/releasing.md).
