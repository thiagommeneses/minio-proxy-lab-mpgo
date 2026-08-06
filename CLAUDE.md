# CLAUDE.md — MinIO Proxy Lab MPGO

> Fonte única de contexto do projeto. Deve ser lida no início de toda sessão,
> tanto no Claude Desktop (análise, organização, documentação) quanto no
> Claude Code (implementação, scripts, configuração e testes).

---

## 1. Visão geral do projeto

Laboratório simulado que valida o fluxo de acesso a vídeos armazenados no **MinIO**
por meio de um **proxy reverso**, usando **URL pré-assinada**, sem expor o MinIO
diretamente ao usuário final.

O objetivo é reproduzir o cenário discutido com o André e testar uma arquitetura
mais segura, com menor exposição da infraestrutura e maior controle do caminho de acesso.

---

## 2. Contexto da demanda

O fluxo atual funciona, em linhas gerais, assim:

1. o usuário acessa a aplicação;
2. a aplicação consulta o MinIO;
3. o MinIO gera e devolve uma URL pré-assinada;
4. essa URL aponta **diretamente para o endereço do MinIO**.

O ponto a corrigir é o item 4: a URL entregue ao cliente revela o endpoint do storage.
A proposta a validar é que o conteúdo seja servido **através de um proxy reverso**,
com o certificado do proxy, mantendo o MinIO inacessível ao cliente final.

### Objetivo da prova de conceito

- simular o ambiente real de forma reduzida;
- subir o MinIO em container;
- configurar um proxy reverso com NGINX;
- gerar uma URL pré-assinada para um vídeo;
- testar o acesso final via proxy;
- documentar o resultado e os ajustes necessários para produção.

### Nota de transcrição

Sempre que na transcrição da reunião aparecer algo como "Miniayô", leia-se **MinIO**.

---

## 3. O ponto técnico central do laboratório

Este é o detalhe que determina o sucesso ou o fracasso da PoC e deve ser tratado
como premissa de projeto:

**A assinatura de uma URL pré-assinada S3 (SigV4) cobre o header `Host`.**

Consequências práticas:

- A URL pré-assinada precisa ser **gerada já com o endpoint do proxy**
  (ex.: `https://intranet.lab.local`), não com o endereço do MinIO.
  Trocar o host da URL depois de assinada invalida a assinatura (`SignatureDoesNotMatch`).
- O NGINX precisa **repassar o `Host` original** para o MinIO
  (`proxy_set_header Host $http_host;`). Se o proxy reescrever o Host para
  `minio:9000`, a assinatura também quebra.
- Alternativa suportada pelo MinIO: usar as variáveis `MINIO_SERVER_URL` e
  `MINIO_BROWSER_REDIRECT_URL` para que o próprio MinIO assine e gere as URLs
  já com o hostname público do proxy.

Decisão do laboratório: usar `MINIO_SERVER_URL` apontando para o proxy e
repassar `Host` no NGINX. É o caminho mais simples e o mais próximo do
que seria feito em produção.

---

## 4. Premissas técnicas

- O foco principal é o **vídeo** (arquivo grande, servido com `Range` requests).
- O laboratório não precisa reproduzir toda a aplicação final, desde que valide o fluxo principal.
- É aceitável pequena latência adicional por conta do proxy.
- A prioridade é **segurança, previsibilidade e controle do acesso**.
- O ambiente deve ser simples, reproduzível e fácil de documentar.

---

## 5. Escopo

### Dentro do escopo

- subir o MinIO;
- criar bucket;
- enviar vídeo de teste;
- gerar URL pré-assinada apontando para o proxy;
- configurar proxy reverso com NGINX (HTTP e HTTPS com certificado autoassinado);
- validar acesso ao vídeo, incluindo streaming com `Range`;
- validar expiração da URL;
- confirmar que o MinIO não é acessível diretamente pelo cliente;
- registrar evidências e resultados;
- documentar a arquitetura final.

