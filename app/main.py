import io
import os
import threading
import time
import urllib.request
import zipfile
from datetime import timedelta

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from minio import Minio

BUCKET = os.environ["MINIO_BUCKET"]
OBJETO = os.environ["TEST_OBJECT"]
APP_HOST = os.environ["APP_HOST"]
MINIO_HOST = os.environ["MINIO_HOST"]
USUARIO = os.environ["MINIO_ROOT_USER"]
SENHA = os.environ["MINIO_ROOT_PASSWORD"]
HORAS = int(os.environ["EXPIRA_HORAS"])
VIDEO_URL = os.environ["VIDEO_URL"]

app = FastAPI()

# Cliente que fala com o MinIO de verdade, pela rede interna.
admin = Minio("minio:9000", USUARIO, SENHA, secure=True, cert_check=False)

# Mensagem de erro do preparo, mostrada na página se algo falhar.
erro_preparo = ""


def cliente(endereco):
    """Cliente usado só para assinar URLs. Não acessa a rede."""
    return Minio(endereco, USUARIO, SENHA, secure=True, region="us-east-1")


def video_existe():
    try:
        admin.stat_object(BUCKET, OBJETO)
        return True
    except Exception:
        return False


def baixar_video():
    """Baixa o vídeo. A origem entrega um .zip, então extrai o .mp4 de dentro."""
    # O User-Agent é obrigatório: o servidor recusa o padrão do Python com 403.
    req = urllib.request.Request(VIDEO_URL, headers={"User-Agent": "Mozilla/5.0"})
    dados = urllib.request.urlopen(req, timeout=180).read()
    if dados[:2] == b"PK":
        z = zipfile.ZipFile(io.BytesIO(dados))
        nome = [n for n in z.namelist() if n.endswith(".mp4")][0]
        dados = z.read(nome)
    return dados


def preparar():
    """Cria o bucket e sobe o vídeo. Roda em segundo plano."""
    global erro_preparo
    try:
        for _ in range(30):  # espera o MinIO ficar de pé
            try:
                admin.list_buckets()
                break
            except Exception:
                time.sleep(2)

        if not admin.bucket_exists(BUCKET):
            admin.make_bucket(BUCKET)

        if not video_existe():
            video = baixar_video()
            admin.put_object(BUCKET, OBJETO, io.BytesIO(video), len(video),
                             content_type="video/mp4")
    except Exception as e:
        erro_preparo = str(e)


@app.on_event("startup")
def iniciar():
    # Em segundo plano para o site responder na hora, sem 502 enquanto baixa.
    threading.Thread(target=preparar, daemon=True).start()


CSS = """
  body { background: #fff; color: #222; font-family: Arial, sans-serif; margin: 24px; }
  h1 { font-size: 20px; }
  .caixa { display: inline-block; vertical-align: top; width: 400px;
           border: 1px solid #ccc; padding: 12px; margin-right: 16px; }
  video { width: 100%; background: #000; }
  .errado { color: #c00; }
  .certo { color: #080; }
  small { color: #666; word-break: break-all; }
  .aviso { border: 1px solid #ccc; padding: 12px; max-width: 700px; }
"""


def html(corpo):
    return f"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><title>MemorIAis</title>
<style>{CSS}</style></head>
<body><h1>MemorIAis — acesso ao vídeo</h1>{corpo}</body></html>"""


@app.get("/", response_class=HTMLResponse)
def pagina():
    if not video_existe():
        if erro_preparo:
            return html(f"""<div class="aviso">
              <p class="errado">Não consegui preparar o vídeo:</p>
              <p><small>{erro_preparo}</small></p>
              <p>Suba um .mp4 chamado <b>{OBJETO}</b> no bucket <b>{BUCKET}</b>
                 pelo console em https://{MINIO_HOST}:9001/ e recarregue.</p>
            </div>""")
        return html("""<div class="aviso">
          <p>Preparando o vídeo, aguarde e recarregue a página.</p>
        </div>""")

    # As duas URLs são assinadas aqui, cada uma para um endereço diferente.
    url_errada = cliente(f"{MINIO_HOST}:9000").presigned_get_object(
        BUCKET, OBJETO, expires=timedelta(hours=HORAS))
    url_certa = cliente(f"{APP_HOST}:8443").presigned_get_object(
        BUCKET, OBJETO, expires=timedelta(hours=HORAS))

    return html(f"""
<div class="caixa">
  <h2 class="errado">Como é hoje</h2>
  <video controls src="{url_errada}"></video>
  <p>A URL aponta direto para o MinIO. O navegador não confia no certificado
     dele, então o vídeo não toca.</p>
  <small>{url_errada[:70]}...</small>
</div>

<div class="caixa">
  <h2 class="certo">Como deveria ser</h2>
  <video controls src="{url_certa}"></video>
  <p>A URL aponta para o proxy, no mesmo endereço da aplicação. Certificado
     confiável e o MinIO fica escondido.</p>
  <small>{url_certa[:70]}...</small>
</div>""")
