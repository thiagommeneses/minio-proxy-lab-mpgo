#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Valida o fluxo completo e imprime um placar dos critérios de sucesso.
# Não interrompe no primeiro erro: roda tudo e reporta o placar no final.
#
# NOTA IMPORTANTE SOBRE HEAD
# Não use `curl -I` para testar uma URL pré-assinada. A assinatura SigV4 cobre
# o método HTTP, e `mc share download` assina para GET — um HEAD produz um
# canonical request diferente e o MinIO responde 403 SignatureDoesNotMatch
# mesmo com o proxy perfeitamente configurado.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

need_docker
check_hosts_entry
command -v curl >/dev/null 2>&1 || die "curl não encontrado no PATH"

PASS=0
FAIL=0

check() { # check <descrição> <esperado> <obtido>
    if [ "$2" = "$3" ]; then
        printf '\033[0;32m  PASS\033[0m %-42s (%s)\n' "$1" "$3"
        PASS=$((PASS + 1))
    else
        printf '\033[0;31m  FAIL\033[0m %-42s esperado=%s obtido=%s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

# curl que nunca devolve string vazia: %{http_code} já imprime 000 em falha de
# conexão, então o `|| true` existe só para não disparar o `set -e`.
http_code() {
    local out
    out="$(curl -sk -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)"
    printf '%s' "${out:-000}"
}

# ---------------------------------------------------------------------------
info "1/5  proxy responde"
check "NGINX no ar (HTTPS)" "200" "$(http_code -m 10 "$PUBLIC_ENDPOINT/healthz")"

# ---------------------------------------------------------------------------
info "2/5  MinIO não acessível diretamente pelo host"
# 000 = conexão recusada ou timeout, que é exatamente o resultado desejado.
check "MinIO sem porta publicada" "000" "$(http_code -m 3 "http://127.0.0.1:9000/")"

# ---------------------------------------------------------------------------
info "3/5  gerando URL pré-assinada"
URL="$(bash scripts/03-generate-presigned-url.sh)" \
    || die "falha ao gerar a URL pré-assinada"
printf '     %s\n' "$URL"

# ---------------------------------------------------------------------------
info "4/5  download do objeto pelo proxy (GET, nunca HEAD)"
STATS="$(curl -sk -o /dev/null -w '%{http_code} %{content_type} %{size_download}' \
         -m 300 "$URL" 2>/dev/null || true)"
[ -n "$STATS" ] || STATS="000 - 0"
# shellcheck disable=SC2086
set -- $STATS
CODE="${1:-000}"; CTYPE="${2:--}"; SIZE="${3:-0}"

check "GET do objeto" "200" "$CODE"
printf '     content-type: %s   bytes: %s\n' "$CTYPE" "$SIZE"

# ---------------------------------------------------------------------------
info "5/5  streaming com Range (seek do player)"
check "206 Partial Content" "206" "$(http_code -r 0-1023 -m 30 "$URL")"

RANGE_BYTES="$(curl -sk -r 0-1023 -o /dev/null -w '%{size_download}' -m 30 "$URL" 2>/dev/null || true)"
check "1024 bytes no range pedido" "1024" "${RANGE_BYTES:-0}"

CONTENT_RANGE="$(curl -sk -r 0-1023 -o /dev/null -D- -m 30 "$URL" 2>/dev/null \
                 | tr -d '\r' | awk -F': ' '/^[Cc]ontent-[Rr]ange:/{print $2; exit}')"
printf '     content-range: %s\n' "${CONTENT_RANGE:-<ausente>}"

# ---------------------------------------------------------------------------
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
info "expiração da URL: não testada aqui (levaria $PRESIGN_EXPIRY)"
echo "     Para validar:"
echo "       CURTA=\"\$(PRESIGN_EXPIRY=30s bash scripts/03-generate-presigned-url.sh)\""
echo "       sleep 35 && curl -sk -o /dev/null -w '%{http_code}\\n' \"\$CURTA\"   # esperado: 403"

echo
printf '\033[1m  RESULTADO: %d passaram, %d falharam\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
