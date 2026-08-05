#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cria o bucket de teste, privado. Idempotente.
# Usa o alias administrativo (direto no MinIO), não o proxy — criar bucket é
# tarefa de infraestrutura, não faz parte do fluxo que está sendo validado.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

need_docker

info "criando bucket '$MINIO_BUCKET'"

mc_run "
set -e
$MC_ALIAS_ADMIN
mc --no-color mb --ignore-existing lab/\"\$MINIO_BUCKET\"
mc --no-color anonymous set none lab/\"\$MINIO_BUCKET\" >/dev/null
echo '--- buckets ---'
mc --no-color ls lab/
"

ok "bucket '$MINIO_BUCKET' pronto e sem acesso anônimo"
