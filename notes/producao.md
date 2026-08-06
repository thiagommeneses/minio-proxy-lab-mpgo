# Migração para produção — MP-GO

Documento de trabalho. Consolida o que muda entre o laboratório e o ambiente real.

---

## 0. Situação atual e decisão de formato

### O que acontece hoje

O ThemísIA roda em `https://intranet.mpgo.mp.br/themisia/`, com certificado
confiável. O MemorIAis é um módulo dentro dele, e o player consome a
`presigned_url` devolvida na **listagem** dos artefatos.

Essa URL aponta direto para o MinIO:

```text
https://vm-lnx-0369:9000/memoriais/<uuid>/DEPOIMENTO/<uuid>.mp4
  ?X-Amz-Credential=minioadmin%2F...&X-Amz-Expires=28800&...
```

O GET da mídia **não passa pelo ThemísIA**: o navegador fala direto com o MinIO.
Como o certificado do MinIO vem da CA interna, o navegador bloqueia — e bloqueia
em silêncio, porque dentro de um `<video>` não existe "Avançado → prosseguir".

Três coisas que essa URL revela, além do problema principal:

1. o host é `vm-lnx-0369`, nome curto, enquanto o certificado cobre
   `vm-lnx-0369.intranet.mpgo`. Nem entre servidores esse nome valida — a
   verificação TLS está desligada no backend;
2. `X-Amz-Credential=minioadmin`: as URLs são assinadas com o **root do MinIO**,
   e esse access key vai para o navegador de todo usuário que abre um vídeo;
3. `X-Amz-Expires=28800` — 8 horas.

### Certificado do ThemísIA

| Campo | Valor |
|---|---|
| Subject | `CN = *.mpgo.mp.br` |
| SAN | `DNS:*.mpgo.mp.br`, `DNS:mpgo.mp.br` |
| Emissor | GlobalSign GCC R3 DV TLS CA 2020 (**CA pública**) |
| Validade | 10/07/2026 a **25/01/2027** |

Por ser de CA pública, qualquer navegador confia — inclusive celular e máquina
fora do domínio. E o curinga cobre um nível: `intranet.mpgo.mp.br` está coberto,
`videos.mpgo.mp.br` também, mas `videos.intranet.mpgo.mp.br` **não**.

### Restrição que define o formato da URL

A assinatura SigV4 cobre o **caminho**, não só o `Host`. O MinIO recalcula a
assinatura a partir do caminho que recebe, e lê esse caminho como
`/<bucket>/<chave>`. Consequências:

- o proxy **não pode reescrever o path** — nem acrescentar nem remover prefixo;
- não existe "prefixo livre": **o primeiro segmento do caminho É o bucket**;
- não há configuração de "path base" no MinIO.

### Decisão: formato A

```text
https://intranet.mpgo.mp.br/themisia/    -> aplicação
https://intranet.mpgo.mp.br/memoriais/…  -> objetos do bucket "memoriais"
```

**Por quê:** o bucket já se chama `memoriais`, então não há migração de objetos
nem rewrite. Não exige certificado novo (o curinga já cobre `intranet.mpgo.mp.br`)
nem registro DNS. A mudança no backend é apenas o endpoint usado para assinar.

**Custo aceito:** `/memoriais/` passa a ser um caminho reservado na raiz da
intranet, e a rota de vídeo fica acoplada à configuração do NGINX do ThemísIA.

Alternativas descartadas:

| Opção | Motivo |
|---|---|
| `/themisia/videos/…` | exigiria renomear o bucket para `themisia` e migrar as chaves para o prefixo `videos/` |
| `videos.mpgo.mp.br` | mais limpo e sem colisão, mas exige registro DNS novo |

**Atenção à porta:** em `443` o header `Host` **não inclui a porta**.

```bash
MINIO_SERVER_URL=https://intranet.mpgo.mp.br      # correto
MINIO_SERVER_URL=https://intranet.mpgo.mp.br:443  # quebra a assinatura
```

No laboratório a porta aparece (`:8443`) porque não é a padrão do esquema. Essa
diferença é a forma mais provável de reproduzir `SignatureDoesNotMatch` na
migração.

---

## 1. Certificado atual do MinIO

Arquivo analisado: `vm-lnx-0369.intranet.mpgo.crt`

