# Resultados e evidências

Primeira execução completa: **05/08/2026**, ambiente WSL2 + Docker Desktop.
MinIO `RELEASE.2025-09-07T16-13-09Z`, `nginx:alpine`.

## Placar dos critérios de sucesso

| # | Critério | Status | Evidência |
|---|---|---|---|
| 1 | Vídeo abre e reproduz | **parcial** | download íntegro; reprodução em player não confirmada (ver pendência A) |
| 2 | Acesso exclusivo pelo proxy | **OK** | log do NGINX registra `GET /videos/video-teste.mp4 ... upstream=206` |
| 3 | MinIO não exposto diretamente | **OK** | `docker compose port minio 9000` → `invalid IP:0`; `curl 127.0.0.1:9000` → `000` |
| 4 | Certificado apresentado é o do proxy | **OK** | `CN=videos.lab.local`, SAN correta |
| 5 | URL expira e retorna 403 | **pendente** | teste bloqueado por bug já corrigido (ver abaixo) |
| 6 | Seek funciona (206 Partial Content) | **OK** | `Content-Range: bytes 0-1023/64657225` |
| 7 | Reprodutível do zero | **parcial** | fluxo `00`→`04` rodou; falta repetir após `down -v` |
| 8 | Documentado | em andamento | este arquivo |

**A premissa central da PoC está validada:** a URL pré-assinada é gerada com o
host do proxy, atravessa o NGINX preservando o `Host`, e o MinIO aceita a
assinatura. O conteúdo chega íntegro e com suporte a `Range`.

## Evidências

### URL gerada — host do proxy, não do MinIO

```text
https://videos.lab.local:8443/videos/video-teste.mp4
  ?X-Amz-Algorithm=AWS4-HMAC-SHA256
  &X-Amz-Credential=minioadmin%2F20260805%2Fus-east-1%2Fs3%2Faws4_request
  &X-Amz-Date=20260805T202347Z
  &X-Amz-Expires=3600
  &X-Amz-SignedHeaders=host
  &X-Amz-Signature=df8ce51abf87...
```

`X-Amz-SignedHeaders=host` é a confirmação literal de que o `Host` entra na assinatura.

### MinIO se enxerga sob o hostname do proxy

```text
mpl-minio | API: https://videos.lab.local:8443
```

### Host preservado ponta a ponta (log do NGINX)

```text
172.19.0.1 [05/Aug/2026:22:21:34 +0000] "GET /videos/video-teste.mp4"
  host="videos.lab.local:8443" status=206 range="bytes=0-1023" sent=1024 upstream=206 rt=0.001
```

O `host=` do log é idêntico ao host da URL assinada — é esse par que precisa bater.

### Integridade e streaming

```text
$ cmp assets/video-teste.mp4 /tmp/baixado.mp4 && echo "byte a byte idêntico"
byte a byte idêntico

$ curl -k -s -r 0-1023 -D- -o /dev/null "$URL" | grep -iE 'HTTP/|content-range'
HTTP/1.1 206 Partial Content
Content-Range: bytes 0-1023/64657225
```

### MinIO inalcançável de fora

```text
$ docker compose port minio 9000
invalid IP:0

$ curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/
000

$ docker compose ps      # coluna PORTS do mpl-minio
9000/tcp                 # exposta na rede do compose, não publicada no host
```

### Assinatura é realmente verificada

```text
$ curl -k -s -o /dev/null -w '%{http_code}\n' "${URL%%\?*}"   # sem query string
403
$ curl -k -s -o /dev/null -w '%{http_code}\n' "${URL%?}X"     # assinatura adulterada
403
```

Descarta a hipótese de bucket público — o acesso depende mesmo da assinatura.

### Certificado

```text
subject=C=BR, ST=Goias, L=Goiania, O=MPGO, OU=Lab, CN=videos.lab.local
issuer =C=BR, ST=Goias, L=Goiania, O=MPGO, OU=Lab, CN=videos.lab.local
X509v3 Subject Alternative Name: DNS:videos.lab.local, DNS:localhost, IP:127.0.0.1
```

O navegador exibe `NET::ERR_CERT_AUTHORITY_INVALID` — esperado para autoassinado
e sem impacto no critério 4: o certificado apresentado é o do proxy.

## Bugs encontrados na primeira execução

Todos nos scripts de teste, nenhum na configuração do laboratório.

| # | Sintoma | Causa | Correção |
|---|---|---|---|
| B1 | `curl -I` → `403 SignatureDoesNotMatch`, `GET` → `206` | a assinatura SigV4 cobre o método HTTP; `mc share download` assina para `GET`, então `HEAD` nunca valida | `04-test-access.sh` passou a usar `GET`; caso documentado no README |
| B2 | `esperado=000 obtido=000000` | `curl -w '%{http_code}'` já imprime `000` em falha de conexão **e** sai não-zero, então o `\|\| echo 000` duplicava | helper `http_code()` centralizado |
| B3 | `PRESIGN_EXPIRY=30s` ignorado (gerou `X-Amz-Expires=3600`) | `set -a; . ./.env` sobrescrevia variável passada na linha de comando | `.env` carregado sem sobrescrever variáveis já definidas no ambiente |
| B4 | `grep: command not found` dentro do container `mc` | a imagem `minio/mc` não traz coreutils | parsing da URL movido para o host |
| B5 | `assets/video-teste.mp4` era um ZIP | a origem parou de distribuir o `.mp4` avulso; só publica `.zip` | `02` detecta o formato pelo conteúdo, extrai o MP4 do zip e recusa upload sem o box `ftyp` |

## Pendências

- **A.** ~~Confirmar que o vídeo é MP4 e não ZIP.~~ **Confirmado: era um ZIP.**
  A origem não distribui mais o `.mp4` avulso. O script `02` foi corrigido
  (B5); falta reexecutar para gerar o MP4 de verdade e refazer o upload:
  `rm assets/video-teste.mp4 && bash scripts/02-upload-test-video.sh`
- **B.** Rodar o teste de expiração agora que B3 está corrigido.
- **C.** Confirmar o seek em player real e capturar print do vídeo reproduzindo
  com a URL do proxy na barra de endereço.
- **D.** Repetir o ciclo após `docker compose down -v` para fechar o critério 7.

## Observações para o ambiente real

- O `Host` assinado precisa incluir a porta quando ela não for a padrão do
  esquema. Em produção, com `443`, o `Host` fica sem porta e o problema
  desaparece — mas `MINIO_SERVER_URL` tem que refletir isso exatamente.
- O log do NGINX com o campo `host=` foi decisivo para o diagnóstico e vale
  manter em produção, ao menos durante a implantação.
- Nenhum header de resposta vazou o endpoint interno (`grep -i 'minio:9000\|location:'`
  não retornou nada), e não houve redirect.
