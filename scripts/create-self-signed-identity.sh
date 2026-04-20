#!/usr/bin/env bash
# Create a stable self-signed code-signing identity in the user's login keychain so
# successive Joyride builds have a consistent designated requirement — which makes
# TCC (Accessibility / Input Monitoring) reliably register the app in System Settings.
#
# You only need to run this once. Afterwards:
#   SIGN_IDENTITY="Joyride Self-Signed" ./scripts/build-app.sh
# (or just ./scripts/build-app.sh — the build script will auto-detect it.)

set -euo pipefail

IDENTITY_NAME="Joyride Self-Signed"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "Identity already exists: $IDENTITY_NAME"
    echo "Delete from Keychain Access first if you want to recreate it."
    exit 0
fi

echo "Creating self-signed code-signing identity '$IDENTITY_NAME' in $KEYCHAIN …"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CONF="$TMP_DIR/ident.conf"
cat > "$CONF" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = $IDENTITY_NAME

[ ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP_DIR/key.pem" -out "$TMP_DIR/cert.pem" \
    -days 3650 -nodes -config "$CONF" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/ident.p12" -password pass:joyride >/dev/null

security import "$TMP_DIR/ident.p12" -k "$KEYCHAIN" -P joyride -T /usr/bin/codesign >/dev/null

# Mark the cert as trusted for code signing. This is what makes TCC treat the signature
# as stable across rebuilds.
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP_DIR/cert.pem" || true

echo
echo "Done. Verify with:"
echo "  security find-identity -v -p codesigning"
echo
echo "Now rebuild:"
echo "  ./scripts/build-app.sh"
echo
echo "And reset any stale TCC entries once, so macOS re-prompts using the new signature:"
echo "  tccutil reset ListenEvent  com.joyride.app"
echo "  tccutil reset Accessibility com.joyride.app"
