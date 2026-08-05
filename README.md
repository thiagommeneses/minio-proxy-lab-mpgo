# MinIO Proxy Lab MPGO

Laboratório que simula o acesso a vídeos armazenados no **MinIO** através de um
**proxy reverso NGINX**, usando **URL pré-assinada**, sem expor o MinIO ao usuário final.

> Contexto completo, decisões e histórico do projeto estão em [`CLAUDE.md`](./CLAUDE.md).

---

## Objetivo

Validar, de forma simples e reproduzível, o seguinte fluxo:

1. o vídeo é enviado para o MinIO;
2. o MinIO gera uma URL pré-assinada **já com o hostname do proxy**;
3. o acesso ao vídeo ocorre pelo proxy reverso, com o certificado do proxy;
4. o usuário final nunca alcança o MinIO diretamente.

```text
[cliente] --HTTPS--> [NGINX :8443]  --HTTP--> [MinIO :9000]
              ^                                    ^
     certificado do proxy              rede interna do compose,
     hostname público                  sem porta publicada no host
```

---

## Ponto crítico antes de começar

A assinatura SigV4 de uma URL pré-assinada **inclui o header `Host`**. Portanto:

- a URL precisa ser **gerada** com o endpoint do proxy — trocar o host depois de
  assinada resulta em `SignatureDoesNotMatch`;
- o NGINX precisa **repassar o `Host` original** (`proxy_set_header Host $http_host;`);
- o proxy deve fazer encaminhamento puro, **sem reescrever o path**.

No laboratório isso é resolvido com a variável `MINIO_SERVER_URL` no container do MinIO.

---

## Tecnologias

- Docker e Docker Compose
- MinIO (servidor S3)
- MinIO Client (`mc`) para bucket, upload e geração de URL
- NGINX como proxy reverso
- Bash para os scripts auxiliares
- OpenSSL para o certificado autoassinado

---

## Pré-requisitos

- Docker instalado e em execução;
- Docker Compose v2 (`docker compose`, sem hífen);
- acesso ao terminal (no Windows, recomenda-se WSL2);
- um vídeo de teste em `assets/video-teste.mp4`;
- OpenSSL disponível (para gerar o certificado).

### Hostname de teste

Adicione ao arquivo de hosts da máquina:

```text
127.0.0.1  videos.lab.local
```

- **Linux/WSL:** `/etc/hosts`
- **Windows:** `C:\Windows\System32\drivers\etc\hosts` (abrir como administrador)

---

## Estrutura do repositório

```text
minio-proxy-lab-mpgo/
├── README.md
├── CLAUDE.md
├── docker-compose.yml
├── .env.example
├── .env                       # local, não versionar
├── .gitignore
├── nginx/
│   ├── nginx.conf             # config única: server HTTP + server HTTPS
│   └── certs/                 # gerado por scripts/00
├── scripts/
│   ├── lib/common.sh
│   ├── 00-setup-certs.sh
│   ├── 01-create-bucket.sh
│   ├── 02-upload-test-video.sh
│   ├── 03-generate-presigned-url.sh
│   └── 04-test-access.sh
├── assets/
│   └── video-teste.mp4        # baixado por scripts/02
└── notes/
    ├── contexto.md
    ├── decisoes.md
    ├── execucao.md
    └── resultados.md
```

---

## Como executar

### 1. Configurar as variáveis de ambiente

```bash
cp .env.example .env
```

Conteúdo esperado:

```env
# Credenciais do MinIO
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin123

# Bucket e objeto de teste
MINIO_BUCKET=videos
TEST_OBJECT=video-teste.mp4

# Hostname público do proxy (usado para assinar as URLs)
PUBLIC_HOST=videos.lab.local
PUBLIC_SCHEME=https

# Portas do NGINX (iguais dentro e fora do container — ver nota abaixo)
NGINX_HTTP_PORT=8080
NGINX_HTTPS_PORT=8443

# Expiração padrão da URL pré-assinada
PRESIGN_EXPIRY=1h

# Vídeo de teste, baixado pelo script 02 se assets/video-teste.mp4 não existir
TEST_VIDEO_URL=https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4
```

> Altere as credenciais antes de qualquer uso fora do laboratório.
> O `.env` não deve ser versionado.

**Sobre as portas:** o NGINX escuta nas mesmas portas dentro e fora do container.
Isso é proposital — a porta faz parte do header `Host` e, portanto, da assinatura.
Se o container escutasse `443` e o host publicasse `8443`, o `mc` (que assina de
dentro da rede) e o navegador (que acessa de fora) usariam hosts diferentes e a
assinatura quebraria.

As portas aparecem em dois lugares: no `.env` e no `listen` de `nginx/nginx.conf`.
**Alterar uma delas exige alterar a outra.** Os scripts comparam os dois arquivos
e abortam com mensagem explícita se divergirem — o mesmo vale para
`PUBLIC_HOST` e `server_name`.

### 2. Gerar o certificado autoassinado

```bash
bash scripts/00-setup-certs.sh
```

Gera `nginx/certs/server.crt` e `nginx/certs/server.key` para `videos.lab.local`.

### 3. Subir os serviços

```bash
docker compose up -d
```

Sobem dois serviços: `minio` (sem portas publicadas) e `nginx` (portas `8080` e `8443`).

### 4. Verificar se os serviços subiram

```bash
docker compose ps
docker compose logs -f
```

Ambos devem aparecer como `running`. O MinIO leva alguns segundos até o healthcheck passar.

### 5. Criar o bucket

```bash
bash scripts/01-create-bucket.sh
```

Cria o bucket definido em `MINIO_BUCKET` (padrão: `videos`), privado.

