#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Funções e carregamento de ambiente compartilhados pelos scripts do lab.
# Uso: source "$(dirname "$0")/lib/common.sh"
# ---------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# --- saída -----------------------------------------------------------------
info() { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m OK\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31mERRO\033[0m %s\n' "$*" >&2; exit 1; }

# --- ambiente --------------------------------------------------------------
[ -f .env ] || die ".env não encontrado. Rode primeiro: cp .env.example .env"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

for var in MINIO_ROOT_USER MINIO_ROOT_PASSWORD MINIO_BUCKET TEST_OBJECT \
           PUBLIC_HOST PUBLIC_SCHEME NGINX_HTTP_PORT NGINX_HTTPS_PORT \
           PRESIGN_EXPIRY; do
    [ -n "${!var:-}" ] || die "variável $var ausente ou vazia no .env"
done

# Endpoint público usado para assinar as URLs.
PUBLIC_ENDPOINT="${PUBLIC_SCHEME}://${PUBLIC_HOST}:${NGINX_HTTPS_PORT}"
export PUBLIC_ENDPOINT

# --- dependências ----------------------------------------------------------
need_docker() {
    command -v docker >/dev/null 2>&1 || die "docker não encontrado no PATH"
    docker compose version >/dev/null 2>&1 \
        || die "docker compose v2 não disponível (use 'docker compose', não 'docker-compose')"
}

# Executa um trecho de shell dentro do container mc, na rede do compose.
# O trecho recebe as variáveis do .env já exportadas pelo compose.
mc_run() {
    docker compose run --rm -T mc -c "$1"
}

# Trechos de shell que registram os dois aliases. São strings passadas a
# `sh -c` DENTRO do container: as aspas e os $ precisam sobreviver literais
# até lá, por isso aspas simples aqui. Os avisos SC2016/SC2089/SC2090
# apontam exatamente o comportamento desejado e são silenciados abaixo.
# shellcheck disable=SC2016,SC2089
MC_ALIAS_ADMIN='mc --no-color alias set lab http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null'
# shellcheck disable=SC2016,SC2089
MC_ALIAS_PROXY='mc --no-color --insecure alias set proxy "$PUBLIC_SCHEME://$PUBLIC_HOST:$NGINX_HTTPS_PORT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null'
# shellcheck disable=SC2090
export MC_ALIAS_ADMIN MC_ALIAS_PROXY

# Portas e hostname existem em dois lugares (.env e nginx/nginx.conf).
# Divergir entre eles é o caminho mais curto para SignatureDoesNotMatch, então
# a checagem roda automaticamente ao carregar este arquivo.
check_nginx_conf_matches_env() {
    local conf="nginx/nginx.conf"
    [ -f "$conf" ] || die "$conf não encontrado"

    grep -Eq "listen[[:space:]]+${NGINX_HTTP_PORT}([[:space:]]|;)" "$conf" \
        || die "porta HTTP divergente: .env diz NGINX_HTTP_PORT=$NGINX_HTTP_PORT,
     mas $conf não tem 'listen $NGINX_HTTP_PORT'. Ajuste os dois."

    grep -Eq "listen[[:space:]]+${NGINX_HTTPS_PORT}[[:space:]]+ssl" "$conf" \
        || die "porta HTTPS divergente: .env diz NGINX_HTTPS_PORT=$NGINX_HTTPS_PORT,
     mas $conf não tem 'listen $NGINX_HTTPS_PORT ssl'. Ajuste os dois.
     A porta entra no Host assinado — divergir quebra a assinatura SigV4."

    grep -Eq "server_name[[:space:]]+${PUBLIC_HOST};" "$conf" \
        || die "hostname divergente: .env diz PUBLIC_HOST=$PUBLIC_HOST,
     mas $conf não tem 'server_name $PUBLIC_HOST;'. Ajuste os dois."
}

check_nginx_conf_matches_env

# Confirma que o hostname público resolve na máquina (arquivo de hosts).
check_hosts_entry() {
    if ! getent hosts "$PUBLIC_HOST" >/dev/null 2>&1; then
        die "$PUBLIC_HOST não resolve nesta máquina.
     Adicione ao arquivo de hosts:  127.0.0.1  $PUBLIC_HOST
     Linux/WSL: /etc/hosts
     Windows:   C:\\Windows\\System32\\drivers\\etc\\hosts (como administrador)"
    fi
}