### Fora do escopo por enquanto

- produção real;
- alta disponibilidade;
- Kubernetes;
- otimizações avançadas de performance e CDN;
- integração completa com a aplicação final, se não for necessária para o teste.

---

## 6. Ambiente

### Ambiente local recomendado

- **Windows com WSL2** para execução do Claude Code e dos scripts;
- **Docker Desktop** com integração ao WSL habilitada;
- editor/terminal com acesso à pasta do projeto.

### Serviços do laboratório

| Serviço | Papel | Exposto ao host |
|---|---|---|
| `minio` | storage S3, com TLS da `ca-interna` | **não** (apenas rede interna do compose) |
| `nginx` | proxy reverso / TLS de borda / roteamento por caminho | sim (`8080` HTTP, `8443` HTTPS) |
| `app` | ThemísIA/MemorIAis simulado (FastAPI + HTMX) | não (só através do proxy) |
| `minio-exposto` | socat que torna o MinIO alcançável, para demonstrar o caminho quebrado | só com `--profile demo` |
| `mc` | client auxiliar (bucket + usuário + upload + presign) | não (container efêmero) |

Manter o MinIO **sem publicar portas no host** é parte do teste: prova que o
único caminho até o objeto é o proxy.

---

## 7. Estrutura do repositório

```text
minio-proxy-lab-mpgo/
├── CLAUDE.md
├── README.md
├── docker-compose.yml
├── .env.example
├── .env                       # local, não versionar
├── .gitignore
├── app/                       # ThemísIA/MemorIAis simulado
│   ├── main.py
│   ├── requirements.txt
│   └── Dockerfile
├── nginx/
│   ├── nginx.conf             # server HTTP + HTTPS, roteamento por caminho
│   ├── conf.d/
│   │   └── minio-proxy.inc    # regras de proxy para o MinIO
│   └── certs/                 # 2 CAs + 2 certificados, não versionar
├── policies/
│   └── presign-readonly.json  # gerada por scripts/01, não versionar
├── scripts/
│   ├── lib/
│   │   └── common.sh          # carrega .env, valida .env x nginx.conf, mc_run()
│   ├── up.sh                  # sobe validando .env x nginx.conf
│   ├── 00-setup-certs.sh
│   ├── 01-create-bucket.sh
│   ├── 02-upload-test-video.sh
│   ├── 03-generate-presigned-url.sh
│   └── 04-test-access.sh
├── assets/
│   └── video-teste.mp4        # baixado pelo script 02, não versionar
└── notes/
    ├── contexto.md  decisoes.md  execucao.md
    ├── resultados.md
    └── producao.md            # migração para o ambiente real
```

---

## 8. Fluxo funcional esperado

1. o usuário solicita o vídeo;
2. a aplicação (ou script) obtém do MinIO uma URL pré-assinada;
3. a URL aponta para o **proxy reverso**, com o hostname e o certificado do proxy;
4. o proxy encaminha a requisição ao MinIO preservando `Host`, `Range` e a query string da assinatura;
5. o vídeo é entregue ao usuário;
6. o MinIO não é alcançável diretamente pelo cliente final.

```text
                    intranet.lab.local:8443
                  ┌──────────────────────────┐
[navegador] ──────┤ /themisia/  -> app       │
                  │ /memoriais/ -> MinIO     ├──HTTPS──> [MinIO :9000]
                  └──────────────────────────┘            vm-lnx-0369.lab.local
                    cert da ca-publica                    cert da ca-interna
                    (confiável)                           (NÃO confiável)
```

Aplicação e mídia no **mesmo host**, separadas por caminho — formato decidido
para produção (`intranet.mpgo.mp.br/themisia/` e `intranet.mpgo.mp.br/memoriais/`).
O primeiro segmento do caminho de mídia é o **nome do bucket**: como a assinatura
SigV4 cobre o caminho, o proxy não pode reescrevê-lo.

