#!/usr/bin/env bash
#
# Creates a stable, self-signed code-signing identity in the login keychain.
#
# Why: the app is signed locally (no Apple Developer account). Ad-hoc signing
# (`codesign --sign -`) changes the code's identity on every rebuild, so macOS
# resets TCC permissions (Input Monitoring, Accessibility) each time. Signing
# with a fixed self-signed certificate gives the app a stable Designated
# Requirement, so granted permissions persist across rebuilds.
#
# This is idempotent: if the identity already exists it does nothing.
set -euo pipefail

CERT_CN="MacWhisper Local Signing"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$CERT_CN"; then
    echo "==> Signing identity '$CERT_CN' already exists; nothing to do."
    exit 0
fi

echo "==> Creating self-signed code-signing certificate '$CERT_CN'"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PW="macwhisper"

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=${CERT_CN}" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false"

# Apple's `security` tool cannot read OpenSSL 3.x default PKCS#12 MACs, so export
# with the legacy SHA1/3DES algorithms it understands.
openssl pkcs12 -export -out "$TMP/cert.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:${PW}" -name "${CERT_CN}" \
    -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

# -A allows codesign to use the private key without per-build keychain prompts.
security import "$TMP/cert.p12" -k "$LOGIN_KC" -P "$PW" -T /usr/bin/codesign -A

echo "==> Imported '$CERT_CN' into the login keychain."
echo "    Rebuild with 'make app'; permissions you grant will now persist."
