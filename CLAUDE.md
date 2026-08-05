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
  (ex.: `https://videos.lab.local`), não com o endereço do MinIO.
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
| `minio` | storage S3 | **não** (apenas rede interna do compose) |
| `nginx` | proxy reverso / TLS | sim (`8080` HTTP, `8443` HTTPS) |
| `mc` | client auxiliar (bucket + upload + presign) | não (container efêmero) |

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
├── nginx/
│   ├── nginx.conf             # config única: server HTTP + server HTTPS
│   └── certs/                 # gerado localmente, não versionar
├── scripts/
│   ├── lib/
│   │   └── common.sh          # carrega .env, valida .env x nginx.conf, mc_run()
│   ├── 00-setup-certs.sh
│   ├── 01-create-bucket.sh
│   ├── 02-upload-test-video.sh
│   ├── 03-generate-presigned-url.sh
│   └── 04-test-access.sh
├── assets/
│   └── video-teste.mp4        # baixado pelo script 02, não versionar
└── notes/
    ├── contexto.md
    ├── decisoes.md
    ├── execucao.md
    └── resultados.md
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
[cliente] --HTTPS--> [NGINX :8443]  --HTTP--> [MinIO :9000]
              ^                                    ^
     certificado do proxy              rede interna do compose,
     hostname público                  sem porta publicada no host
```

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
| 7 | Hostname de teste | `videos.lab.local` via `hosts` | reproduz nome público sem depender de DNS |
| 8 | Certificado | autoassinado local | suficiente para validar o caminho TLS |
| 9 | Geração da URL | `mc` com alias apontando para o proxy | equivale ao que a aplicação faria |
| 10 | Portas do NGINX | iguais dentro e fora do container (`8443:8443`) | porta faz parte do `Host` assinado; divergir quebra a assinatura |
| 11 | Resolução do hostname | `videos.lab.local` como alias de rede do NGINX | o container `mc` precisa resolver o mesmo nome que o navegador usa |
| 12 | Aliases do `mc` | `lab` (admin, direto) e `proxy` (somente presign) | tarefas administrativas não devem depender do proxy |
| 13 | Config do NGINX | arquivo único `nginx/nginx.conf`, portas fixas | legibilidade acima de DRY; a duplicação entre `.env` e `nginx.conf` é coberta por checagem automática em `common.sh` |
| 14 | Console do MinIO | adiado para depois da validação do vídeo | WebSocket e redirect adicionam risco sem ajudar a premissa central |
| 15 | Vídeo de teste | baixado no setup via `TEST_VIDEO_URL`, com extração de `.zip` e validação do box `ftyp` | reproduzível do zero sem versionar binário grande; a validação evita subir um ZIP renomeado, que passaria em todos os testes menos no player |

Decisões novas devem ser acrescentadas aqui e detalhadas em `notes/decisoes.md`.

---

## 14. Estado atual

Atualizado em: **05/08/2026**

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
| Vídeo de teste | enviado (62 MiB) — ver pendência sobre `.zip` |
| URL pré-assinada | gerada com host do proxy |
| Acesso ao vídeo via proxy | **validado** (`200` no GET, `206` no Range, íntegro) |
| Expiração da URL | não testada |
| Reprodução em player real | não confirmada |

**A premissa central da seção 3 está validada.** A URL pré-assinada nasce com o
host do proxy, atravessa o NGINX com o `Host` preservado e o MinIO aceita a
assinatura. O download bateu byte a byte com o arquivo original e o `Range`
devolve `206 Partial Content`. O MinIO não é alcançável de fora.

---

## 15. Pendências

1. refazer o vídeo de teste — era mesmo um ZIP, e o script `02` já foi corrigido:
   `rm assets/video-teste.mp4 && bash scripts/02-upload-test-video.sh`;
2. rodar novamente `bash scripts/04-test-access.sh` com os bugs corrigidos;
3. testar a expiração: `CURTA="$(PRESIGN_EXPIRY=30s bash scripts/03-generate-presigned-url.sh)"`
   e, após 35s, esperar `403`;
4. abrir o vídeo em player real, confirmar o seek e capturar print;
5. repetir o ciclo após `docker compose down -v` para fechar o critério 7;
6. atualizar as seções 14 e 18 com o resultado final;
7. reavaliar a exposição do console do MinIO (decisão 14).

---

## 16. Diário de execução

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

Lista a ser confirmada ao final da PoC:

- certificado emitido por CA confiável em vez de autoassinado;
- hostname público real e registro DNS;
- `MINIO_SERVER_URL` apontando para o domínio de produção;
- regras de firewall garantindo que o MinIO só aceite tráfego do proxy;
- política de expiração de URL alinhada à duração média do vídeo;
- avaliação de cache e de limite de banda no proxy;
- logging e monitoração do caminho de acesso.

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
