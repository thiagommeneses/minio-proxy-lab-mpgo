import io
import os
import threading
import time
import urllib.request
import zipfile
from datetime import timedelta

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from minio import Minio, MinioAdmin
from minio.credentials import StaticProvider

BUCKET = os.environ["MINIO_BUCKET"]
OBJETO = os.environ["TEST_OBJECT"]
APP_HOST = os.environ["APP_HOST"]
MINIO_HOST = os.environ["MINIO_HOST"]
MINIO_ROOT_USER = os.environ["MINIO_ROOT_USER"]
MINIO_ROOT_PASSWORD = os.environ["MINIO_ROOT_PASSWORD"]
MINIO_LEITOR_USER = os.environ["MINIO_LEITOR_USER"]
MINIO_LEITOR_PASSWORD = os.environ["MINIO_LEITOR_PASSWORD"]
HORAS = int(os.environ["EXPIRA_HORAS"])
VIDEO_URL = os.environ["VIDEO_URL"]

app = FastAPI()

# Cliente que conversa com o MinIO pela rede interna.
admin = Minio("minio:9000", MINIO_ROOT_USER, MINIO_ROOT_PASSWORD, secure=True, cert_check=False)

# Mensagem de erro se algo falhar.
erro_preparo = ""


def cliente(endereco):
    """Cliente que assina as URLs, com o usuário leitor. Não acessa a rede."""
    return Minio(endereco, MINIO_LEITOR_USER, MINIO_LEITOR_PASSWORD, secure=True, region="us-east-1")


# Permissão única: ler objetos deste bucket. Nada de listar, gravar ou apagar.
POLICY = """{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::%s/*"]}]}"""


def criar_usuario_leitor():
    """Cria o usuário que assina as URLs, com permissão só de leitura."""
    adm = MinioAdmin("minio:9000", StaticProvider(MINIO_ROOT_USER, MINIO_ROOT_PASSWORD),
                     secure=True, cert_check=False)
    with open("/tmp/leitura.json", "w") as f:
        f.write(POLICY % BUCKET)
    adm.user_add(MINIO_LEITOR_USER, MINIO_LEITOR_PASSWORD)
    adm.policy_add("somente-leitura", "/tmp/leitura.json")
    adm.policy_set("somente-leitura", user=MINIO_LEITOR_USER)


def video_existe():
    try:
        admin.stat_object(BUCKET, OBJETO)
        return True
    except Exception:
        return False


def baixar_video():
    """Baixa o vídeo especificado no ENV. O site de origem se entrega um .zip, extraímos o .mp4 de dentro."""
    # O User-Agent é obrigatório: o servidor recusa o padrão do Python com 403.
    req = urllib.request.Request(VIDEO_URL, headers={"User-Agent": "Mozilla/5.0"})
    dados = urllib.request.urlopen(req, timeout=180).read()
    if dados[:2] == b"PK":
        z = zipfile.ZipFile(io.BytesIO(dados))
        nome = [n for n in z.namelist() if n.endswith(".mp4")][0]
        dados = z.read(nome)
    return dados


def preparar():
    """Cria o bucket e sobe o vídeo. Executa em segundo plano."""
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

        criar_usuario_leitor()

        if not video_existe():
            video = baixar_video()
            admin.put_object(BUCKET, OBJETO, io.BytesIO(video), len(video),
                             content_type="video/mp4")
    except Exception as e:
        erro_preparo = str(e)


@app.on_event("startup")
def iniciar():
    # Enquanto o vídeo é baixado. Inicia em segundo plano para o site responder na hora, sem gerar erro 502.
    threading.Thread(target=preparar, daemon=True).start()


CSS = """
  body { background: #fff; color: #222; font-family: Arial, sans-serif; margin: 24px; text-align: center; }
  h1 { font-size: 20px; }
  .caixa { display: inline-block; vertical-align: top; width: 400px;
           border: 1px solid #ccc; border-radius: 2px; padding: 12px; margin-right: 16px; }
  video { width: 100%; background: #000; }
  .errado { color: #c00; }
  .certo { color: #080; }
  small { color: #666; word-break: break-all; }
  .divisor { width: 70%; border: 0; height: 1px; background: linear-gradient(to right, transparent, #9ca3af, transparent); }
  margin: 2rem auto;
}

  .aviso { border: 1px solid #ccc; padding: 12px; max-width: 700px; }
"""


def html(corpo):
    return f"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><title>MemorIAis</title>
<style>{CSS}</style></head>
<body><h1>MemorIAis — acesso ao vídeo</h1><br><br>{corpo}</body></html>"""


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
          <p>A aplicação está preparando o vídeo, aguarde e recarregue a página.</p>
        </div>""")

    #########################################################################################################
    # As duas URLs são pré-assinadas aqui, cada uma para um endereço (interno e público) para demonstração. #
    #########################################################################################################
    url_interna = cliente(f"{MINIO_HOST}:9000").presigned_get_object(
        BUCKET, OBJETO, expires=timedelta(hours=HORAS))
    url_externa_com_proxy = cliente(f"{APP_HOST}:8443").presigned_get_object(
        BUCKET, OBJETO, expires=timedelta(hours=HORAS))

    return html(f"""
<div class="caixa">
  <h2 class="errado">Como é hoje</h2>
  <video controls src="{url_interna}"></video>
  <p>A URL aponta direto para o MinIO. O navegador não confia no certificado
     dele que é interno, então o vídeo não toca.</p>
     <hr class="divisor" />
     <br>
  <small>{url_interna[:500]}...</small>
</div>

<div class="caixa">
  <h2 class="certo">Como deveria ser</h2>
  <video controls src="{url_externa_com_proxy}"></video>
  <p>A URL aponta para o proxy, no mesmo endereço da aplicação. Certificado
     confiável e o MinIO fica escondido.</p>
     <hr class="divisor" />
     <br>
  <small>{url_externa_com_proxy[:500]}...</small>
</div>""")
