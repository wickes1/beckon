# Releasing

1. Set the version in `Sources/BeckonCore/Paths.swift`, `vscode/package.json` and `plugin/.claude-plugin/plugin.json`.
2. `scripts/release.sh` → `dist/Beckon-<version>.zip` and `dist/beckon.rb`.
3. `gh release create v<version> dist/Beckon-<version>.zip --target main` makes the `v<version>` tag and the release page in one step; `git fetch --tags` brings the tag into the local clone. Every version gets both.
4. Copy `dist/beckon.rb` to `Casks/beckon.rb` in the `wickes1/homebrew-tap` repository.
5. VS Code extension, when `vscode/` changed: `cd vscode && npx @vscode/vsce package`, upload the `.vsix` at https://marketplace.visualstudio.com/manage/publishers/wickend, and `npx ovsx publish <file>.vsix` with the Open VSX token in `OVSX_PAT` (Cursor and VSCodium install from Open VSX).

Every release must be signed with the same `beckon Dev` identity: macOS ties the Automation permissions people granted to that certificate, and a release signed with another one makes it ask again. Keep a copy of its private key off this Mac.

With an Apple Developer ID, `BECKON_SIGN_IDENTITY="Developer ID Application: …" BECKON_NOTARY_PROFILE=<profile> scripts/release.sh` signs, notarizes and staples instead; that path has not been run.