---

## 9. Plano de trabalho

### Fase 1 — Preparação
- validar WSL2 e Docker;
- criar a estrutura de pastas;
- gerar certificado autoassinado para o hostname de teste.

### Fase 2 — MinIO
- subir o container do MinIO com `MINIO_SERVER_URL` apontando para o proxy;
- configurar credenciais via `.env`;
- criar o bucket `videos`;
- enviar o vídeo de teste.

### Fase 3 — URL pré-assinada
- gerar a URL pré-assinada;
- confirmar que o host da URL é o do proxy;
- validar o tempo de expiração.

### Fase 4 — Proxy reverso
- subir o NGINX;
- configurar upstream, `Host`, `Range` e buffering;
- testar a resposta do proxy em HTTP e HTTPS.

### Fase 5 — Validação do fluxo
- abrir o vídeo pela URL gerada;
- confirmar `HTTP 206 Partial Content` no seek do player;
- verificar o certificado apresentado;
- confirmar que o MinIO não responde diretamente ao cliente;
- observar o comportamento após a expiração da assinatura (esperado: `403`).

### Fase 6 — Documentação
- registrar a arquitetura final;
- salvar os comandos usados;
- descrever os erros encontrados e como foram resolvidos;
- listar os ajustes necessários para o ambiente real.

---

## 10. Critérios de sucesso

O laboratório é considerado bem-sucedido quando:

- [ ] o vídeo abre e reproduz corretamente;
- [ ] o acesso ocorre exclusivamente pelo proxy reverso;
- [ ] o MinIO não está exposto diretamente ao usuário final;
- [ ] o certificado apresentado é o do proxy;
- [ ] a URL expira no tempo configurado e retorna erro depois disso;
- [ ] o seek no player funciona (`206 Partial Content`);
- [ ] o comportamento é estável e reproduzível do zero;
- [ ] a solução está documentada com evidências.

---

## 11. Riscos e pontos de atenção

| Risco | Sintoma esperado | Mitigação |
|---|---|---|
| Host reescrito pelo proxy | `SignatureDoesNotMatch` | `proxy_set_header Host $http_host;` |
| Porta do `.env` diferente do `listen` | `SignatureDoesNotMatch` | checagem automática em `scripts/lib/common.sh` |
| URL assinada com endpoint interno | URL vaza `minio:9000` | usar `MINIO_SERVER_URL` |
| Buffering do NGINX em arquivo grande | player trava, memória/disco alta | `proxy_buffering off;` |
| `Range` não repassado | sem seek, download inteiro | repassar `Range` e permitir `206` |
| Expiração curta durante o teste | `403` no meio da validação | usar expiração de 1h nos testes |
| Certificado autoassinado | aviso no navegador, `curl` falha | usar `curl -k` ou confiar no CA local |
| Testar com `HEAD` (`curl -I`) | `403 SignatureDoesNotMatch` com o proxy correto | a assinatura cobre o método; testar sempre com `GET` |
| MinIO recriado com outro IP | `502` súbito no proxy | `docker compose restart nginx` (o NGINX resolve o upstream só na inicialização) |
| HSTS herdado do MinIO | porta 8080 deixa de abrir no navegador | `proxy_hide_header Strict-Transport-Security` e política definida no proxy |
| Relógio do host fora de sincronia | `403` intermitente sem mudança de configuração | SigV4 rejeita `X-Amz-Date` fora de ~15 min; verificar o clock do WSL2 após suspender |
| URL expira durante a sessão | vídeo trava no seek, não no play | expiração precisa cobrir a sessão com pausas, não a duração do vídeo |
| `client_max_body_size` padrão | upload grande falha com `413` | ajustar no NGINX se houver upload via proxy |

---

## 12. Estratégia de execução

### Princípios de trabalho

