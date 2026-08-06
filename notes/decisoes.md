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
A opção 1 produziria `intranet.lab.local` na assinatura e
`intranet.lab.local:8443` na requisição do navegador — `SignatureDoesNotMatch`.
Alterar as portas no `.env` mantém a consistência porque o `listen` é gerado
a partir das mesmas variáveis.

---

## D2 — `intranet.lab.local` como alias de rede do serviço NGINX

**Contexto:** o container `mc` precisa resolver o hostname público para assinar
a URL contra o proxy.

**Escolha:** declarar `aliases: [${PUBLIC_HOST}]` na rede do compose.

**Consequência:** o mesmo nome resolve de dentro (via DNS do Docker) e de fora
(via arquivo de hosts). Sem isso, o `mc` falharia na resolução de nome.

---

## D3 — Dois aliases no `mc`, com papéis separados

| Alias | Endpoint | Uso |
|---|---|---|
| `lab` | `https://minio:9000` | criar bucket, usuário, upload |
| `proxy` | `https://intranet.lab.local:8443` | somente gerar a URL pré-assinada |

**Motivo:** tarefas administrativas não fazem parte do fluxo em validação e não
devem depender do proxy. Já o presign **precisa** sair pelo proxy, porque é o
endpoint do alias que define o `Host` assinado.

**Consequência:** o alias `proxy` valida o certificado do proxy contra a
`ca-publica`, montada como CA no container (ver D11).

---

## D4 — Console do MinIO adiado

**Contexto:** a decisão 5 do `CLAUDE.md` prevê o console acessível apenas via
proxy, em rota separada.

**Escolha:** não implementar na primeira versão.

**Motivo:** exige segundo `server_name`, headers de upgrade de WebSocket e
`MINIO_BROWSER_REDIRECT_URL` — complexidade que não ajuda a validar a premissa
central e adiciona superfície de erro. Bucket e upload são feitos por script.

**Reavaliar quando:** o fluxo do vídeo estiver validado de ponta a ponta.

**Resolvido em 06/08/2026:** o console é publicado direto em
`https://vm-lnx-0369.lab.local:9001/`, com o certificado da `ca-interna`.

Uma versão intermediária chegou a servi-lo pelo proxy em `console.lab.local:8443`,
com certificado confiável. Foi descartada por não corresponder a produção: lá o
console vive no mesmo hostname do MinIO, e abrir `https://vm-lnx-0369:9000/` no
navegador redireciona para `https://vm-lnx-0369.intranet.mpgo:9001/`. Além disso,
`vm-lnx-0369.intranet.mpgo` está em zona DNS distinta de `*.mpgo.mp.br`, então
nem em produção existiria certificado confiável para esse nome.

`MINIO_BROWSER_REDIRECT_URL` reproduz o redirect `:9000` → `:9001` no laboratório.

**Custo aceito:** o console fica exposto sem passar pelo proxy e com aviso de
certificado. O critério "MinIO não exposto" continua valendo para o caminho da
**mídia**, que é o que a PoC valida — a porta 9000 segue fechada por padrão.

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

## D7 — Usuário dedicado para assinar as URLs

**Contexto:** o presign era feito com `MINIO_ROOT_USER`. O access key de quem
assina aparece em texto claro na URL, no parâmetro `X-Amz-Credential`.

**Escolha:** usuário `MINIO_PRESIGN_USER` com uma única permissão,
`s3:GetObject` no bucket de vídeos, criado por `scripts/01-create-bucket.sh`.

**Motivo:** todo link de vídeo distribuído revelava o usuário administrador do
storage. Com o usuário dedicado, o que vaza é uma identidade que não lista, não
grava e não apaga nada.

**Consequência:** a policy é gerada no host (`policies/presign-readonly.json`) e
montada no container, porque a imagem `minio/mc` não tem ferramentas para
montar o arquivo lá dentro. Trocar `MINIO_BUCKET` exige rodar o `01` de novo.

---

## D8 — Validade da URL em 24h

**Contexto:** a pergunta natural é "quanto dura o vídeo?", mas ela é a errada.

