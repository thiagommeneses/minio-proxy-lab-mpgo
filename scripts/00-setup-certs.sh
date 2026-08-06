#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Gera a PKI do laboratório: DUAS CAs e dois certificados.
#
# Por que duas CAs
# Em produção o navegador confia no certificado do ThemísIA (curinga
# *.mpgo.mp.br, emitido pela GlobalSign) e NÃO confia no certificado do MinIO
# (emitido pela Certificadora TLS do MP-GO, interna). É essa assimetria que
# produz a falha atual, e é ela que a comparação lado a lado precisa mostrar.
# Com um autoassinado só, os dois caminhos falhariam e a demo não provaria nada.
#
#   ca-publica    -> simula a GlobalSign.  VOCÊ INSTALA no Windows.
#     └── proxy   -> intranet.lab.local, usado pelo NGINX
#
#   ca-interna    -> simula a Certificadora TLS do MP-GO. NÃO instalar.
#     └── minio   -> vm-lnx-0369.lab.local, usado pelo MinIO
#
# Idempotente: não regera se os arquivos existirem (use --force).
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CERT_DIR="nginx/certs"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

command -v openssl >/dev/null 2>&1 || die "openssl não encontrado no PATH"

if [ -f "$CERT_DIR/proxy.crt" ] && [ -f "$CERT_DIR/minio.crt" ] && [ "$FORCE" -eq 0 ]; then
    info "certificados já existem em $CERT_DIR (use --force para regerar)"
    for c in ca-publica proxy ca-interna minio; do
        printf '  %-12s ' "$c"
        openssl x509 -in "$CERT_DIR/$c.crt" -noout -subject -enddate 2>/dev/null \
            | tr '\n' ' ' | sed 's/subject=//'
        echo
    done
    exit 0
fi

mkdir -p "$CERT_DIR"

# --- helpers ---------------------------------------------------------------

