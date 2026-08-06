"""
ThemísIA / MemorIAis — simulação mínima do fluxo de vídeo do MP-GO.

O que esta aplicação reproduz, e por que cada parte importa:

1. A página é servida pelo proxy, em https://intranet.lab.local:8443/themisia/,
   com um certificado que o navegador confia (ca-publica, que simula a
   GlobalSign do curinga *.mpgo.mp.br).

2. A URL pré-assinada é gerada NA LISTAGEM, não no clique do play — é como o
   ThemísIA funciona hoje. Isso importa para a decisão de expiração: o relógio
   começa a correr quando a lista é montada, não quando o usuário aperta play.

3. O player apenas usa a URL como `src`. O GET da mídia sai do navegador
   DIRETO para o endereço da URL, sem passar pelo backend. É esse salto que
   determina de quem é o certificado que o usuário precisa confiar.

4. Dois players lado a lado:
     - "atual"  -> URL apontando direto para o MinIO (vm-lnx-0369.lab.local),
                   cujo certificado vem da ca-interna, não instalada.
     - "correto"-> URL apontando para o proxy, no mesmo host da aplicação.

   A falha do primeiro é SILENCIOSA: dentro de um <video> não existe
   "Avançado -> prosseguir". O vídeo simplesmente não toca. É por isso que o
   problema é difícil de diagnosticar e que testes com `curl -k` não o pegam.
"""

import os
from datetime import timedelta

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from minio import Minio

app = FastAPI(title="ThemísIA (simulação)", root_path="/themisia")

# --- configuração ----------------------------------------------------------

BUCKET = os.environ["MINIO_BUCKET"]
OBJECT_KEY = os.environ["TEST_OBJECT"]

PUBLIC_HOST = os.environ["PUBLIC_HOST"]
PUBLIC_PORT = os.environ["NGINX_HTTPS_PORT"]
PROXY_ENDPOINT = f"{PUBLIC_HOST}:{PUBLIC_PORT}"

DIRECT_HOST = os.environ["MINIO_DIRECT_HOST"]
DIRECT_PORT = os.environ["MINIO_DIRECT_PORT"]
DIRECT_ENDPOINT = f"{DIRECT_HOST}:{DIRECT_PORT}"

ACCESS_KEY = os.environ["MINIO_PRESIGN_USER"]
SECRET_KEY = os.environ["MINIO_PRESIGN_PASSWORD"]
EXPIRY_HOURS = int(os.environ.get("PRESIGN_EXPIRY_HOURS", "24"))


def _client(endpoint: str) -> Minio:
    """
    Cliente usado só para assinar. A região é fixada de propósito: sem ela o
    SDK faria uma chamada de descoberta ao servidor, e assinar uma URL não
    precisa de rede nenhuma — é cálculo local sobre host, método, caminho e
    query string.
    """
    return Minio(
        endpoint,
        access_key=ACCESS_KEY,
        secret_key=SECRET_KEY,
        secure=True,
        region="us-east-1",
    )


def presigned(endpoint: str) -> str:
    return _client(endpoint).presigned_get_object(
        BUCKET, OBJECT_KEY, expires=timedelta(hours=EXPIRY_HOURS)
    )


# --- apresentação ----------------------------------------------------------

CSS = """
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body { font-family: system-ui, -apple-system, Segoe UI, sans-serif;
       margin: 0; padding: 1.5rem; line-height: 1.5; }
h1 { font-size: 1.25rem; margin: 0 0 .25rem; }
.sub { color: #666; font-size: .85rem; margin-bottom: 1.25rem; }
.tabs { display: flex; gap: .25rem; border-bottom: 2px solid #d0d0d0; margin-bottom: 1.25rem; }
.tabs button { border: 0; background: none; padding: .6rem 1.1rem; font-size: .95rem;
               cursor: pointer; border-bottom: 3px solid transparent; margin-bottom: -2px; }
.tabs button.on { border-bottom-color: #0b5fff; font-weight: 600; }
.grid { display: grid; gap: 1.25rem; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); }
.card { border: 1px solid #d0d0d0; border-radius: 8px; padding: 1rem; }
.card.bad { border-color: #d13438; }
.card.good { border-color: #107c10; }
.tag { display: inline-block; font-size: .7rem; font-weight: 700; letter-spacing: .04em;
       padding: .15rem .5rem; border-radius: 4px; text-transform: uppercase; }
.tag.bad { background: #d13438; color: #fff; }
.tag.good { background: #107c10; color: #fff; }
video { width: 100%; border-radius: 6px; background: #000; margin: .75rem 0 .5rem; }
code { font-size: .72rem; word-break: break-all; display: block; background: #00000010;
       padding: .5rem; border-radius: 4px; margin-top: .5rem; }
.status { font-size: .8rem; font-weight: 600; margin-top: .5rem; }
.nota { font-size: .85rem; background: #00000008; border-left: 3px solid #999;
        padding: .75rem 1rem; margin-top: 1.5rem; border-radius: 0 4px 4px 0; }
"""


