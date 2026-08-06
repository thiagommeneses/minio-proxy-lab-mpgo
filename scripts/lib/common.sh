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

# Carrega o .env SEM sobrescrever variáveis já presentes no ambiente.
# É o que permite sobrepor um valor pontualmente na linha de comando:
#   PRESIGN_EXPIRY=30s bash scripts/03-generate-presigned-url.sh
# Um 'set -a; . ./.env' faria o arquivo vencer da variável passada pelo caller.
while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line#"${_line%%[![:space:]]*}"}"          # trim à esquerda
    case "$_line" in ''|'#'*) continue ;; esac
    case "$_line" in *=*) ;; *) continue ;; esac

    _key="${_line%%=*}"
    _val="${_line#*=}"
    _key="${_key//[[:space:]]/}"
    case "$_key" in [A-Za-z_]*) ;; *) continue ;; esac

    _val="${_val%\"}"; _val="${_val#\"}"                # aspas opcionais
    _val="${_val%\'}"; _val="${_val#\'}"

    [ -n "${!_key:-}" ] || export "${_key}=${_val}"
done < .env
unset _line _key _val

for var in MINIO_ROOT_USER MINIO_ROOT_PASSWORD \
           MINIO_PRESIGN_USER MINIO_PRESIGN_PASSWORD \
           MINIO_BUCKET TEST_OBJECT \
           PUBLIC_HOST PUBLIC_SCHEME NGINX_HTTP_PORT NGINX_HTTPS_PORT \
           MINIO_DIRECT_HOST MINIO_DIRECT_PORT MINIO_CONSOLE_PORT PRESIGN_EXPIRY_HOURS \
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

# O mc valida o certificado do proxy usando nginx/certs/server.crt, montado
# como CA no container (ver docker-compose.yml). É o comportamento que a
# aplicação real precisa ter — desligar a validação no componente que assina
# as URLs esconderia justamente um MITM nesse caminho.
# MC_INSECURE=1 no .env é escotilha de emergência.
if [ "${MC_INSECURE:-0}" = "1" ]; then
    MC_TLS_FLAG="--insecure"
    warn "MC_INSECURE=1: validação do certificado desligada no mc"
else
    MC_TLS_FLAG=""
fi
export MC_TLS_FLAG

# Trechos de shell que registram os dois aliases. São strings passadas a
# `sh -c` DENTRO do container: as aspas e os $ das variáveis do container
# precisam sobreviver literais até lá, por isso o escape. Os avisos
# SC2016/SC2089/SC2090 apontam exatamente o comportamento desejado.
#
# lab   = administrador, direto no MinIO. Cria bucket, sobe arquivo, cria usuário.
# proxy = usuário dedicado somente-leitura, através do proxy. SÓ assina URLs.
#         O access key deste alias fica visível no X-Amz-Credential da URL.
# shellcheck disable=SC2016,SC2089
MC_ALIAS_ADMIN='mc --no-color alias set lab https://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null'
# shellcheck disable=SC2089
MC_ALIAS_PROXY="mc --no-color $MC_TLS_FLAG alias set proxy \"\$PUBLIC_SCHEME://\$PUBLIC_HOST:\$NGINX_HTTPS_PORT\" \"\$MINIO_PRESIGN_USER\" \"\$MINIO_PRESIGN_PASSWORD\" >/dev/null"
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
