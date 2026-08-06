# MinIO Proxy Lab MPGO

Laboratório que simula o acesso a vídeos armazenados no **MinIO** através de um
**proxy reverso NGINX**, usando **URL pré-assinada**, sem expor o MinIO ao usuário final.

> Contexto completo, decisões e histórico do projeto estão em [`CLAUDE.md`](./CLAUDE.md).

---

## Objetivo

Validar, de forma simples e reproduzível, o seguinte fluxo:

1. o vídeo é enviado para o MinIO;
2. a aplicação gera uma URL pré-assinada **já com o hostname público do proxy**;
3. o acesso ao vídeo ocorre pelo proxy reverso, com o certificado do proxy;
4. o usuário final nunca alcança o MinIO diretamente.

```text
                    intranet.lab.local:8443
                  ┌──────────────────────────┐
[navegador] ──────┤ /themisia/  -> app       │
                  │ /memoriais/ -> MinIO     ├──HTTPS──> [MinIO :9000]
                  └──────────────────────────┘            vm-lnx-0369.lab.local
                    certificado da ca-publica              cert da ca-interna
                    (confiável no navegador)               (NÃO confiável)
```

Aplicação e mídia no **mesmo host**, separadas por caminho. O primeiro segmento
do caminho de mídia é o **nome do bucket** — a assinatura SigV4 cobre o caminho,
então o proxy não pode reescrevê-lo.

## A aplicação de simulação

`https://intranet.lab.local:8443/themisia/` sobe um ThemísIA mínimo (FastAPI +
HTMX) com duas abas. A aba **MemorIAis** mostra dois players lado a lado:

| Player | Aponta para | Resultado esperado |
|---|---|---|
| Caminho atual | `vm-lnx-0369.lab.local:9000` | falha — certificado não confiável |
| Caminho proposto | `intranet.lab.local:8443/memoriais/` | vídeo reproduz |

Isso existe porque **erro de certificado dentro de um `<video>` falha em
silêncio**: não há "Avançado → prosseguir" como na navegação de topo, o player
simplesmente não toca. É o que torna o problema difícil de diagnosticar e o que
nenhum teste com `curl -k` detecta.

Para o player quebrado ser alcançável, o MinIO precisa estar exposto — que é o
estado atual de produção e justamente o que a PoC quer eliminar. Por isso fica
sob profile:

```bash
docker compose --profile demo up -d      # liga o caminho quebrado
docker compose --profile demo down       # desliga
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
- FastAPI + HTMX para a aplicação de simulação
- OpenSSL para a PKI do laboratório

---

## Pré-requisitos

- Docker instalado e em execução;
- Docker Compose v2 (`docker compose`, sem hífen);
- acesso ao terminal (no Windows, recomenda-se WSL2);
- OpenSSL disponível (para gerar a PKI).

### Hostnames de teste

Adicione ao arquivo de hosts da máquina **as duas entradas**:

```text
127.0.0.1  intranet.lab.local
127.0.0.1  vm-lnx-0369.lab.local
```

- **Linux/WSL:** `/etc/hosts`
- **Windows:** `C:\Windows\System32\drivers\etc\hosts` (abrir como administrador)

`intranet.lab.local` simula `intranet.mpgo.mp.br` (aplicação + mídia).
`vm-lnx-0369.lab.local` simula o servidor MinIO, usado na demonstração do
caminho quebrado.

### Confiar na CA "pública" do laboratório

O laboratório gera **duas** CAs, para reproduzir a assimetria de produção: o
navegador confia no certificado da aplicação (curinga `*.mpgo.mp.br`, GlobalSign)
e não confia no do MinIO (Certificadora TLS do MP-GO, interna).

Depois de rodar `scripts/00-setup-certs.sh`, é preciso confiar **apenas** na
`ca-publica.crt`. A `ca-interna.crt` tem que continuar não confiável — é ela
que reproduz a falha atual.

**Opção recomendada — `mkcert` no Windows.** O script detecta e usa
automaticamente, e o `mkcert` instala a CA em todos os truststores, inclusive o
do Firefox:

```powershell
winget install FiloSottile.mkcert     # ou: choco install mkcert
mkcert -install
```

Depois rode `bash scripts/00-setup-certs.sh --force`. Nada mais a fazer.

> O `mkcert` precisa estar instalado **no Windows**, não no WSL. Rodado dentro
> do WSL, ele instala a CA no truststore do Linux, e o navegador é o do Windows.
> O script detecta esse caso e avisa. Para forçar o openssl: `USE_MKCERT=0`.

**Sem `mkcert`** — o script gera a CA com openssl e você instala manualmente:

```powershell
# PowerShell como administrador, na pasta do projeto
Import-Certificate -FilePath .\nginx\certs\ca-publica.crt `
  -CertStoreLocation Cert:\LocalMachine\Root
```

