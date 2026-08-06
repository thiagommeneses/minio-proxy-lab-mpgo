# Resultados e evidências

Primeira execução completa: **05/08/2026**, ambiente WSL2 + Docker Desktop.
MinIO `RELEASE.2025-09-07T16-13-09Z`, `nginx:alpine`.

## Placar dos critérios de sucesso

| # | Critério | Status | Evidência |
|---|---|---|---|
Segunda execução: **05/08/2026, 21:18** — placar `8 passaram, 0 falharam`.

| # | Critério | Status | Evidência |
|---|---|---|---|
| 1 | Vídeo abre e reproduz | **parcial** | MP4 real, `content-type: video/mp4`, íntegro; reprodução em player ainda não confirmada |
| 2 | Acesso exclusivo pelo proxy | **OK** | log do NGINX registra `GET /videos/video-teste.mp4 ... upstream=206` |
| 3 | MinIO não exposto diretamente | **OK** | `docker compose port minio 9000` → `invalid IP:0`; `curl 127.0.0.1:9000` → `000` |
| 4 | Certificado apresentado é o do proxy | **OK** | `CN=videos.lab.local`, SAN correta |
| 5 | URL expira e retorna 403 | **OK** | URL de 30s → `403` após 35s |
| 6 | Seek funciona (206 Partial Content) | **OK** | `Content-Range: bytes 0-1023/64657027` |
| 7 | Reprodutível do zero | **parcial** | `down -v` executado; falta a subida limpa |
| 8 | Documentado | **OK** | este arquivo, `decisoes.md` e `CLAUDE.md` |

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

## Segunda execução — 05/08/2026

```text
==> o download é um ZIP; extraindo o MP4
==> extraído: BigBuckBunny_320x180.mp4
 OK MP4 válido: assets/video-teste.mp4 (62M)

  PASS NGINX no ar (HTTPS)                    (200)
  PASS MinIO sem porta publicada              (000)
  OK   URL assinada com o host do proxy (videos.lab.local:8443)
  PASS GET do objeto                          (200)
       content-type: video/mp4   bytes: 64657027
  PASS conteúdo íntegro (byte a byte)         (identico)
  PASS 206 Partial Content                    (206)
  PASS 1024 bytes no range pedido             (1024)
       content-range: bytes 0-1023/64657027
  PASS sem query string -> 403                (403)
  PASS assinatura adulterada -> 403           (403)

  RESULTADO: 8 passaram, 0 falharam
```

Expiração, verificada em seguida:

```text
$ CURTA="$(PRESIGN_EXPIRY=30s bash scripts/03-generate-presigned-url.sh)"
==> gerando URL pré-assinada (expira em 30s) via https://videos.lab.local:8443
$ sleep 35 && curl -sk -o /dev/null -w '%{http_code}\n' "$CURTA"
403
```

O `content-type: video/mp4` e o tamanho `64657027` (contra `64657225` do ZIP
anterior) confirmam que agora o objeto é o MP4 de verdade.

## Endurecimento aplicado em 06/08/2026

Revisão de proxy, certificado, expiração e Host header. Nenhum dos itens abaixo
tinha causado falha ainda; são riscos identificados e fechados.

| Item | Problema | Correção |
|---|---|---|
| E6 | o access key de quem assina fica visível no `X-Amz-Credential`, e era o root | usuário dedicado com apenas `s3:GetObject` no bucket, criado por `scripts/01` |
| E3 | expiração de 1h podia acabar no meio de uma sessão | 24h, cobrindo a sessão com pausas |
| P2 | HSTS de um ano vindo do MinIO; HSTS ignora a porta e inutilizaria a 8080 | header descartado e política assumida pelo proxy, `max-age=0` no lab |
| P4 | `client_max_body_size 0` valia para todas as rotas | 1m no padrão, 5g explícito na rota do S3 |
| P5 | sem proteção contra abuso | `limit_conn` por IP; `limit_req` e `limit_rate` descartados por quebrarem seek |
| P6 | a checagem `.env` × `nginx.conf` não rodava no `docker compose up` | `scripts/up.sh` |
| C2 | o `mc` assinava com `--insecure` | certificado do proxy montado como CA no container |
| H3 | não havia teste contra redirect vazando o endpoint interno | grupo 7 do placar |
| P1 | NGINX congela o IP do upstream; MinIO recriado → `502` | documentado no README (`docker compose restart nginx`) |

## Pendências

- **A.** ~~Vídeo é ZIP.~~ Resolvido: MP4 real, verificado pelo box `ftyp`.
- **B.** ~~Testar expiração.~~ Resolvido: `403` confirmado, agora automatizado
  no grupo 8 do placar.
- **C.** Confirmar o seek em player real e capturar print do vídeo reproduzindo
  com a URL do proxy na barra de endereço. **Único item que separa o critério 1.**
- **D.** Subida limpa após o `docker compose down -v` já executado, para fechar
  o critério 7.

## Observações para o ambiente real

- O `Host` assinado precisa incluir a porta quando ela não for a padrão do
  esquema. Em produção, com `443`, o `Host` fica sem porta e o problema
  desaparece — mas `MINIO_SERVER_URL` tem que refletir isso exatamente.
- O log do NGINX com o campo `host=` foi decisivo para o diagnóstico e vale
  manter em produção, ao menos durante a implantação.
- Nenhum header de resposta vazou o endpoint interno (`grep -i 'minio:9000\|location:'`
  não retornou nada), e não houve redirect.
