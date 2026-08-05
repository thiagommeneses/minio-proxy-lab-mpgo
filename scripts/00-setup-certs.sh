#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Gera o certificado autoassinado usado pelo NGINX.
# Idempotente: não regera se o par já existir (use --force para substituir).
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CERT_DIR="nginx/certs"
CRT="$CERT_DIR/server.crt"
KEY="$CERT_DIR/server.key"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

command -v openssl >/dev/null 2>&1 || die "openssl não encontrado no PATH"

if [ -f "$CRT" ] && [ -f "$KEY" ] && [ "$FORCE" -eq 0 ]; then
    info "certificado já existe em $CERT_DIR (use --force para regerar)"
    openssl x509 -in "$CRT" -noout -subject -ext subjectAltName -enddate
    exit 0
fi

mkdir -p "$CERT_DIR"

info "gerando certificado autoassinado para $PUBLIC_HOST"

# SAN é obrigatório: clientes modernos ignoram o CN sozinho.
openssl req -x509 -nodes \
    -newkey rsa:2048 \
    -keyout "$KEY" \
    -out "$CRT" \
    -days 825 \
    -subj "/C=BR/ST=Goias/L=Goiania/O=MPGO/OU=Lab/CN=$PUBLIC_HOST" \
    -addext "subjectAltName=DNS:$PUBLIC_HOST,DNS:localhost,IP:127.0.0.1" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    2>/dev/null

chmod 644 "$CRT"
chmod 600 "$KEY"

ok "certificado gerado"
openssl x509 -in "$CRT" -noout -subject -ext subjectAltName -enddate
