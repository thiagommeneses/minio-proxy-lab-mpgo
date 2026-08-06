#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Prepara o vídeo de teste e envia para o bucket.
#
# TEST_VIDEO_URL pode apontar tanto para um .mp4 quanto para um .zip contendo
# o .mp4 — a origem usada no laboratório (Blender / Big Buck Bunny) só
# distribui a versão compactada. O script detecta o formato pelo conteúdo,
# não pela extensão, extrai quando necessário e recusa seguir se o resultado
# final não for um MP4 de verdade.
#
# O download roda no host; o upload roda no container mc.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

need_docker

VIDEO="assets/video-teste.mp4"
TMP_DL="assets/.download.tmp"

# --- helpers ---------------------------------------------------------------

# Um MP4 tem o box 'ftyp' nos bytes 4..7. Verificar o conteúdo evita o caso
# silencioso de um ZIP renomeado para .mp4, que trafega íntegro pelo proxy
# mas não abre em player nenhum.
# Nada de $( ) aqui: capturar bytes de arquivo binário faz o bash reclamar de
# null bytes. Um pipe para grep evita o ruído e o resultado é o mesmo.
is_mp4() {
    [ -f "$1" ] || return 1
    head -c 12 "$1" 2>/dev/null | grep -qa 'ftyp'
}

is_zip() {
    [ -f "$1" ] || return 1
    head -c 2 "$1" 2>/dev/null | grep -qa 'PK'
}

# Extrai o maior .mp4 de dentro do zip. Usa unzip se existir, senão python3.
extract_mp4_from_zip() {
    local zip="$1" dest="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$zip" "$dest" <<'PY'
import shutil, sys, zipfile

zip_path, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path) as z:
    cands = [
        i for i in z.infolist()
        if i.filename.lower().endswith(".mp4")
        and not i.filename.startswith("__MACOSX")
        and not i.is_dir()
    ]
    if not cands:
        sys.exit("nenhum arquivo .mp4 encontrado dentro do zip")
    best = max(cands, key=lambda i: i.file_size)
    with z.open(best) as src, open(dest, "wb") as out:
        shutil.copyfileobj(src, out)
    print(best.filename)
PY
        return $?
    fi

    if command -v unzip >/dev/null 2>&1; then
        local tmpdir
        tmpdir="$(mktemp -d)"
        unzip -o -q -j "$zip" '*.mp4' -d "$tmpdir" || { rm -rf "$tmpdir"; return 1; }
        local found
        found="$(find "$tmpdir" -type f -name '*.mp4' -printf '%s %p\n' \
                 | sort -rn | head -1 | cut -d' ' -f2-)"
        [ -n "$found" ] || { rm -rf "$tmpdir"; return 1; }
        mv "$found" "$dest"
        rm -rf "$tmpdir"
        return 0
    fi

    die "nem python3 nem unzip disponíveis para extrair o .zip.
     Instale um dos dois, ou coloque um MP4 manualmente em $VIDEO"
}

# --- preparação do arquivo -------------------------------------------------

if [ ! -f "$VIDEO" ]; then
    [ -n "${TEST_VIDEO_URL:-}" ] || die "TEST_VIDEO_URL não definido no .env e $VIDEO não existe"
    command -v curl >/dev/null 2>&1 || die "curl não encontrado no PATH"

    mkdir -p assets
    info "baixando de $TEST_VIDEO_URL"
    if ! curl -fL --progress-bar -o "$TMP_DL" "$TEST_VIDEO_URL"; then
        rm -f "$TMP_DL"
        die "falha ao baixar. Ajuste TEST_VIDEO_URL no .env ou coloque um MP4 em $VIDEO"
    fi

    if is_zip "$TMP_DL"; then
        info "o download é um ZIP; extraindo o MP4"
        INNER="$(extract_mp4_from_zip "$TMP_DL" "$VIDEO")" \
            || { rm -f "$TMP_DL" "$VIDEO"; die "não foi possível extrair o MP4 do zip"; }
        [ -n "$INNER" ] && info "extraído: $INNER"
        rm -f "$TMP_DL"
    else
        mv "$TMP_DL" "$VIDEO"
    fi
    ok "vídeo preparado"
fi

# --- validação: precisa ser um MP4 de verdade ------------------------------

if ! is_mp4 "$VIDEO"; then
    if is_zip "$VIDEO"; then
        die "$VIDEO é um ZIP, não um MP4.
     Apague o arquivo e rode este script de novo para que a extração aconteça:
       rm $VIDEO && bash scripts/02-upload-test-video.sh"
    fi
    die "$VIDEO não parece um MP4 (box 'ftyp' ausente nos bytes 4..7).
     Verifique o arquivo ou substitua por um MP4 válido."
fi

SIZE_H="$(du -h "$VIDEO" | cut -f1)"
ok "MP4 válido: $VIDEO ($SIZE_H)"

# --- upload ----------------------------------------------------------------

info "enviando como '$TEST_OBJECT'"

mc_run "
set -e
$MC_ALIAS_ADMIN
mc --no-color cp /assets/video-teste.mp4 lab/\"\$MINIO_BUCKET\"/\"\$TEST_OBJECT\"
echo '--- objeto ---'
mc --no-color ls lab/\"\$MINIO_BUCKET\"/\"\$TEST_OBJECT\"
"

ok "upload concluído"