make_ca() { # make_ca <arquivo> <CN>
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$CERT_DIR/$1.key" -out "$CERT_DIR/$1.crt" \
        -days 1825 -subj "/C=BR/ST=Goias/O=MPGO Lab/CN=$2" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}

make_leaf() { # make_leaf <arquivo> <CN> <SAN> <ca>
    openssl req -nodes -newkey rsa:2048 \
        -keyout "$CERT_DIR/$1.key" -out "$CERT_DIR/$1.csr" \
        -subj "/C=BR/ST=Goias/O=MPGO Lab/CN=$2" 2>/dev/null

    openssl x509 -req -in "$CERT_DIR/$1.csr" \
        -CA "$CERT_DIR/$4.crt" -CAkey "$CERT_DIR/$4.key" -CAcreateserial \
        -out "$CERT_DIR/$1.crt" -days 825 \
        -extfile <(printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$3") \
        2>/dev/null

    rm -f "$CERT_DIR/$1.csr"
}

# --- CA "pública" e certificado do proxy -----------------------------------
#
# Se o mkcert estiver disponível, ele é preferido para ESTA metade: instala a CA
# nos truststores automaticamente, incluindo o do Firefox, que é separado do
# Windows e não é alcançado por Import-Certificate.
#
# Pegadinha do WSL: `mkcert -install` rodado dentro do WSL instala no truststore
# do Linux, não no do Windows, e o navegador é o do Windows. Para o auto-install
# valer, o mkcert precisa rodar NO WINDOWS (mkcert.exe). O script detecta os dois
# casos e avisa.
#
# A outra metade (ca-interna + cert do MinIO) nunca usa mkcert: ela precisa
# continuar NÃO confiável, e o mkcert só sabe emitir certificados confiáveis.

MKCERT_BIN=""
if [ "${USE_MKCERT:-auto}" != "0" ]; then
    for cand in mkcert mkcert.exe; do
        command -v "$cand" >/dev/null 2>&1 && { MKCERT_BIN="$cand"; break; }
    done
fi

if [ -n "$MKCERT_BIN" ]; then
    info "mkcert encontrado ($MKCERT_BIN): emitindo o certificado do proxy"

    CAROOT="$("$MKCERT_BIN" -CAROOT 2>/dev/null || true)"
    [ -n "$CAROOT" ] || die "mkcert não respondeu a -CAROOT. Use USE_MKCERT=0 para forçar openssl."

    # Caminho do Windows (C:\...) indica mkcert.exe, cuja CA vale para o
    # navegador do host. Caminho POSIX indica mkcert do WSL, que instala no
    # truststore errado para este laboratório.
    #
    # O mkcert.exe devolve o CAROOT em formato Windows, que o WSL não abre
    # diretamente — precisa passar por wslpath.
    case "$CAROOT" in
        [A-Za-z]:\\*|[A-Za-z]:/*)
            MKCERT_NO_HOST=0
            if command -v wslpath >/dev/null 2>&1; then
                CAROOT="$(wslpath -u "$CAROOT")"
            else
                die "mkcert devolveu um caminho Windows ($CAROOT) mas 'wslpath' não existe
     para convertê-lo. Rode o script no WSL, ou use USE_MKCERT=0 para o openssl."
            fi
            ;;
        *) MKCERT_NO_HOST=1 ;;
    esac

    [ -f "$CAROOT/rootCA.pem" ] \
        || die "não encontrei $CAROOT/rootCA.pem. Rode '$MKCERT_BIN -install' primeiro."

    "$MKCERT_BIN" -cert-file "$CERT_DIR/proxy.crt" -key-file "$CERT_DIR/proxy.key" \
        "$PUBLIC_HOST" localhost 127.0.0.1 >/dev/null 2>&1 \
        || die "mkcert falhou ao emitir o certificado. Rode '$MKCERT_BIN -install' antes, ou USE_MKCERT=0."

    # A CA do mkcert assume o papel da ca-publica para o restante do laboratório.
    cp "$CAROOT/rootCA.pem" "$CERT_DIR/ca-publica.crt"
    : > "$CERT_DIR/ca-publica.key"   # a chave fica no CAROOT, fora do repositório

    ok "certificado do proxy emitido pelo mkcert (CA em $CAROOT)"
    [ "$MKCERT_NO_HOST" -eq 1 ] && warn "este mkcert roda no WSL: a CA foi instalada no truststore do Linux,
     não no do Windows. Para o navegador do host confiar, importe manualmente
     nginx/certs/ca-publica.crt (comando no fim deste script)."
else
    info "mkcert ausente: gerando ca-publica com openssl (simula GlobalSign)"
    make_ca ca-publica "Lab CA Publica (simula GlobalSign)"
    make_leaf proxy "$PUBLIC_HOST" "DNS:$PUBLIC_HOST,DNS:localhost,IP:127.0.0.1" ca-publica
fi

# --- CA interna e certificado do MinIO -------------------------------------
info "gerando ca-interna (simula Certificadora TLS do MP-GO) e o cert do MinIO"
make_ca ca-interna "Lab Certificadora TLS interna"
make_leaf minio "$MINIO_DIRECT_HOST" \
    "DNS:$MINIO_DIRECT_HOST,DNS:minio,DNS:localhost,IP:127.0.0.1" ca-interna

chmod 644 "$CERT_DIR"/*.crt
chmod 600 "$CERT_DIR"/*.key

# --- verificação das cadeias ----------------------------------------------
openssl verify -CAfile "$CERT_DIR/ca-publica.crt" "$CERT_DIR/proxy.crt" >/dev/null \
    || die "cadeia do proxy não valida contra a ca-publica"
openssl verify -CAfile "$CERT_DIR/ca-interna.crt" "$CERT_DIR/minio.crt" >/dev/null \
    || die "cadeia do MinIO não valida contra a ca-interna"
openssl verify -CAfile "$CERT_DIR/ca-publica.crt" "$CERT_DIR/minio.crt" >/dev/null 2>&1 \
    && die "o cert do MinIO validou contra a CA errada — as CAs não estão separadas"

ok "PKI gerada e cadeias conferidas"
echo
echo "  ca-publica.crt  -> confiável (simula a GlobalSign)"
echo "  proxy.crt       -> $PUBLIC_HOST         (NGINX)"
echo "  ca-interna.crt  -> NÃO instalar (simula a CA interna do MP-GO)"
echo "  minio.crt       -> $MINIO_DIRECT_HOST  (MinIO)"
echo

if [ -n "$MKCERT_BIN" ] && [ "${MKCERT_NO_HOST:-1}" -eq 0 ]; then
    echo "  Confiança já instalada pelo mkcert, inclusive no Firefox."
    echo "  Nada mais a fazer — reinicie o navegador se ele já estava aberto."
else
    echo "  Para o navegador do Windows confiar no proxy, no PowerShell como administrador:"
    echo "    Import-Certificate -FilePath .\\nginx\\certs\\ca-publica.crt \\"
    echo "      -CertStoreLocation Cert:\\LocalMachine\\Root"
    echo
    echo "  O Firefox usa truststore próprio e ignora o do Windows. Nele:"
    echo "    Configurações -> Privacidade e Segurança -> Certificados -> Ver certificados"
    echo "    -> Autoridades -> Importar -> nginx/certs/ca-publica.crt"
    echo "    -> marcar 'Confiar nesta CA para identificar sites'"
    echo
    echo "  Alternativa que faz os dois automaticamente: instalar o mkcert NO WINDOWS"
    echo "    winget install FiloSottile.mkcert   (ou: choco install mkcert)"
    echo "    mkcert -install"
    echo "    e rodar este script de novo com --force"
fi
