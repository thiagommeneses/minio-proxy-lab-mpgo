# Laboratório MinIO + proxy reverso

Mostra por que o vídeo do MemorIAis não abre no navegador e como resolver.

## O problema

A aplicação gera uma URL pré-assinada apontando direto para o MinIO:

```
https://vm-lnx-0369:9000/memoriais/depoimento.mp4?X-Amz-Signature=...
```

O navegador busca o vídeo nesse endereço, sem passar pela aplicação. Como o
certificado do MinIO é de uma CA interna, o navegador bloqueia e o vídeo não
toca. Dentro de um `<video>` isso acontece em silêncio, sem mensagem de erro.

## A solução

A URL passa a apontar para o proxy, no mesmo endereço da aplicação:

```
https://intranet.mpgo.mp.br/memoriais/depoimento.mp4?X-Amz-Signature=...
```

O proxy repassa a requisição ao MinIO. O navegador só conversa com um endereço,
que tem certificado confiável, e o MinIO fica escondido.

## O detalhe que quebra tudo

A assinatura da URL protege o **hostname** e o **caminho**. Por isso:

- a URL tem que ser **gerada** já com o endereço do proxy;
- o proxy não pode trocar o `Host` (`proxy_set_header Host $http_host`);
- o proxy não pode mudar o caminho — o primeiro pedaço dele é o nome do bucket.

Se qualquer um desses três mudar, o MinIO responde `SignatureDoesNotMatch`.

## Quem assina a URL

O usuário que assina fica **visível na URL**, no parâmetro `X-Amz-Credential`:

```
...&X-Amz-Credential=leitor-videos%2F20260806%2Fus-east-1%2Fs3%2Faws4_request&...
```

Hoje, em produção, esse valor é `minioadmin` — o administrador do MinIO vai para
o navegador de todo usuário que abre um vídeo.

Aqui a aplicação cria um usuário `leitor-videos` com uma permissão só:

```json
{"Effect": "Allow", "Action": ["s3:GetObject"], "Resource": ["arn:aws:s3:::memoriais/*"]}
```

Ele lê objetos do bucket e nada mais — não lista, não grava, não apaga, não
enxerga outros buckets. Se a URL vazar, o que vaza é essa identidade.

Dá para conferir no console do MinIO, em **Identity → Users**.

## Como rodar

Adicione no arquivo de hosts do Windows
(`C:\Windows\System32\drivers\etc\hosts`, como administrador):

```
127.0.0.1  intranet.lab.local
127.0.0.1  vm-lnx-0369.lab.local
```

Depois, no WSL:

```bash
cp .env.example .env
bash certs.sh
docker compose up -d --build
```

Lembrete: o `.env` fica sem ir no commit para o repositório no GitHub.

- Instale `certs/ca-publica.crt` como confiável no Host de teste Windows (Usuário), conforme o comando no script indicado.
  Exemplo (executar no PowerShell como Admin):  `Import-Certificate -FilePath .\certs\ca-publica.crt -CertStoreLocation Cert:\LocalMachine\Root`
- Reinicie o navegador. **Não instale a `ca-interna.crt`** — ela precisa continuar não confiável para a demonstração fazer sentido.

O primeiro start baixa o vídeo de teste e leva cerca de um minuto. Depois disso
ele fica guardado, então `docker compose down` e `up` são rápidos.

Se o download falhar, a página avisa. Nesse caso abra o console do MinIO,
crie o bucket `memoriais` se não existir e suba qualquer `.mp4` com o nome
`depoimento.mp4`.

Só o `docker compose down -v` apaga o vídeo — evite antes de uma apresentação,
porque o próximo start vai precisar de internet para baixar de novo.

## O que abrir

| Endereço | O que é |
|---|---|
| https://intranet.lab.local:8443/ | a demonstração, com os dois players |
| https://vm-lnx-0369.lab.local:9001/ | console do MinIO (login no `.env`) |

Na página, o player da esquerda não toca e o da direita sim. É a diferença
entre buscar o vídeo no MinIO e buscar no proxy.

## Arquivos

```
docker-compose.yml   os três serviços
nginx.conf           o proxy
certs.sh             gera os certificados
.env.example         modelo de configuração (copie para .env)
app/main.py          a aplicação
```

## Conferindo pelo terminal

Para a URL pré-assinada os comandos abaixo pegam a URL direto da página.

No WSL:

```bash
URL=$(curl -ks https://intranet.lab.local:8443/ \
      | grep -o 'https://intranet[^"]*X-Amz-Signature=[a-f0-9]*' | head -1)

curl -k -s -o /dev/null -w '%{http_code}\n' "$URL"            # 200 — vídeo entregue
curl -k -s -r 0-1023 -o /dev/null -w '%{http_code}\n' "$URL"  # 206 — pedaço do vídeo
```

No PowerShell:

```powershell
$html = (curl.exe -ks https://intranet.lab.local:8443/) -join "`n"
$URL  = [regex]::Match($html, 'https://intranet[^"]*X-Amz-Signature=[a-f0-9]+').Value

curl.exe -k -s -o NUL -w "%{http_code}`n" $URL
curl.exe -k -s -r 0-1023 -o NUL -w "%{http_code}`n" $URL
```

O `206` é o mesmo tipo de resposta que o player usa quando você arrasta a barra
do vídeo: ele pede só o trecho que precisa, em vez do arquivo inteiro.

Sem a assinatura, o MinIO recusa:

```bash
curl -k -s -o /dev/null -w '%{http_code}\n' \
     https://intranet.lab.local:8443/memoriais/depoimento.mp4   # 403 — esperado
```

Para ver o `Host` que chegou no proxy e o trecho pedido em cada requisição:

```bash
docker compose logs nginx
```

### Dois erros comuns

**Não use `curl -I`.** A assinatura protege também o método HTTP, e a URL foi
assinada para `GET`. Um `HEAD` devolve `403` mesmo com tudo funcionando.

**Não escape a URL.** Se colar a URL à mão, use aspas simples e não acrescente
`\` antes de `?`, `=` ou `&`. A contrabarra entra no caminho, muda o que foi
assinado e o resultado é `403`. No log do nginx isso aparece como
`depoimento.mp4\x5C`.
