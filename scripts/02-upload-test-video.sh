#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Baixa o vídeo de teste (se ainda não existir) e envia para o bucket.
# O download é feito no host; o upload roda no container mc.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

need_docker

VIDEO="assets/video-teste.mp4"

if [ ! -f "$VIDEO" ]; then
    [ -n "${TEST_VIDEO_URL:-}" ] || die "TEST_VIDEO_URL não definido no .env e $VIDEO não existe"
    command -v curl >/dev/null 2>&1 || die "curl não encontrado no PATH"

    mkdir -p assets
    info "baixando vídeo de teste de $TEST_VIDEO_URL"
    if ! curl -fL --progress-bar -o "$VIDEO.part" "$TEST_VIDEO_URL"; then
        rm -f "$VIDEO.part"
        die "falha ao baixar o vídeo. Baixe manualmente para $VIDEO ou ajuste TEST_VIDEO_URL no .env"
    fi
    mv "$VIDEO.part" "$VIDEO"
    ok "vídeo baixado"
fi

SIZE_H="$(du -h "$VIDEO" | cut -f1)"
info "enviando $VIDEO ($SIZE_H) como '$TEST_OBJECT'"

mc_run "
set -e
$MC_ALIAS_ADMIN
mc --no-color cp /assets/video-teste.mp4 lab/\"\$MINIO_BUCKET\"/\"\$TEST_OBJECT\"
echo '--- objeto ---'
mc --no-color ls lab/\"\$MINIO_BUCKET\"/\"\$TEST_OBJECT\"
"

ok "upload concluído"
