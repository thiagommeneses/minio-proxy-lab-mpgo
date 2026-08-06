#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cria o bucket de teste e o usuário dedicado que assina as URLs.
# Idempotente: pode rodar quantas vezes quiser.
#
# Usa o alias administrativo (direto no MinIO), não o proxy — criar bucket e
# usuário é tarefa de infraestrutura, não faz parte do fluxo em validação.
#
# Sobre o usuário de presign: o access key de quem assina aparece na URL, no
# parâmetro X-Amz-Credential. Assinar com o root exporia o administrador do
# storage em todo link de vídeo distribuído. Este usuário tem uma permissão
# só — s3:GetObject no bucket — então o que vaza na URL não lista, não grava
# e não apaga nada.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

need_docker

# --- policy: somente leitura de objetos, escopada ao bucket ----------------
# Gerada no host e montada em /policies no container, porque a imagem
# minio/mc não traz ferramentas para montar o arquivo lá dentro.
mkdir -p policies
POLICY_FILE="policies/presign-readonly.json"

cat > "$POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::${MINIO_BUCKET}/*"]
    }
  ]
}
JSON

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

info "criando usuário de presign '$MINIO_PRESIGN_USER' (somente s3:GetObject)"

mc_run "
set -e
$MC_ALIAS_ADMIN

# mc admin user add falha se o usuário já existe; o '|| true' mantém idempotente
mc --no-color admin user add lab \"\$MINIO_PRESIGN_USER\" \"\$MINIO_PRESIGN_PASSWORD\" >/dev/null 2>&1 || true

mc --no-color admin policy create lab presign-readonly /policies/presign-readonly.json >/dev/null 2>&1 || true
mc --no-color admin policy attach lab presign-readonly --user \"\$MINIO_PRESIGN_USER\" >/dev/null 2>&1 || true

echo '--- usuário ---'
mc --no-color admin user info lab \"\$MINIO_PRESIGN_USER\"
"

ok "usuário '$MINIO_PRESIGN_USER' pronto"
