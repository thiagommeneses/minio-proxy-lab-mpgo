#!/usr/bin/env bash
# Gera dois certificados (duas CAs): uma confiável (proxy acesso público) e uma não confiável (MinIO acesso direto/interno).
set -e

mkdir -p certs
cd certs

# CA confiável — simula a GlobalSign usada no MPGO atualmente. [Instale esta no host (Windows)]
openssl req -x509 -nodes -newkey rsa:2048 -days 1825 \
  -keyout ca-publica.key -out ca-publica.crt -subj "/CN=CA Publica do Lab" \
  -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

# CA não confiável — simula a CA interna do MPGO; entre servidores. [NÃO instale esta]
openssl req -x509 -nodes -newkey rsa:2048 -days 1825 \
  -keyout ca-interna.key -out ca-interna.crt -subj "/CN=CA Interna do Lab" \
  -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

# Emite um certificado assinado por uma das CAs.
emitir() {  # emitir <nome> <hostname> <ca>
  openssl req -nodes -newkey rsa:2048 -keyout "$1.key" -out "$1.csr" \
    -subj "/CN=$2" 2>/dev/null
  openssl x509 -req -in "$1.csr" -CA "$3.crt" -CAkey "$3.key" -CAcreateserial \
    -out "$1.crt" -days 825 \
    -extfile <(echo "subjectAltName=DNS:$2,DNS:minio") 2>/dev/null
  rm -f "$1.csr"
}

emitir proxy "${APP_HOST:-intranet.lab.local}"    ca-publica
emitir minio "${MINIO_HOST:-vm-lnx-0369.lab.local}" ca-interna

chmod 644 ./*.crt
echo "OK. Agora instale certs/ca-publica.crt como confiável no Windows:"
echo "  Import-Certificate -FilePath .\\certs\\ca-publica.crt -CertStoreLocation Cert:\\LocalMachine\\Root"