Isso cobre Chrome e Edge. O **Firefox usa truststore próprio** e ignora o do
Windows: Configurações → Privacidade e Segurança → Certificados → Ver
certificados → Autoridades → Importar → `nginx/certs/ca-publica.crt`, marcando
"Confiar nesta CA para identificar sites".

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
├── app/                       # ThemísIA/MemorIAis simulado (FastAPI + HTMX)
│   ├── main.py
│   ├── requirements.txt
│   └── Dockerfile
├── nginx/
│   ├── nginx.conf             # server HTTP + HTTPS, roteamento por caminho
│   ├── conf.d/
│   │   └── minio-proxy.inc    # regras de proxy para o MinIO
│   └── certs/                 # 2 CAs + 2 certificados, gerados por scripts/00
├── policies/
│   └── presign-readonly.json  # gerada por scripts/01
├── scripts/
│   ├── lib/common.sh
│   ├── up.sh                  # sobe validando .env x nginx.conf
│   ├── 00-setup-certs.sh
│   ├── 01-create-bucket.sh
│   ├── 02-upload-test-video.sh
│   ├── 03-generate-presigned-url.sh
│   └── 04-test-access.sh
├── assets/
│   └── video-teste.mp4        # baixado por scripts/02
└── notes/
    ├── contexto.md  decisoes.md  execucao.md
    ├── resultados.md
    └── producao.md            # migração para o ambiente real
```

---

## Como executar

### 1. Configurar as variáveis de ambiente

```bash
cp .env.example .env
```

O `.env.example` vem comentado, explicando cada escolha. Os valores que mais
importam:

```env
PUBLIC_HOST=intranet.lab.local        # simula intranet.mpgo.mp.br
MINIO_DIRECT_HOST=vm-lnx-0369.lab.local
MINIO_BUCKET=memoriais                # = primeiro segmento do caminho da mídia
TEST_OBJECT=019fb8eb-.../DEPOIMENTO/019fb8eb-....mp4
PRESIGN_EXPIRY=24h
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

### 2. Gerar os certificados

```bash
bash scripts/00-setup-certs.sh
```

Gera as duas CAs e os dois certificados. Depois disso, instale a
`ca-publica.crt` conforme os pré-requisitos.

### 3. Subir os serviços

```bash
bash scripts/up.sh
```

Sobem três serviços: `minio` (sem portas publicadas), `nginx` (`8080` e `8443`) e `app`.

Use `scripts/up.sh` em vez de `docker compose up -d` direto: ele confere se as
portas e o hostname do `.env` batem com o `nginx/nginx.conf` antes de subir.

> **Se recriar o container do MinIO, reinicie o NGINX:**
> `docker compose restart nginx`
>
> O NGINX resolve o nome `minio` uma vez, ao iniciar, e guarda o IP. Se o
> MinIO voltar com outro IP, o proxy passa a responder `502` até ser reiniciado.

### 4. Verificar se os serviços subiram

```bash
docker compose ps
docker compose logs -f
```

Ambos devem aparecer como `running`. O MinIO leva alguns segundos até o healthcheck passar.

### 5. Criar o bucket e o usuário de presign

```bash
bash scripts/01-create-bucket.sh
```

Cria o bucket definido em `MINIO_BUCKET` (padrão: `videos`), privado, e o
usuário `MINIO_PRESIGN_USER` com uma única permissão: `s3:GetObject` no bucket.

É esse usuário que assina as URLs. O motivo é que o access key de quem assina
fica visível na URL, no parâmetro `X-Amz-Credential` — assinar com o root
exporia o administrador do storage em todo link de vídeo distribuído.

### 6. Enviar o vídeo de teste

```bash
bash scripts/02-upload-test-video.sh
```