| Campo | Valor |
|---|---|
| Subject CN | `vm-lnx-0369.intranet.mpgo` |
| SAN | `DNS:vm-lnx-0369.intranet.mpgo`, `IP:10.234.46.4`, `IP:127.0.0.1` |
| Emissor | `Certificadora TLS do MP-GO` (CA interna) |
| Organização | Procuradoria Geral de Justiça de Goiás / Superintendência de Informática |
| Validade | 26/11/2025 a **02/09/2026** |
| Chave | RSA 2048, assinatura SHA-256 |
| Key Usage | `Digital Signature` (crítico) — **sem `Key Encipherment`** |
| Extended Key Usage | `TLS Web Server Authentication` |
| OCSP | `http://certificadora.intranet.mpgo/v1/certificadora_tls/ocsp` |
| CA Issuers | `http://certificadora.intranet.mpgo/v1/certificadora_tls/ca` |
| CRL | `http://certificadora.intranet.mpgo/v1/certificadora_tls/crl` |

### Observações

**Vencimento próximo.** Restam poucas semanas. Renovar antes de qualquer
implantação, e definir o processo de renovação junto com a Superintendência.

**Ausência de `Key Encipherment`.** O certificado não autoriza troca de chave
RSA estática. Na prática, use apenas ECDHE (TLS 1.2) e TLS 1.3 — que é o padrão
recomendado de qualquer forma. Evitar ciphersuites `TLS_RSA_*`.

**Nome de máquina, não de serviço.** `vm-lnx-0369` identifica o servidor. Não há
SAN para nenhum nome do tipo `videos.*`, e o sufixo é `.intranet.mpgo`, distinto
de `intranet.mpgo.mp.br`.

**Renovar o certificado NÃO invalida URLs pré-assinadas em circulação.** A
assinatura SigV4 cobre o `Host`, o método HTTP e a query string — não o
certificado TLS. Trocar o certificado mantendo o mesmo hostname é transparente
para os links já emitidos. O que invalidaria seria mudar o hostname ou a porta.

---

## 2. Hostname público — DECIDIDO (formato A, ver seção 0)

Mantido abaixo o comparativo que levou à decisão.

### Opção descartada — nome de serviço dedicado

Exemplo: `videos.intranet.mpgo.mp.br`

- exige registro DNS e **um certificado novo** emitido pela Certificadora TLS do MP-GO;
- o nome da máquina não aparece na URL entregue ao usuário;
- permite mover o serviço de servidor sem trocar URL nem quebrar links;
- é o que preserva a premissa da PoC: o usuário não sabe onde o storage está.

Configuração correspondente:

```bash
MINIO_SERVER_URL=https://videos.intranet.mpgo.mp.br
```

### Opção descartada — reaproveitar `vm-lnx-0369.intranet.mpgo`

- não exige pedir certificado novo (mas o atual vence em setembro/2026 mesmo assim);
- a URL do vídeo passa a revelar o nome da máquina;
- o proxy fica amarrado a esse servidor: trocar de host invalida todos os links;
- o certificado é do MinIO — usá-lo no proxy significa que proxy e MinIO
  compartilham identidade, o que confunde o diagnóstico e enfraquece a separação.

### Atenção à porta, nos dois casos

Em `443`, o header `Host` **não inclui a porta**. Então:

```bash
MINIO_SERVER_URL=https://videos.intranet.mpgo.mp.br     # correto
MINIO_SERVER_URL=https://videos.intranet.mpgo.mp.br:443 # quebra a assinatura
```

No laboratório a porta aparece (`:8443`) porque não é a padrão do esquema.
Essa diferença é a forma mais provável de reproduzir `SignatureDoesNotMatch`
no ambiente real.

---

## 3. Perna interna com TLS (decidido)

O proxy falará HTTPS com o MinIO, validando o certificado contra a CA do MP-GO.

### No MinIO

Instalar o par em `${MINIO_VOLUMES}/.minio/certs/`:

```text
public.crt   → vm-lnx-0369.intranet.mpgo.crt
private.key  → chave privada correspondente
```

E manter o `MINIO_SERVER_URL` apontando para o **hostname público do proxy**,
não para o nome da máquina. É isso que faz o MinIO aceitar a assinatura gerada
com o nome público.

### No NGINX

