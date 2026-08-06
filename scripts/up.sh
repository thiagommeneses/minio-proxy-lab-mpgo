#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Sobe o laboratório. Use este script em vez de `docker compose up -d`.
#
# Motivo: as portas e o hostname existem em dois lugares — .env e
# nginx/nginx.conf. Subir pelo compose direto não compara os dois, e a
# divergência só apareceria muito depois, como SignatureDoesNotMatch.
# O source de lib/common.sh já executa essa checagem.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

need_docker

[ -f nginx/certs/server.crt ] && [ -f nginx/certs/server.key ] \
    || die "certificado ausente. Rode primeiro: bash scripts/00-setup-certs.sh"

ok ".env e nginx/nginx.conf conferem (portas $NGINX_HTTP_PORT/$NGINX_HTTPS_PORT, host $PUBLIC_HOST)"

info "subindo os serviços"
docker compose up -d "$@"

echo
docker compose ps