- preferir a solução mais simples que funcione;
- evitar complexidade desnecessária;
- validar cada etapa antes de avançar;
- documentar toda decisão relevante;
- manter o laboratório reproduzível a partir do zero.

### Ordem sugerida

1. gerar certificados;
2. subir MinIO;
3. criar bucket e validar upload;
4. subir NGINX;
5. gerar URL pré-assinada;
6. testar o vídeo pelo proxy;
7. registrar resultado.

---

## 13. Decisões técnicas

| # | Decisão | Escolha | Motivo |
|---|---|---|---|
| 1 | Orquestração | Docker Compose | mais simples e reproduzível que containers avulsos |
| 2 | Ambiente de execução | WSL2 + Docker Desktop | ambiente já disponível na máquina |
| 3 | Proxy reverso | NGINX | é o que se pretende usar no ambiente real |
| 4 | Exposição do MinIO | sem publicar portas no host | prova que o único caminho é o proxy |
| 5 | Console do MinIO | acessível apenas via proxy, em rota separada | evita segundo ponto de exposição |
| 6 | Papel do proxy | encaminhamento puro, sem reescrita de path | reescrita quebraria a assinatura SigV4 |
| 7 | Hostname de teste | `intranet.lab.local` via `hosts` | simula `intranet.mpgo.mp.br` sem depender de DNS |
| 8 | Certificado | duas CAs de laboratório | reproduz a assimetria de produção: navegador confia no proxy (GlobalSign) e não no MinIO (CA interna do MP-GO) |
| 9 | Geração da URL | `mc` com alias apontando para o proxy | equivale ao que a aplicação faria |
| 10 | Portas do NGINX | iguais dentro e fora do container (`8443:8443`) | porta faz parte do `Host` assinado; divergir quebra a assinatura |
| 11 | Resolução do hostname | `intranet.lab.local` como alias de rede do NGINX | o container `mc` precisa resolver o mesmo nome que o navegador usa |
| 12 | Aliases do `mc` | `lab` (admin, direto) e `proxy` (somente presign) | tarefas administrativas não devem depender do proxy |
| 13 | Config do NGINX | arquivo único `nginx/nginx.conf`, portas fixas | legibilidade acima de DRY; a duplicação entre `.env` e `nginx.conf` é coberta por checagem automática em `common.sh` |
| 14 | Console do MinIO | adiado para depois da validação do vídeo | WebSocket e redirect adicionam risco sem ajudar a premissa central |
| 15 | Vídeo de teste | baixado no setup via `TEST_VIDEO_URL`, com extração de `.zip` e validação do box `ftyp` | reproduzível do zero sem versionar binário grande; a validação evita subir um ZIP renomeado, que passaria em todos os testes menos no player |
| 16 | Credencial que assina | usuário dedicado com apenas `s3:GetObject` no bucket | o access key de quem assina fica visível no `X-Amz-Credential` da URL; com root, todo link de vídeo exporia o administrador do storage |
| 17 | Validade da URL | 24h | a assinatura é conferida a cada requisição, então precisa cobrir a sessão inteira com pausas, não a duração do vídeo; abaixo disso o player trava no seek |
| 18 | HSTS | `max-age=0` no laboratório, com o header do MinIO descartado | HSTS vale por host e ignora a porta: qualquer valor positivo forçaria HTTPS na porta 8080 e mataria o caminho de diagnóstico sem TLS |
| 19 | Proteção contra abuso | `limit_conn` por IP, sem `limit_rate` nem `limit_req` | `limit_req` quebraria a rajada legítima de `Range` do seek; `limit_rate` exigiria conhecer o bitrate e travaria vídeos longos |
| 20 | TLS no `mc` | certificado do proxy montado como CA no container | desligar a validação justamente no componente que assina as URLs esconderia um MITM nesse caminho |
| 21 | Subida do ambiente | via `scripts/up.sh` | garante que a checagem `.env` × `nginx.conf` rode antes do `docker compose up` |
| 22 | Formato da URL pública | caminho no mesmo host: `/memoriais/<chave>` | a assinatura cobre o caminho, então o prefixo **é** o nome do bucket; não existe prefixo livre nem rewrite possível |
| 23 | Aplicação de simulação | FastAPI + HTMX, duas abas, dois players | erro de certificado dentro de `<video>` falha em silêncio — nenhum teste com `curl` detecta, só um player real |
| 24 | Exposição do MinIO na demo | sob profile `demo` (socat) | o caminho quebrado precisa do MinIO alcançável, que é o oposto do que a PoC defende; fica opt-in |
| 25 | Perna proxy → MinIO | HTTPS validado contra a `ca-interna` | implementa no lab a decisão já tomada para produção |
| 26 | Emissão do cert do proxy | `mkcert` se disponível, `openssl` como fallback | o `mkcert` instala a CA também no truststore do Firefox, que é separado do Windows; a `ca-interna` continua no openssl porque precisa permanecer não confiável |

