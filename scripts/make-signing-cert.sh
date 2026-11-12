#!/usr/bin/env bash
# Creates a self-signed code-signing certificate in the login keychain.
#
# With a stable certificate, Lupa's designated requirement stays the same across builds and macOS
# keeps the Screen Recording permission. With ad-hoc signing it changes on every build.
#
# Usage: scripts/make-signing-cert.sh [name]   (default: "Lupa Local Signing")
set -euo pipefail

name="${1:-Lupa Local Signing}"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "certificate already exists: $name"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Only protects the temporary .p12 between export and import; it never leaves this directory.
pass="$(/usr/bin/openssl rand -hex 16)"

cat >"$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# The system openssl (LibreSSL) writes a .p12 that `security import` accepts; Homebrew's OpenSSL 3
# defaults to algorithms it rejects.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$name" -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/cert.p12" -passout "pass:$pass" 2>/dev/null
security import "$work/cert.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "created certificate in the login keychain: $name"
