#!/bin/bash
# Explicit, one-time setup for local development; never called by the build.
set -euo pipefail
CERT_NAME="Relay Local Development"
if security find-identity -v -p codesigning | rg -q '"Relay Local Development"'; then
    echo "Relay Local Development is already available. Reusing it."
    exit 0
fi
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "A Relay Local Development certificate already exists but is not a valid signing identity." >&2
    echo "Check its private key, expiry, and Code Signing trust in Keychain Access before retrying." >&2
    exit 1
fi
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
umask 077
SIGNING_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/relay-signing.XXXXXX")"
trap 'rm -rf "$SIGNING_TEMP"' EXIT
cat > "$SIGNING_TEMP/certificate.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Relay Local Development
[extensions]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign,cRLSign
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
/usr/bin/openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -config "$SIGNING_TEMP/certificate.cnf" \
    -keyout "$SIGNING_TEMP/key.pem" -out "$SIGNING_TEMP/certificate.pem" 2> "$SIGNING_TEMP/generation.log"
# The temporary directory is private and removed on exit. No private key is
# written into the repository. Only codesign is authorized to use the key.
/usr/bin/openssl rand -hex 32 > "$SIGNING_TEMP/import-password"
/usr/bin/openssl pkcs12 -export -inkey "$SIGNING_TEMP/key.pem" -in "$SIGNING_TEMP/certificate.pem" \
    -name "$CERT_NAME" -out "$SIGNING_TEMP/identity.p12" -passout "file:$SIGNING_TEMP/import-password"
security import "$SIGNING_TEMP/identity.p12" -k "$KEYCHAIN" \
    -P "$(cat "$SIGNING_TEMP/import-password")" -T /usr/bin/codesign
# User trust, restricted to code signing; no SSL or system-wide trust override.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$SIGNING_TEMP/certificate.pem"
if ! security find-identity -v -p codesigning | rg -q '"Relay Local Development"'; then
    echo "Certificate imported, but signing validation failed. Inspect Code Signing trust in Keychain Access." >&2
    exit 1
fi
echo "Stable Relay signing identity is ready in the login keychain."