```nginx
upstream minio_s3 {
    server vm-lnx-0369.intranet.mpgo:9000;
    keepalive 16;
}

location / {
    proxy_pass https://minio_s3;

    # Host público — o que a assinatura cobre. NÃO muda por causa do TLS interno.
    proxy_set_header Host $http_host;

    # SNI e validação usam o nome do certificado do MinIO, que é DIFERENTE do
    # Host público. Sem proxy_ssl_name explícito, o NGINX usaria o nome do
    # bloco upstream ("minio_s3") e a validação falharia.
    proxy_ssl_name                vm-lnx-0369.intranet.mpgo;
    proxy_ssl_server_name         on;
    proxy_ssl_verify              on;
    proxy_ssl_verify_depth        2;
    proxy_ssl_trusted_certificate /etc/nginx/certs/mpgo-ca.crt;
    proxy_ssl_protocols           TLSv1.2 TLSv1.3;
    proxy_ssl_session_reuse       on;

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering         off;
    proxy_request_buffering off;
}
```

O certificado da CA sai de:

```bash
curl -o mpgo-ca.crt http://certificadora.intranet.mpgo/v1/certificadora_tls/ca
```

**O detalhe que quebra silenciosamente:** `proxy_set_header Host` e
`proxy_ssl_name` passam a ter valores diferentes de propósito. O primeiro é o
nome público que o cliente assinou; o segundo é o nome que o MinIO apresenta no
certificado. Confundir os dois produz ou `SignatureDoesNotMatch` (se o Host for
reescrito) ou falha de validação TLS (se o SNI for o nome público).

---

## 4. Diferenças entre laboratório e produção

| Item | Laboratório | Produção |
|---|---|---|
| Hostname | `intranet.lab.local` via `hosts` | `intranet.mpgo.mp.br` (já existe) |
| Porta pública | `8443` (aparece no `Host`) | `443` (não aparece no `Host`) |
| Certificado do proxy | autoassinado | emitido pela Certificadora TLS do MP-GO |
| Perna proxy → MinIO | HTTP | HTTPS validado contra a CA |
| HSTS | `max-age=0` de propósito | `86400` na implantação, `31536000` depois |
| Credencial de presign | usuário local somente-leitura | mesmo modelo, com rotação definida |
| Expiração da URL | 24h | alinhar à duração máxima de sessão |
| Exposição do MinIO | sem porta publicada no host | firewall liberando apenas o proxy |
| `limit_conn` | 100 por IP | revisar: usuários da intranet saem por NAT |
| Resolução do upstream | IP congelado no start | `resolver` ou reinício automatizado |

---

## 5. Checklist de migração

- [ ] renovar o certificado de `vm-lnx-0369.intranet.mpgo` (vence 02/09/2026)
- [x] definir o hostname público — formato A, `intranet.mpgo.mp.br/memoriais/`
- [ ] confirmar que `/memoriais/` não colide com rota existente na raiz da intranet
- [ ] obter o certificado da CA para o `proxy_ssl_trusted_certificate`
- [ ] instalar o par de chaves no MinIO e habilitar TLS
- [ ] configurar `MINIO_SERVER_URL` com o nome público **sem porta**
- [ ] configurar o NGINX conforme a seção 3
- [ ] criar o usuário de presign somente-leitura no MinIO de produção
- [ ] firewall: MinIO aceita conexão apenas do proxy
- [ ] validar com o mesmo roteiro do `scripts/04-test-access.sh`, adaptando o host
- [ ] confirmar que máquinas não ingressadas no domínio (celular, BYOD) não são
      público-alvo, ou distribuir a CA para elas
- [ ] definir HSTS e o momento de aumentar o `max-age`
- [ ] definir processo e responsável pela renovação do certificado

---

## 6. Pontos a confirmar com a Superintendência

1. O sufixo correto: o certificado usa `.intranet.mpgo`, mas o acesso dos
   funcionários foi descrito como `intranet.mpgo.mp.br`. São zonas diferentes?
2. A CA `Certificadora TLS do MP-GO` já está distribuída como confiável em todas
   as estações? Em dispositivos móveis também?
3. Qual o prazo e o procedimento para emissão de um certificado para nome de
   serviço novo?
4. Existe balanceador, WAF ou proxy corporativo entre o usuário e este servidor?
   Se existir, ele precisa preservar o header `Host` — caso contrário a
   assinatura quebra e o sintoma será `SignatureDoesNotMatch`.
