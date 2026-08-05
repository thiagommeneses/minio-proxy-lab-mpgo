#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Valida o fluxo completo e imprime um resumo dos critérios de sucesso.
# Não interrompe no primeiro erro: roda tudo e reporta o placar no final.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

need_docker
check_hosts_entry
command -v curl >/dev/null 2>&1 || die "curl não encontrado no PATH"

PASS=0
FAIL=0

check() { # check <descrição> <esperado> <obtido>
    if [ "$2" = "$3" ]; then
        printf '\033[0;32m  PASS\033[0m %-45s (%s)\n' "$1" "$3"
        PASS=$((PASS + 1))
    else
        printf '\033[0;31m  FAIL\033[0m %-45s esperado=%s obtido=%s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
info "1/5  proxy responde"
HEALTH="$(curl -sk -o /dev/null -w '%{http_code}' -m 10 \
          "$PUBLIC_ENDPOINT/healthz" || echo 000)"
check "NGINX no ar (HTTPS)" "200" "$HEALTH"

# ---------------------------------------------------------------------------
info "2/5  MinIO não acessível diretamente pelo host"
DIRECT="$(curl -s -o /dev/null -w '%{http_code}' -m 3 \
          "http://127.0.0.1:9000/" 2>/dev/null || echo 000)"
# 000 = conexão recusada/timeout, que é exatamente o resultado desejado.
check "MinIO sem porta publicada" "000" "$DIRECT"

# ---------------------------------------------------------------------------
info "3/5  gerando URL pré-assinada"
URL="$(bash scripts/03-generate-presigned-url.sh)" \
    || die "falha ao gerar a URL pré-assinada"
printf '     %s\n' "$URL"

# ---------------------------------------------------------------------------
info "4/5  acesso ao objeto pelo proxy"
CODE="$(curl -sk -o /dev/null -w '%{http_code}' -m 30 -I "$URL" || echo 000)"
check "GET/HEAD do objeto" "200" "$CODE"

CTYPE="$(curl -sk -o /dev/null -w '%{content_type}' -m 30 -I "$URL" || echo '')"
printf '     content-type: %s\n' "${CTYPE:-<vazio>}"

# ---------------------------------------------------------------------------
info "5/5  streaming com Range (seek do player)"
RANGE_CODE="$(curl -sk -r 0-1023 -o /dev/null -w '%{http_code}' -m 30 "$URL" || echo 000)"
check "206 Partial Content" "206" "$RANGE_CODE"

RANGE_BYTES="$(curl -sk -r 0-1023 -o /dev/null -w '%{size_download}' -m 30 "$URL" || echo 0)"
check "1024 bytes no range pedido" "1024" "$RANGE_BYTES"

# ---------------------------------------------------------------------------
# Certificado apresentado — informativo, não entra no placar.
info "certificado apresentado pelo proxy"
if command -v openssl >/dev/null 2>&1; then
    echo | openssl s_client -connect "$PUBLIC_HOST:$NGINX_HTTPS_PORT" \
        -servername "$PUBLIC_HOST" 2>/dev/null \
      | openssl x509 -noout -subject -issuer -enddate 2>/dev/null \
      | sed 's/^/     /' || warn "não foi possível ler o certificado"
else
    warn "openssl ausente, pulando inspeção do certificado"
fi

# ---------------------------------------------------------------------------
echo
info "expiração da URL: não testada aqui (PRESIGN_EXPIRY=$PRESIGN_EXPIRY)"
echo "     Para validar, gere uma URL curta e aguarde:"
echo "       PRESIGN_EXPIRY=30s bash scripts/03-generate-presigned-url.sh"
echo "       sleep 35 && curl -sk -o /dev/null -w '%{http_code}\\n' \"\$URL\"   # esperado: 403"

echo
printf '\033[1m  RESULTADO: %d passaram, %d falharam\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
