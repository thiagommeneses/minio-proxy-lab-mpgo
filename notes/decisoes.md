# Decisões técnicas

Detalhamento das decisões resumidas na seção 13 do `CLAUDE.md`.
Formato: contexto → alternativas → escolha → consequência.

---

## D1 — Portas internas do NGINX iguais às do host

**Contexto:** a assinatura SigV4 cobre o header `Host`, incluindo a porta.
O `mc` assina a URL de dentro da rede do compose; o navegador acessa de fora.

**Alternativas:**

1. NGINX escuta `443` internamente, mapeado para `8443` no host.
2. NGINX escuta `8443` dentro e fora.

**Escolha:** opção 2 (`8443:8443`).

**Consequência:** o mesmo `Host` vale dentro e fora da rede do compose.
A opção 1 produziria `videos.lab.local` na assinatura e
`videos.lab.local:8443` na requisição do navegador — `SignatureDoesNotMatch`.
Alterar as portas no `.env` mantém a consistência porque o `listen` é gerado
a partir das mesmas variáveis.

---

## D2 — `videos.lab.local` como alias de rede do serviço NGINX

**Contexto:** o container `mc` precisa resolver o hostname público para assinar
a URL contra o proxy.

**Escolha:** declarar `aliases: [${PUBLIC_HOST}]` na rede do compose.

**Consequência:** o mesmo nome resolve de dentro (via DNS do Docker) e de fora
(via arquivo de hosts). Sem isso, o `mc` falharia na resolução de nome.

---

## D3 — Dois aliases no `mc`, com papéis separados

| Alias | Endpoint | Uso |
|---|---|---|
| `lab` | `http://minio:9000` | criar bucket, upload |
| `proxy` | `https://videos.lab.local:8443` | somente gerar a URL pré-assinada |

**Motivo:** tarefas administrativas não fazem parte do fluxo em validação e não
devem depender do proxy. Já o presign **precisa** sair pelo proxy, porque é o
endpoint do alias que define o `Host` assinado.

**Consequência:** o alias `proxy` usa `--insecure` (certificado autoassinado).

---

## D4 — Console do MinIO adiado

**Contexto:** a decisão 5 do `CLAUDE.md` prevê o console acessível apenas via
proxy, em rota separada.

**Escolha:** não implementar na primeira versão.

**Motivo:** exige segundo `server_name`, headers de upgrade de WebSocket e
`MINIO_BROWSER_REDIRECT_URL` — complexidade que não ajuda a validar a premissa
central e adiciona superfície de erro. Bucket e upload são feitos por script.

**Reavaliar quando:** o fluxo do vídeo estiver validado de ponta a ponta.

---

## D5 — Vídeo de teste baixado no setup

**Escolha:** `scripts/02-upload-test-video.sh` baixa o arquivo definido em
`TEST_VIDEO_URL` quando `assets/video-teste.mp4` não existe.

**Motivo:** mantém o laboratório reproduzível do zero sem versionar binário grande.

**Consequência:** o setup passa a depender de rede e de um link externo. O script
falha com mensagem clara e o arquivo pode ser colocado manualmente.

**Atualização em 05/08/2026:** a origem deixou de distribuir o `.mp4` avulso e
hoje só publica o `.zip` com o MP4 dentro. O script `02` passou a detectar o
formato **pelo conteúdo** (magic bytes `PK` para ZIP, box `ftyp` para MP4) e a
extrair o maior `.mp4` de dentro do arquivo, usando `python3` ou `unzip`.

Além disso, o script agora **recusa fazer upload** de qualquer arquivo sem o box
`ftyp`. O motivo é que a falha anterior era silenciosa: um ZIP renomeado para
`.mp4` sobe normalmente, trafega íntegro pelo proxy, passa no `cmp` byte a byte
e em todos os testes de `Range` — e mesmo assim nenhum player abre. Sem essa
checagem, o critério 1 pareceria atendido sem estar.

---

## D6 — Configuração do NGINX em arquivo único

**Contexto:** a primeira versão usava `nginx/templates/default.conf.template`
(portas vindas do `.env` via `envsubst`) mais `nginx/snippets/minio-proxy.conf`
(regras de proxy compartilhadas por HTTP e HTTPS).

**Alternativas:**

1. Template + snippet: porta com fonte de verdade única, duas indireções.
2. Arquivo único `nginx/nginx.conf` com portas fixas: legível de uma olhada,
   mas duplica portas e hostname entre `.env` e a configuração.

**Escolha:** opção 2.

**Motivo:** o laboratório precisa ser fácil de ler e de mostrar para o time.
A configuração é o artefato que será discutido; duas indireções atrapalham mais
do que a duplicação atrapalha.

**Consequência e mitigação:** portas e hostname passam a existir em dois lugares.
`scripts/lib/common.sh` compara `.env` com `nginx/nginx.conf` a cada execução e
aborta com mensagem explícita se `NGINX_HTTP_PORT`, `NGINX_HTTPS_PORT` ou
`PUBLIC_HOST` divergirem do `listen`/`server_name`. A divergência silenciosa
seria diagnosticada como `SignatureDoesNotMatch`, o erro mais caro de depurar
neste laboratório.

**Custo aceito:** o bloco de proxy aparece duas vezes no `nginx.conf` (HTTP e
HTTPS). Se um for alterado sem o outro, os dois caminhos passam a divergir.

---

<!-- Novas decisões abaixo, seguindo o mesmo formato. -->