Se `assets/video-teste.mp4` não existir, baixa o arquivo de `TEST_VIDEO_URL`
(Big Buck Bunny, CC-BY Blender Foundation) e envia para o bucket.

`TEST_VIDEO_URL` pode apontar para um `.mp4` **ou** para um `.zip` contendo o
`.mp4` — a origem usada hoje só distribui a versão compactada. O script detecta
o formato pelo conteúdo, extrai quando necessário e recusa continuar se o
resultado não for um MP4 válido (checa o box `ftyp`). Isso evita o caso
silencioso de um ZIP renomeado, que trafega íntegro pelo proxy mas não abre em
player nenhum.

Para usar um vídeo próprio, basta colocá-lo nesse caminho antes de rodar.

### 7. Gerar a URL pré-assinada

```bash
bash scripts/03-generate-presigned-url.sh
```

A saída deve ser uma URL parecida com:

```text
https://intranet.lab.local:8443/memoriais/019fb8eb-.../DEPOIMENTO/019fb8eb-....mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=...&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=...
```

Confirme que o host é o do **proxy** e não o do MinIO. Esse é o ponto principal da PoC.

### 8. Testar o acesso pelo proxy

```bash
bash scripts/04-test-access.sh
```

O script roda oito grupos de verificação e imprime um placar no final: proxy no
ar, MinIO inacessível pelo host, geração da URL, download e integridade,
`Range`, testes negativos de assinatura, ausência de vazamento do endpoint
interno e expiração. Sai com código diferente de zero se alguma falhar.

O teste de expiração gera uma URL de 30s e espera ela morrer, somando ~40s à
execução. Para pular: `SKIP_EXPIRY_TEST=1 bash scripts/04-test-access.sh`.

Ou manualmente:

```bash
URL="$(bash scripts/03-generate-presigned-url.sh)"

# cabeçalhos da resposta
curl -k -I "$URL"

# teste de Range (seek do player)
curl -k -r 0-1023 -o /dev/null -w '%{http_code}\n' "$URL"
```

E abra a URL no navegador para reproduzir o vídeo.

### 9. Testar a expiração isoladamente

Já coberto pelo script `04`, mas dá para rodar à parte:

```bash
CURTA="$(PRESIGN_EXPIRY=30s bash scripts/03-generate-presigned-url.sh)"
sleep 35 && curl -sk -o /dev/null -w '%{http_code}\n' "$CURTA"   # esperado: 403
```

> **Escopo desta versão:** o console do MinIO ainda não é exposto pelo proxy.
> Bucket e upload são feitos pelos scripts. Ver decisão 14 no `CLAUDE.md`.

---

## Como validar se deu certo

| Verificação | Como testar | Resultado esperado |
|---|---|---|
| Vídeo reproduz | abrir a URL no navegador | vídeo toca sem erro |
| Sem vazamento interno | `04-test-access.sh` grupo 7 | sem redirect, sem `minio:9000` |
| Acesso pelo proxy | ver a barra de endereço / `curl -I` | host `intranet.lab.local:8443` |
| MinIO não exposto | `curl http://localhost:9000` | conexão recusada (com o profile `demo` desligado) |
| Certificado do proxy | inspecionar o cadeado no navegador | emitido pela ca-publica, para `intranet.lab.local` |
| Seek funciona | `curl -k -r 0-1023 ... -w '%{http_code}'` | `206` |
| URL expira | aguardar `PRESIGN_EXPIRY` e repetir | `403` |
| Reprodutível | `docker compose down -v` e refazer tudo | mesmo resultado |

---

## Problemas comuns

### `403 SignatureDoesNotMatch` só no `curl -I`

**Não é bug de configuração.** A assinatura SigV4 cobre o método HTTP, e
`mc share download` assina para `GET`. Um `HEAD` (`curl -I`) monta um canonical
request diferente e o MinIO recusa, mesmo com tudo correto.

O sintoma é reconhecível: `HEAD` devolve `403` e `GET` devolve `200`/`206` na
mesma URL. Teste sempre com `GET`:

```bash
curl -k -s -o /dev/null -w '%{http_code}\n' "$URL"          # 200
curl -k -s -r 0-1023 -o /dev/null -w '%{http_code}\n' "$URL"  # 206
```