Decisões novas devem ser acrescentadas aqui e detalhadas em `notes/decisoes.md`.

---

## 14. Estado atual

Atualizado em: **06/08/2026**

| Item | Estado |
|---|---|
| Documentação base (CLAUDE.md / README.md) | concluído |
| Estrutura de pastas | concluído |
| `docker-compose.yml` | **executado, funcionando** |
| Configuração do NGINX | **executada, funcionando** |
| Scripts (`00`–`04`) | executados; 4 bugs corrigidos (ver `notes/resultados.md`) |
| Certificado autoassinado | gerado, válido até 07/11/2028 |
| MinIO | rodando, `healthy`, sem porta publicada |
| Bucket `videos` | criado, sem acesso anônimo |
| Vídeo de teste | **MP4 real** extraído do `.zip`, 62 MiB, `content-type: video/mp4` |
| URL pré-assinada | gerada com host do proxy, assinada por usuário dedicado |
| Acesso ao vídeo via proxy | **validado** (`200` no GET, `206` no Range, íntegro) |
| Expiração da URL | **validada** (`403` após expirar) |
| Reprodução em player real | não confirmada |
| Ciclo a partir do zero | `down -v` executado; falta a subida limpa |

**A premissa central da seção 3 está validada.** A URL pré-assinada nasce com o
host do proxy, atravessa o NGINX com o `Host` preservado e o MinIO aceita a
assinatura. O download bateu byte a byte com o arquivo original e o `Range`
devolve `206 Partial Content`. O MinIO não é alcançável de fora.

---

## 15. Pendências

1. subir do zero e rodar o placar completo — o `down -v` apagou o volume,
   então esta rodada já fecha o critério 7:
   `bash scripts/00-setup-certs.sh && bash scripts/up.sh && bash scripts/01-create-bucket.sh
    && bash scripts/02-upload-test-video.sh && bash scripts/04-test-access.sh`;
2. abrir o vídeo em player real, confirmar o seek e capturar print (critério 1);
3. atualizar as seções 14 e 18 com o resultado final;
4. reavaliar a exposição do console do MinIO (decisão 14).

---

## 16. Diário de execução

