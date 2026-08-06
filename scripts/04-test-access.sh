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
TMPFILE="$(mktemp -t mpl-download.XXXXXX)"
trap 'rm -f "$TMPFILE"' EXIT

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
info "1/8  proxy responde"
check "NGINX no ar (HTTPS)" "200" "$(http_code -m 10 "$PUBLIC_ENDPOINT/healthz")"

# ---------------------------------------------------------------------------
info "2/8  MinIO não acessível diretamente pelo host"
# 000 = conexão recusada ou timeout, que é exatamente o resultado desejado.
check "MinIO sem porta publicada" "000" "$(http_code -m 3 "http://127.0.0.1:9000/")"

# ---------------------------------------------------------------------------
info "3/8  gerando URL pré-assinada"
URL="$(bash scripts/03-generate-presigned-url.sh)" \
    || die "falha ao gerar a URL pré-assinada"
printf '     %s\n' "$URL"

# ---------------------------------------------------------------------------
info "4/8  download do objeto pelo proxy (GET, nunca HEAD)"
STATS="$(curl -sk -o "$TMPFILE" -w '%{http_code} %{content_type} %{size_download}' \
         -m 300 "$URL" 2>/dev/null || true)"
[ -n "$STATS" ] || STATS="000 - 0"
# shellcheck disable=SC2086
set -- $STATS
CODE="${1:-000}"; CTYPE="${2:--}"; SIZE="${3:-0}"

check "GET do objeto" "200" "$CODE"
printf '     content-type: %s   bytes: %s\n' "$CTYPE" "$SIZE"

if [ -f assets/video-teste.mp4 ]; then
    if cmp -s assets/video-teste.mp4 "$TMPFILE"; then
        check "conteúdo íntegro (byte a byte)" "identico" "identico"
    else
        check "conteúdo íntegro (byte a byte)" "identico" "difere"
    fi
else
    warn "assets/video-teste.mp4 ausente, integridade não verificada"
fi

# ---------------------------------------------------------------------------
info "5/8  streaming com Range (seek do player)"
check "206 Partial Content" "206" "$(http_code -r 0-1023 -m 30 "$URL")"

RANGE_BYTES="$(curl -sk -r 0-1023 -o /dev/null -w '%{size_download}' -m 30 "$URL" 2>/dev/null || true)"
check "1024 bytes no range pedido" "1024" "${RANGE_BYTES:-0}"

CONTENT_RANGE="$(curl -sk -r 0-1023 -o /dev/null -D- -m 30 "$URL" 2>/dev/null \
                 | tr -d '\r' | awk -F': ' '/^[Cc]ontent-[Rr]ange:/{print $2; exit}')"
printf '     content-range: %s\n' "${CONTENT_RANGE:-<ausente>}"

# ---------------------------------------------------------------------------
# Sem isto, um bucket público passaria em tudo acima e a PoC não provaria nada.
info "6/8  a assinatura está mesmo sendo verificada"
check "sem query string -> 403" "403" "$(http_code -m 15 "${URL%%\?*}")"
check "assinatura adulterada -> 403" "403" "$(http_code -m 15 "${URL%?}X")"

# ---------------------------------------------------------------------------
# Se MINIO_SERVER_URL estiver errado, o MinIO responde 3xx com Location
# apontando para o endereço interno — vazando exatamente o que a PoC esconde.
info "7/8  nenhum vazamento do endpoint interno"

REDIRECTS="$(curl -sk -o /dev/null -w '%{num_redirects}' -r 0-0 -m 30 "$URL" 2>/dev/null || true)"
check "sem redirect" "0" "${REDIRECTS:-erro}"

HDRS="$(curl -sk -D- -o /dev/null -r 0-0 -m 30 "$URL" 2>/dev/null || true)"
LEAK="$(printf '%s' "$HDRS" | grep -ci 'minio:9000\|^location:' || true)"
check "headers sem 'minio:9000' nem Location" "0" "${LEAK:-0}"

# ---------------------------------------------------------------------------
# Gera uma URL de 30s e espera ela morrer. Não dá para testar isso com o
# PRESIGN_EXPIRY real (24h), então o valor é sobreposto só nesta chamada — o
# que só funciona porque lib/common.sh não deixa o .env vencer do ambiente.
# Custa ~40s; SKIP_EXPIRY_TEST=1 pula.
if [ "${SKIP_EXPIRY_TEST:-0}" = "1" ]; then
    info "8/8  expiração da URL: pulada (SKIP_EXPIRY_TEST=1)"
else
    info "8/8  expiração da URL (leva ~40s)"
    CURTA="$(PRESIGN_EXPIRY=30s bash scripts/03-generate-presigned-url.sh 2>/dev/null)" || CURTA=""
    if [ -n "$CURTA" ]; then
        check "URL curta válida agora" "206" "$(http_code -r 0-0 -m 15 "$CURTA")"
        printf '     aguardando 35s para a assinatura expirar...\n'
        sleep 35
        check "URL expirada -> 403" "403" "$(http_code -m 15 "$CURTA")"
    else
        warn "não foi possível gerar a URL curta, expiração não verificada"
    fi
fi

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

echo
printf '\033[1m  RESULTADO: %d passaram, %d falharam\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