### `SignatureDoesNotMatch` no `GET` também

Aí sim é configuração. Causa mais provável: o `Host` visto pelo MinIO é
diferente do usado na assinatura.

- confirme `proxy_set_header Host $http_host;` em `nginx/nginx.conf`;
- confirme que `NGINX_HTTPS_PORT` no `.env` é igual ao `listen ... ssl` do `nginx.conf`;
- confirme que `MINIO_SERVER_URL` inclui esquema, host **e porta** (`https://intranet.lab.local:8443`);
- confirme que o NGINX não está reescrevendo o path — nem no `location`
  `/memoriais/`, nem com `proxy_pass` terminado em barra;
- confirme que o bucket se chama exatamente igual ao primeiro segmento do
  caminho (`memoriais`).

### `403 Forbidden` logo após gerar a URL

- relógio do container fora de sincronia com o host;
- credenciais do `mc` diferentes das do `.env`;
- URL já expirada (verifique `PRESIGN_EXPIRY`).

### Container não sobe

- portas `8080`/`8443` ocupadas — ajuste no `.env` **e** no `nginx/nginx.conf`;
- Docker parado;
- `.env` ausente ou com variável faltando.

### `502 Bad Gateway` do nada

O NGINX resolve `minio` uma vez, ao iniciar, e guarda o IP. Se o container do
MinIO foi recriado, ele voltou com outro endereço:

```bash
docker compose restart nginx
```

### `429 Too Many Requests`

Limite de conexões simultâneas por IP (`limit_conn perip 100`). Só deve
aparecer com muitos clientes atrás do mesmo NAT — ajuste o valor em
`nginx/nginx.conf` se for o caso.

### `AccessDenied` ao gerar a URL

O usuário de presign tem apenas `s3:GetObject` no bucket. Se você mudou
`MINIO_BUCKET` depois de criar o usuário, a policy aponta para o bucket antigo:

```bash
bash scripts/01-create-bucket.sh   # regenera a policy com o bucket atual
```

### Erro de TLS no `mc` ao gerar a URL

O `mc` valida os certificados usando as duas CAs do laboratório, montadas no
container. Se você regerou a PKI (`00-setup-certs.sh --force`), recrie os
containers: `docker compose up -d --force-recreate`. Como último recurso,
`MC_INSECURE=1` no `.env` desliga a validação.

### Bucket não encontrado

Confirme se o bucket foi criado e se o nome bate entre `.env`, scripts e a URL.

### Vídeo trava ou não permite seek

- `proxy_buffering off;` em `nginx/nginx.conf`;
- confirme que a resposta é `206` (`bash scripts/04-test-access.sh` já testa isso);
- o `log_format lab` do NGINX registra `range=` e `status=` em cada requisição:
  `docker compose logs -f nginx`.

### Aviso de certificado no navegador (`NET::ERR_CERT_AUTHORITY_INVALID`)

Depende de qual host apresentou o aviso.

Em **`intranet.lab.local`** significa que a `ca-publica.crt` não foi instalada.
Instale conforme os pré-requisitos e reinicie o navegador:

```powershell
Import-Certificate -FilePath .\nginx\certs\ca-publica.crt `
  -CertStoreLocation Cert:\LocalMachine\Root
```

Em **`vm-lnx-0369.lab.local`** o aviso é esperado e desejado: é o certificado da
CA interna, que reproduz exatamente a falha atual de produção. Não instale essa CA.

Em `curl`, continue usando `-k`.

### O vídeo não reproduz, mas o download bate byte a byte

Verifique se o arquivo é mesmo um MP4:

```bash
file assets/video-teste.mp4    # esperado: ISO Media, MP4 ...
```

Se aparecer `Zip archive data`, o arquivo veio de uma execução antiga, anterior
à extração automática. Apague e rode o script de novo:

```bash
rm assets/video-teste.mp4
bash scripts/02-upload-test-video.sh
```

O script agora recusa fazer upload de qualquer arquivo que não tenha o box
`ftyp`, então esse caso não passa mais despercebido.

### `413 Request Entity Too Large` no upload

Já tratado com `client_max_body_size 0;` no snippet — só relevante se o upload
também passar pelo proxy.

### `intranet.lab.local` não resolve

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
bash scripts/up.sh
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
