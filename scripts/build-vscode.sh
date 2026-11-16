#!/usr/bin/env bash
# Packs vscode/ into vscode/beckon.vsix. No Node needed: a .vsix is a zip with two manifest files.
#   scripts/build-vscode.sh                      build only
#   scripts/build-vscode.sh --install [profile]  also install it into VS Code (a named profile, else the default one)
# VS Code keeps extensions per profile: a window using another profile needs its own install.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^public let beckonVersion = "\(.*\)"$/\1/p' Sources/BeckonCore/Paths.swift)"
grep -q "\"version\": \"$VERSION\"" vscode/package.json || { echo "vscode/package.json version differs from beckonVersion ($VERSION)" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/extension"
cp vscode/package.json vscode/extension.js vscode/icon.png "$STAGE/extension/"
cp vscode/README.md "$STAGE/extension/readme.md"
cp LICENSE "$STAGE/extension/LICENSE.txt"
DESCRIPTION="$(sed -n 's/.*"description": "\(.*\)",$/\1/p' vscode/package.json)"

cat > "$STAGE/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="beckon" Version="$VERSION" Publisher="wickend" />
    <DisplayName>beckon</DisplayName>
    <Description xml:space="preserve">$DESCRIPTION</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui" />
      <Property Id="Microsoft.VisualStudio.Code.ExecutesCode" Value="true" />
    </Properties>
    <License>extension/LICENSE.txt</License>
    <Icon>extension/icon.png</Icon>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/readme.md" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.License" Path="extension/LICENSE.txt" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Icons.Default" Path="extension/icon.png" Addressable="true" />
  </Assets>
</PackageManifest>
XML
cat > "$STAGE/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".json" ContentType="application/json"/><Default Extension=".md" ContentType="text/markdown"/><Default Extension=".png" ContentType="image/png"/><Default Extension=".txt" ContentType="text/plain"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
XML

OUT="$PWD/vscode/beckon.vsix"
rm -f "$OUT"
(cd "$STAGE" && zip -q -r "$OUT" extension.vsixmanifest '[Content_Types].xml' extension)
echo "built vscode/beckon.vsix ($VERSION)"

if [[ "${1:-}" == "--install" ]]; then
  command -v code >/dev/null || { echo "the 'code' command is not on PATH (VS Code: Shell Command: Install 'code' command in PATH)" >&2; exit 1; }
  if [[ -n "${2:-}" ]]; then code --install-extension "$OUT" --force --profile "$2"; else code --install-extension "$OUT" --force; fi
fi
