#!/usr/bin/env bash
# Creates a self-signed code signing identity in the login keychain so that
# rebuilt binaries keep the same designated requirement (and TCC permissions).
set -euo pipefail

NAME="mac-input-switcher-local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Signing identity '$NAME' already exists."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOC
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOC

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout pass:temp -out "$TMP/identity.p12"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign
# Prompts for the login password to trust the certificate for code signing.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "$NAME"
echo "Created signing identity '$NAME'."