### 6. Enviar o vídeo de teste

```bash
bash scripts/02-upload-test-video.sh
```

Se `assets/video-teste.mp4` não existir, baixa o arquivo de `TEST_VIDEO_URL`
(Big Buck Bunny, CC-BY Blender Foundation) e então envia para o bucket.
Para usar um vídeo próprio, basta colocá-lo nesse caminho antes de rodar.

### 7. Gerar a URL pré-assinada

```bash
bash scripts/03-generate-presigned-url.sh
```

A saída deve ser uma URL parecida com:

```text
https://videos.lab.local:8443/videos/video-teste.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=...&X-Amz-Expires=3600&X-Amz-Signature=...
```

Confirme que o host é o do **proxy** e não o do MinIO. Esse é o ponto principal da PoC.

### 8. Testar o acesso pelo proxy

```bash
bash scripts/04-test-access.sh
```

O script roda cinco verificações e imprime um placar no final: proxy no ar,
MinIO inacessível pelo host, geração da URL, acesso ao objeto e `Range`.
Sai com código diferente de zero se alguma falhar.

Ou manualmente:

```bash
URL="$(bash scripts/03-generate-presigned-url.sh)"

# cabeçalhos da resposta
curl -k -I "$URL"

# teste de Range (seek do player)
curl -k -r 0-1023 -o /dev/null -w '%{http_code}\n' "$URL"
```

E abra a URL no navegador para reproduzir o vídeo.

### 9. Testar a expiração

```bash
PRESIGN_EXPIRY=30s bash scripts/03-generate-presigned-url.sh
# aguarde 35s e repita o curl — esperado: 403
```

> **Escopo desta versão:** o console do MinIO ainda não é exposto pelo proxy.
> Bucket e upload são feitos pelos scripts. Ver decisão 14 no `CLAUDE.md`.

---

## Como validar se deu certo

| Verificação | Como testar | Resultado esperado |
|---|---|---|
| Vídeo reproduz | abrir a URL no navegador | vídeo toca sem erro |
| Acesso pelo proxy | ver a barra de endereço / `curl -I` | host `videos.lab.local:8443` |
| MinIO não exposto | `curl http://localhost:9000` | conexão recusada |
| Certificado do proxy | inspecionar o cadeado no navegador | certificado de `videos.lab.local` |
| Seek funciona | `curl -k -r 0-1023 ... -w '%{http_code}'` | `206` |
| URL expira | aguardar `PRESIGN_EXPIRY` e repetir | `403` |
| Reprodutível | `docker compose down -v` e refazer tudo | mesmo resultado |

---

## Problemas comuns

### `SignatureDoesNotMatch`

Causa mais provável: o `Host` visto pelo MinIO é diferente do usado na assinatura.

- confirme `proxy_set_header Host $http_host;` em `nginx/nginx.conf`;
- confirme que `NGINX_HTTPS_PORT` no `.env` é igual ao `listen ... ssl` do `nginx.conf`;
- confirme que `MINIO_SERVER_URL` inclui esquema, host **e porta** (`https://videos.lab.local:8443`);
- confirme que o NGINX não está reescrevendo o path.

### `403 Forbidden` logo após gerar a URL

- relógio do container fora de sincronia com o host;
- credenciais do `mc` diferentes das do `.env`;
- URL já expirada (verifique `PRESIGN_EXPIRY`).

### Container não sobe

- portas `8080`/`8443` ocupadas — ajuste no `.env`;
- Docker parado;
- `.env` ausente ou com variável faltando.

### Bucket não encontrado

Confirme se o bucket foi criado e se o nome bate entre `.env`, scripts e a URL.

### Vídeo trava ou não permite seek

- `proxy_buffering off;` em `nginx/nginx.conf`;
- confirme que a resposta é `206` (`bash scripts/04-test-access.sh` já testa isso);
- o `log_format lab` do NGINX registra `range=` e `status=` em cada requisição:
  `docker compose logs -f nginx`.

### Aviso de certificado no navegador

Esperado com certificado autoassinado. Aceite a exceção ou instale o certificado
como confiável na máquina. Em `curl`, use `-k`.

### `413 Request Entity Too Large` no upload

Já tratado com `client_max_body_size 0;` no snippet — só relevante se o upload
também passar pelo proxy.

### `videos.lab.local` não resolve

Falta a entrada no arquivo de hosts (ver Pré-requisitos). Os scripts que dependem
disso falham com a instrução na mensagem de erro.

### NGINX não sobe: certificado ausente

Rode `scripts/00-setup-certs.sh` antes do `docker compose up -d`. Sem os arquivos
em `nginx/certs/`, o server block HTTPS falha ao carregar.

---

## Reiniciar do zero

```bash
docker compose down -v          # remove containers e o volume do MinIO
rm -rf nginx/certs assets/video-teste.mp4

bash scripts/00-setup-certs.sh
docker compose up -d
bash scripts/01-create-bucket.sh
bash scripts/02-upload-test-video.sh
bash scripts/04-test-access.sh
```

Reproduzir esse ciclo do zero e obter o mesmo resultado é um dos critérios de sucesso.

---

## Próximos passos

- adicionar hostname e certificado de um ambiente de teste real;
- automatizar a validação em um único script de ponta a ponta;
- medir a latência adicional introduzida pelo proxy;
- documentar as evidências em `notes/resultados.md`;
- levantar os ajustes de firewall necessários em produção.

---

## Observação

Este laboratório é uma **prova de conceito**. O foco é validar o caminho de acesso
e a redução da exposição da infraestrutura — não performance extrema nem alta disponibilidade.
