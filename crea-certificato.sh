#!/bin/bash
# Crea (una volta sola) un certificato personale per firmare Registratore.
# Con una firma stabile macOS riconosce l'app anche dopo ogni ricompilazione
# e non chiede più i permessi (microfono, registrazione schermo e audio).
# Per rimuoverlo: Accesso Portachiavi > login > Certificati > "Registratore Firma Locale".
set -euo pipefail

NAME="Registratore Firma Locale"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Il certificato \"$NAME\" esiste già."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
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
EOF

PASS=$(openssl rand -hex 16)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo "Certificato \"$NAME\" creato. Ora esegui ./build.sh"