### 06/08/2026 — revisão técnica e endurecimento
- **O que foi feito:** segunda execução com **8 de 8 checagens passando** e expiração confirmada (`403` após 35s), fechando o critério 5. Depois, revisão de proxy, certificado, expiração e Host header, com correções aplicadas.
- **Resultado:** vídeo de teste agora é MP4 real (`content-type: video/mp4`, 64.657.027 bytes, íntegro byte a byte). Aplicado: usuário dedicado somente-leitura para assinar as URLs (o access key aparece no `X-Amz-Credential`, então o root não podia continuar ali); expiração para 24h; HSTS do MinIO descartado e zerado no lab, porque HSTS ignora a porta e estava a caminho de inutilizar o diagnóstico via 8080; `client_max_body_size` escopado em vez de ilimitado; `limit_conn` por IP; `mc` passou a validar o certificado do proxy em vez de usar `--insecure`; `scripts/up.sh` garante a checagem `.env` × `nginx.conf`; e o placar ganhou os grupos 7 (sem redirect nem vazamento de `minio:9000`) e 8 (expiração automatizada).
- **Problemas encontrados:** dois riscos latentes que ainda não tinham mordido. O IP do upstream fica congelado no NGINX — se o MinIO for recriado, o proxy responde `502` até reiniciar; ficou documentado no README em vez de resolvido, porque `resolver` com variável no `proxy_pass` acrescenta complexidade que a PoC não precisa. E o HSTS de um ano vindo do MinIO, que teria quebrado o caminho HTTP no navegador de quem já acessou o HTTPS.
- **Próximo passo:** subida limpa após o `down -v` (fecha o critério 7) e reprodução em player real (critério 1).

### 05/08/2026 — primeira execução real
- **O que foi feito:** fluxo completo `00`→`04` em WSL2 + Docker Desktop, mais a bateria manual de validação (certificado, testes negativos, integridade, `Range`).
- **Resultado:** **a premissa central está validada.** URL assinada com `videos.lab.local:8443`, `Host` preservado ponta a ponta (log do NGINX confirma), `200` no GET, `206` com `Content-Range: bytes 0-1023/64657225`, download byte a byte idêntico ao original. MinIO inalcançável de fora (`docker compose port minio 9000` → `invalid IP:0`). Assinatura efetivamente verificada: sem query string e com assinatura adulterada, ambos `403`.
- **Problemas encontrados:** quatro bugs, **todos nos scripts de teste, nenhum na configuração**. (B1) `curl -I` devolvia `403 SignatureDoesNotMatch` porque a assinatura SigV4 cobre o método HTTP e `mc share download` assina para `GET` — `HEAD` nunca valida; o teste é que estava errado. (B2) `esperado=000 obtido=000000`: o `|| echo 000` duplicava o `000` que o próprio `curl -w` já imprime em falha de conexão. (B3) `PRESIGN_EXPIRY=30s` na linha de comando era ignorado porque `set -a; . ./.env` sobrescrevia o ambiente do caller. (B4) `grep`/`sed` não existem na imagem `minio/mc`. Detalhes em `notes/resultados.md`.
- **Próximo passo:** confirmar que o vídeo de teste é MP4 e não ZIP, testar a expiração e validar o seek em player real.

### 04/08/2026 — base executável
- **O que foi feito:** criados `docker-compose.yml`, configuração do NGINX (template + snippet), `.env.example`, `.gitignore`, os cinco scripts e os arquivos de `notes/`.
- **Resultado:** validação estática limpa — YAML parseável, `bash -n` e `shellcheck -S warning` sem apontamentos, substituição do template preservando as variáveis do NGINX (`$http_host` etc.), e o parser da URL do presign testado com saída simulada do `mc`, incluindo a contraprova de que uma URL com host do MinIO é rejeitada.
- **Problemas encontrados:** o risco de o `envsubst` do entrypoint do NGINX consumir `$http_host` foi verificado e não se confirma (só variáveis presentes no ambiente são substituídas). Decisão de igualar as portas interna e externa surgiu ao mapear como o `Host` assinado pelo `mc` (de dentro da rede) se compara ao enviado pelo navegador (de fora).
- **Próximo passo:** primeira execução real do fluxo.

### 04/08/2026 — documentação
- **O que foi feito:** revisão e reescrita da documentação base (`CLAUDE.md` e `README.md`), que estavam com escapes de markdown e texto conversacional; consolidação das decisões técnicas e do ponto crítico da assinatura SigV4.
- **Resultado:** contexto do projeto pronto para ser consumido por sessões novas.
- **Problemas encontrados:** os arquivos originais não tinham os nomes padrão (`CLAUDE.md` / `README.md`), então não eram carregados automaticamente como contexto.
- **Próximo passo:** criar `docker-compose.yml`, `nginx.conf` e os scripts.