def page() -> str:
    return f"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<title>ThemísIA — simulação</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<script src="https://unpkg.com/htmx.org@2.0.4"></script>
<style>{CSS}</style></head>
<body>
  <h1>ThemísIA</h1>
  <div class="sub">Simulação do fluxo de vídeo — laboratório MinIO + proxy reverso</div>

  <div class="tabs">
    <button class="on" hx-get="aba/processo" hx-target="#conteudo"
            onclick="document.querySelectorAll('.tabs button').forEach(b=>b.classList.remove('on'));
                     this.classList.add('on')">Processo</button>
    <button hx-get="aba/memoriais" hx-target="#conteudo"
            onclick="document.querySelectorAll('.tabs button').forEach(b=>b.classList.remove('on'));
                     this.classList.add('on')">MemorIAis</button>
  </div>

  <div id="conteudo" hx-get="aba/processo" hx-trigger="load"></div>
</body></html>"""


def card(titulo: str, classe: str, tag: str, url: str, explicacao: str, ident: str) -> str:
    return f"""
    <div class="card {classe}">
      <span class="tag {classe}">{tag}</span>
      <strong style="margin-left:.5rem">{titulo}</strong>
      <video controls preload="metadata" src="{url}" id="v-{ident}"></video>
      <div class="status" id="s-{ident}">verificando…</div>
      <div style="font-size:.85rem;color:#666;margin-top:.5rem">{explicacao}</div>
      <code>{url[:120]}…</code>
    </div>"""


# --- rotas -----------------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return page()


@app.get("/aba/processo", response_class=HTMLResponse)
def aba_processo() -> str:
    return """
    <p>Aba que representa o ThemísIA propriamente dito. Nada aqui depende do
    MinIO — serve para mostrar que a aplicação e a mídia convivem no mesmo
    host público, separadas apenas por caminho:</p>
    <ul>
      <li><code style="display:inline">/themisia/</code> → esta aplicação</li>
      <li><code style="display:inline">/memoriais/</code> → objetos do MinIO,
          servidos pelo proxy</li>
    </ul>
    <div class="nota">
      O primeiro segmento do caminho de mídia é o <strong>nome do bucket</strong>.
      Ele não pode ser reescrito pelo proxy: a assinatura SigV4 cobre o caminho
      além do <code style="display:inline">Host</code>, então um
      <code style="display:inline">rewrite</code> produziria
      <code style="display:inline">SignatureDoesNotMatch</code>.
    </div>"""


@app.get("/aba/memoriais", response_class=HTMLResponse)
def aba_memoriais() -> str:
    # As duas URLs são geradas AQUI, na listagem — como no ThemísIA real.
    url_direta = presigned(DIRECT_ENDPOINT)
    url_proxy = presigned(PROXY_ENDPOINT)

    return f"""
    <p style="margin-top:0">Depoimento — <code style="display:inline">{OBJECT_KEY}</code></p>

    <div class="grid">
      {card("Caminho atual", "bad", "quebrado", url_direta,
            f"URL aponta direto para o MinIO ({DIRECT_HOST}). O certificado vem "
            "da CA interna, que o navegador não conhece. A falha é silenciosa: "
            "dentro de um &lt;video&gt; não há opção de prosseguir.", "ruim")}
      {card("Caminho proposto", "good", "correto", url_proxy,
            f"URL aponta para o proxy, no mesmo host da aplicação "
            f"({PUBLIC_HOST}). Certificado confiável, MinIO invisível.", "bom")}
    </div>

    <div class="nota">
      Ambas as URLs foram assinadas nesta requisição, com validade de
      {EXPIRY_HOURS}h. A assinatura cobre o <code style="display:inline">Host</code>,
      então são assinaturas diferentes para o mesmo objeto — não é a mesma URL
      com o endereço trocado.
    </div>

    <script>
    // Torna visível a falha que o <video> esconde: tenta buscar 1 byte e
    // reporta o motivo. Erro de certificado rejeita a promise sem status.
    async function checar(id, url) {{
      const el = document.getElementById('s-' + id);
      try {{
        const r = await fetch(url, {{ headers: {{ 'Range': 'bytes=0-0' }} }});
        el.textContent = r.status === 206 || r.status === 200
          ? '\\u2705 mídia acessível (HTTP ' + r.status + ')'
          : '\\u26a0\\ufe0f HTTP ' + r.status;
        el.style.color = r.ok ? '#107c10' : '#d13438';
      }} catch (e) {{
        el.textContent = '\\u274c bloqueado pelo navegador — certificado não confiável';
        el.style.color = '#d13438';
      }}
    }}
    checar('ruim', {url_direta!r});
    checar('bom', {url_proxy!r});
    </script>"""


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True, "bucket": BUCKET, "proxy": PROXY_ENDPOINT, "direto": DIRECT_ENDPOINT}
