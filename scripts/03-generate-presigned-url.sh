#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Gera a URL pré-assinada usando o alias que aponta para o PROXY.
#
# É este script que materializa a premissa da seção 3 do CLAUDE.md: a URL
# precisa nascer assinada com o Host do proxy. Se sair com qualquer outro
# host, o script falha — em vez de deixar o erro aparecer só no player.
#
# stdout: apenas a URL (permite  URL="$(bash scripts/03-...sh)")
# stderr: mensagens humanas
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

need_docker

info "gerando URL pré-assinada (expira em $PRESIGN_EXPIRY) via $PUBLIC_ENDPOINT" >&2

RAW="$(mc_run "
set -e
$MC_ALIAS_PROXY
mc --no-color --insecure share download \
   --expire \"\$PRESIGN_EXPIRY\" \
   proxy/\"\$MINIO_BUCKET\"/\"\$TEST_OBJECT\"
")"

URL="$(
    printf '%s\n' "$RAW" \
    | tr -d '\r' \
    | grep '^Share: ' \
    | cut -d' ' -f2
)"

[ -n "$URL" ] || die "não foi possível extrair a URL. Saída do mc:
$RAW"

# --- validação do host assinado -------------------------------------------
case "$URL" in
    "$PUBLIC_ENDPOINT"/*)
        ok "URL assinada com o host do proxy ($PUBLIC_HOST:$NGINX_HTTPS_PORT)" >&2
        ;;
    *)
        die "a URL NÃO aponta para o proxy — a PoC falharia aqui.
     esperado começar com: $PUBLIC_ENDPOINT/
     obtido:               $URL
     Verifique o alias 'proxy' e a variável MINIO_SERVER_URL."
        ;;
esac

case "$URL" in
    *X-Amz-Signature=*) : ;;
    *) die "a URL não contém assinatura SigV4: $URL" ;;
esac

printf '%s\n' "$URL"
