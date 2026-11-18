#!/usr/bin/env bash
# Creates a self-signed code signing certificate, "MacMeet Local Signing", in a keychain file
# inside the project (.signing/MacMeet.keychain-db), not in your login keychain.
#
# macOS ties privacy permissions (camera, microphone, Screen Recording) to an app's code
# signature. An ad-hoc signature changes on every build, which orphans those permissions; signing
# with a fixed certificate keeps them across rebuilds. build.sh uses this keychain when present.
#
# The certificate only signs this local build, so the keychain uses a fixed, non-secret password.
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="MacMeet Local Signing"
KEYCHAIN="$PWD/.signing/MacMeet.keychain-db"
KEYCHAIN_PASSWORD="macmeet"

if [[ -f "$KEYCHAIN" ]]; then
  echo "$KEYCHAIN already exists."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# The system LibreSSL writes a PKCS#12 format that `security import` accepts; OpenSSL 3 does not.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/cert.p12" -passout "pass:$KEYCHAIN_PASSWORD" 2>/dev/null

mkdir -p "$(dirname "$KEYCHAIN")"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"  # never auto-lock
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a keychain access prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

echo "Created $KEYCHAIN"
