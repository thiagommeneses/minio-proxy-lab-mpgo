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

O `.env` fica de fora do git, então senhas nunca vão para o repositório.

Instale `certs/ca-boa.crt` como confiável no Windows, conforme o script indica,
e reinicie o navegador. **Não instale a `ca-ruim.crt`** — ela precisa continuar
não confiável para a demonstração fazer sentido.

O primeiro start baixa o vídeo de teste e leva cerca de um minuto.

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

```bash
# o proxy entrega o vídeo
curl -k -s -o /dev/null -w '%{http_code}\n' "<url do player da direita>"   # 200

# adiantar o vídeo funciona (é o que o player faz ao arrastar a barra)
curl -k -s -r 0-1023 -o /dev/null -w '%{http_code}\n' "<mesma url>"        # 206

# sem a assinatura não passa
curl -k -s -o /dev/null -w '%{http_code}\n' "https://intranet.lab.local:8443/memoriais/depoimento.mp4"  # 403

# ver o Host que chegou no proxy
docker compose logs nginx
```

Use `GET` e não `curl -I`. A assinatura também protege o método, e ela foi
gerada para `GET` — um `HEAD` devolve `403` mesmo estando tudo certo.
