#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity "beckon Dev" in the login keychain.
# WHY: ad-hoc builds have no stable code identity, so macOS refuses them notification
# permission outright and re-prompts Automation/Accessibility grants after every rebuild.
# A real (even self-signed) certificate gives an identity those grants stick to.
# Approach adapted from Boopr (MIT, memorte03/boopr-claude-notifier, scripts/make-signing-cert.sh).
# Run once. macOS may ask for your login password to trust the certificate.
set -euo pipefail

CERT_NAME="beckon Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$CERT_NAME\""; then
  echo "identity '$CERT_NAME' already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

# Separate PEMs, not PKCS12: OpenSSL 3 p12 files fail `security import` MAC verification.
security import "$TMP/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
security import "$TMP/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null

if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"; then
  echo "trust not set automatically: Keychain Access → login → '$CERT_NAME' → Trust → Code Signing → Always Trust" >&2
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$CERT_NAME\""; then
  echo "created code-signing identity '$CERT_NAME'"
else
  echo "identity not valid yet (trust step incomplete?)" >&2
  exit 1
fi