**Motivo:** a assinatura é conferida a **cada requisição**. O que precisa ser
coberto é a duração da sessão, incluindo pausas — um vídeo de 2h assistido com
interrupções pode ocupar 5h de relógio. Se a URL expira antes, o vídeo não falha
ao abrir: ele trava no próximo seek, no meio da sessão, e o sintoma é confuso.

**Escolha:** 24h.

**Contrapartida:** a URL é um bearer token. Se vazar, vale até expirar e não há
revogação sem rotacionar a credencial que assinou. Para conteúdo mais sensível,
6h ainda cobre um vídeo de 2h com folga. Teto do MinIO: 7 dias.

---

## D9 — HSTS controlado pelo proxy, `max-age=0` no laboratório

**Contexto:** o MinIO emite `Strict-Transport-Security: max-age=31536000;
includeSubDomains` em toda resposta, e o NGINX repassava.

**Problema:** HSTS vale por **host** e **ignora a porta**. Depois de um único
acesso a `https://intranet.lab.local:8443`, o navegador passaria a forçar HTTPS
também em `http://intranet.lab.local:8080`, onde não há TLS — matando o bloco HTTP
que existe justamente para isolar problema de certificado de problema de proxy.

**Escolha:** `proxy_hide_header` nos dois blocos; o HTTPS emite `max-age=0`.

**Motivo do zero:** além de não poluir, ele **limpa** a política já gravada em
navegadores que acessaram versões anteriores do laboratório.

**Em produção:** `86400` durante a implantação, para poder reverter sem deixar
clientes presos, e `31536000` depois que todo o caminho estiver em HTTPS.

---

## D10 — `limit_conn` em vez de `limit_req` ou `limit_rate`

**Contexto:** o laboratório serve vídeos de 1 minuto a 2 horas.

**Alternativas descartadas:**

- `limit_req` — o seek do player dispara uma rajada legítima de requisições
  `Range`. Limitar taxa de requisição transformaria uso normal em `503`.
- `limit_rate` — a taxa correta depende do bitrate. Errar para baixo trava a
  reprodução; errar para cima não protege. Com vídeos de perfis tão diferentes,
  não existe um valor único defensável.

**Escolha:** `limit_conn perip 100`, conexões simultâneas por IP.

**Consequência:** protege contra um scraper abrindo centenas de conexões sem
interferir em uso normal. O valor é generoso de propósito porque, atrás de NAT
corporativo, muitos usuários compartilham o mesmo IP — precisa ser revisto se
isso virar produção.

---

## D11 — Duas CAs, com mkcert opcional para a metade confiável

**Contexto:** o laboratório precisa que o navegador confie no certificado do
proxy e **não** confie no do MinIO. É essa assimetria que reproduz a falha de
produção (GlobalSign vs. Certificadora TLS do MP-GO). Com um autoassinado só,
os dois caminhos falhariam e a comparação lado a lado não provaria nada.

**Por que não usar mkcert para tudo:** o mkcert é construído em torno de uma CA
que é sempre instalada como confiável. Ele não sabe emitir a metade que precisa
continuar não confiável. Essa metade fica no openssl de qualquer forma.

**Escolha:** híbrido com detecção automática.

- certificado do proxy: mkcert se o binário existir, openssl como fallback;
- `ca-interna` e certificado do MinIO: sempre openssl.

**Motivo de aceitar o mkcert:** ele instala a CA em todos os truststores,
incluindo o do **Firefox**, que é separado do Windows e não é alcançado por
`Import-Certificate`. A instrução anterior falhava silenciosamente no Firefox.

**Pegadinha do WSL:** `mkcert -install` rodado dentro do WSL instala no
truststore do Linux, não no do Windows, e o navegador é o do Windows. O script
distingue os dois casos pelo formato do `-CAROOT`: caminho Windows (`C:\...`)
significa `mkcert.exe`, e é convertido com `wslpath` para poder ser lido. Caminho
POSIX significa mkcert do WSL, e o script avisa que a instalação manual ainda é
necessária.

**Escotilha:** `USE_MKCERT=0` força o openssl.

---

<!-- Novas decisões abaixo, seguindo o mesmo formato. -->
