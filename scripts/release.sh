#!/usr/bin/env bash
# Builds the distributable: a universal Beckon.app, zipped, plus a Homebrew cask that points at it.
#   scripts/release.sh
# Environment:
#   BECKON_SIGN_IDENTITY   codesign identity (default "beckon Dev", the self-signed one). Releases must keep using
#                          the same identity: macOS ties the permissions users granted to it. A build signed this
#                          way is not notarized, so the cask clears the download quarantine after installing; only
#                          a "Developer ID Application: …" certificate gives a zip Gatekeeper opens by itself.
#   BECKON_NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials). When set, the zip is
#                          notarized and the app stapled; needs a Developer ID identity.
#   BECKON_REPO            GitHub owner/repo the release zip will be uploaded to (default wickes1/beckon); only
#                          used for the URL written into the cask.
# Output in dist/: Beckon-<version>.zip, beckon.rb. Uploading the zip and publishing the cask are manual steps.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${BECKON_SIGN_IDENTITY:-beckon Dev}"
REPO="${BECKON_REPO:-wickes1/beckon}"
VERSION="$(sed -n 's/^public let beckonVersion = "\(.*\)"$/\1/p' Sources/BeckonCore/Paths.swift)"
[[ -n "$VERSION" ]] || { echo "could not read beckonVersion" >&2; exit 1; }
grep -q "\"version\": \"$VERSION\"" plugin/.claude-plugin/plugin.json || { echo "plugin/.claude-plugin/plugin.json version differs from beckonVersion ($VERSION)" >&2; exit 1; }
security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" || { echo "no \"$IDENTITY\" signing identity" >&2; exit 1; }

# Two single-arch builds joined with lipo: a multi-arch `swift build` needs full Xcode, this works with
# Command Line Tools alone.
for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path ".build/release-$arch"
done
APP=dist/Beckon.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
bin_dir() { swift build -c release --triple "$1-apple-macosx14.0" --scratch-path ".build/release-$1" --show-bin-path; }
for bin in BeckonApp beckon; do
  lipo -create "$(bin_dir arm64)/$bin" "$(bin_dir x86_64)/$bin" -output "$APP/Contents/MacOS/$bin"
  # Debug symbols name every object file by its full path on the build machine: a release must not carry that.
  strip -S "$APP/Contents/MacOS/$bin" 2>/dev/null
  if LC_ALL=C grep -aq "$HOME" "$APP/Contents/MacOS/$bin"; then echo "$bin still contains $HOME after strip" >&2; exit 1; fi
done

# The VS Code extension rides inside the bundle, so an install that has no checkout of this repo (Homebrew)
# still has it; `beckon doctor` prints the command that installs it.
scripts/build-vscode.sh
mkdir -p "$APP/Contents/Resources"
cp vscode/beckon.vsix "$APP/Contents/Resources/beckon.vsix"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime + secure timestamp are what notarization requires; a self-signed identity can't get a timestamp.
SIGN=(codesign --force --sign "$IDENTITY")
[[ "$IDENTITY" == "Developer ID Application:"* ]] && SIGN+=(--options runtime --timestamp)
"${SIGN[@]}" "$APP/Contents/MacOS/beckon"
"${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"

ZIP="dist/Beckon-$VERSION.zip"
# No extended attributes in the zip: plain `unzip` would unpack them as ._ files inside the bundle, and the
# signature then fails to verify.
zip_app() { ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"; }
zip_app
if [[ -n "${BECKON_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$BECKON_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && zip_app  # the zip must carry the stapled ticket
else
  echo "not notarized (BECKON_NOTARY_PROFILE unset): installs through the cask, which clears the quarantine flag; a zip downloaded by hand is refused by Gatekeeper"
fi

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" -e "s#@REPO@#$REPO#" packaging/beckon.rb.in > dist/beckon.rb
echo "built $ZIP ($(lipo -archs "$APP/Contents/MacOS/BeckonApp")), sha256 $SHA"
echo "cask written to dist/beckon.rb"