<!-- Novas entradas abaixo, do mais recente para o mais antigo, no formato:
### dd/mm/aaaa
- **O que foi feito:**
- **Resultado:**
- **Problemas encontrados:**
- **Próximo passo:**
-->

---

## 17. Evidências e resultados

Guardar aqui (ou em `notes/resultados.md`) tudo que comprove o funcionamento:

- prints do vídeo reproduzindo com a URL do proxy na barra de endereço;
- print do certificado apresentado;
- saída do `curl -I` mostrando `206 Partial Content`;
- saída mostrando `403` após a expiração;
- comprovação de que o MinIO não responde na porta direta;
- logs do NGINX e do MinIO;
- trechos relevantes da configuração;
- comandos executados.

---

## 18. Ajustes previstos para o ambiente real

> Detalhamento, checklist e configuração do NGINX para produção estão em
> [`notes/producao.md`](notes/producao.md), já com a análise do certificado
> real do servidor MinIO (`vm-lnx-0369.intranet.mpgo`).

**Decisão bloqueante:** o hostname público ainda não foi definido. Ele entra na
assinatura SigV4, então precisa ser fixado antes de gerar qualquer URL em
produção. O certificado atual cobre só `vm-lnx-0369.intranet.mpgo` — nome de
máquina — e vence em **02/09/2026**.

**Decidido:** a perna proxy → MinIO usará HTTPS validado contra a CA do MP-GO.

Lista a ser confirmada ao final da PoC:

- certificado emitido por CA confiável em vez de autoassinado;
- hostname público real e registro DNS;
- `MINIO_SERVER_URL` apontando para o domínio de produção **sem porta**, já que
  em `443` o header `Host` não a inclui — incluir é a forma mais provável de
  reproduzir o `SignatureDoesNotMatch` no ambiente real;
- regras de firewall garantindo que o MinIO só aceite tráfego do proxy;
- HSTS com `max-age=86400` durante a implantação e `31536000` depois que todo o
  caminho estiver comprovadamente em HTTPS (no lab está em `0` de propósito);
- `resolver` no NGINX, ou reinício automático, para não congelar o IP do upstream;
- revisão do `limit_conn` considerando clientes atrás de NAT corporativo;
- credencial de presign rotacionável, com política de expiração alinhada à
  duração máxima de sessão — a URL é um bearer token e não há revogação;
- avaliação de cache e de limite de banda no proxy;
- logging e monitoração do caminho de acesso, mantendo a query string fora do
  log (o `log_format lab` já faz isso usando `$uri` em vez de `$request`).

---

## 19. Como usar este arquivo

- **Claude Desktop:** análise, organização, documentação e revisão do plano.
- **Claude Code:** implementação, scripts, configuração, ajustes e testes.

Ao iniciar uma sessão, ler as seções 3 (ponto técnico central), 13 (decisões),
14 (estado atual) e 15 (pendências) antes de agir.

---

## 20. Próximo passo sugerido

O fluxo principal já está validado. Falta fechar os critérios pendentes:

```bash
rm assets/video-teste.mp4          # o arquivo antigo era um ZIP
bash scripts/02-upload-test-video.sh   # agora extrai o MP4 e valida o 'ftyp'
bash scripts/04-test-access.sh     # placar completo, agora com 8 checagens

CURTA="$(PRESIGN_EXPIRY=30s bash scripts/03-generate-presigned-url.sh)"
sleep 35 && curl -sk -o /dev/null -w '%{http_code}\n' "$CURTA"   # esperado: 403
```

Depois, abrir o vídeo em player real para confirmar o seek, e repetir o ciclo
a partir de `docker compose down -v` para fechar o critério de reprodutibilidade.
