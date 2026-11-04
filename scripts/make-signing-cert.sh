#!/usr/bin/env bash
# Cria no chaveiro de início de sessão um certificado autoassinado de assinatura de código.
# Com ele a "designated requirement" da Lupa fica estável entre compilações, e o macOS
# mantém a permissão de Gravação de Tela; na assinatura ad-hoc ela muda a cada build.
set -euo pipefail

name="${1:-Lupa Local Signing}"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "certificado já existe: $name"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass="lupa-$RANDOM-$RANDOM"

cat > "$work/cert.cnf" <<CNF
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

# O openssl do sistema (LibreSSL) gera o .p12 num formato que o security import aceita.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$name" -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/cert.p12" -passout "pass:$pass" 2>/dev/null
security import "$work/cert.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "certificado criado no chaveiro: $name"
