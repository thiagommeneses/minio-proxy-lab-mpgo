# ---------------------------------------------------------------------------
# Encaminhamento para o MinIO. Incluído pelos blocos HTTP e HTTPS para
# garantir comportamento idêntico nos dois.
#
# NÃO adicionar rewrite aqui. A assinatura SigV4 cobre o Host, o método E o
# caminho. Qualquer alteração de path invalida a assinatura.
# ---------------------------------------------------------------------------

# Perna interna com TLS, como decidido para produção.
proxy_pass https://minio_s3;

# >>> O ponto crítico <<<
# Host público, exatamente como o cliente enviou. É o que a assinatura cobre.
proxy_set_header Host              $http_host;

proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# SNI e validação usam o nome do CERTIFICADO do MinIO, que é diferente do Host
# público de propósito. Sem proxy_ssl_name explícito o NGINX usaria o nome do
# bloco upstream ("minio_s3") e a validação falharia.
# Em produção: proxy_ssl_name vm-lnx-0369.intranet.mpgo, com a CA do MP-GO.
proxy_ssl_name                minio;
proxy_ssl_server_name         on;
proxy_ssl_verify              on;
proxy_ssl_verify_depth        2;
proxy_ssl_trusted_certificate /etc/nginx/certs/ca-interna.crt;
proxy_ssl_protocols           TLSv1.2 TLSv1.3;
proxy_ssl_session_reuse       on;

proxy_http_version 1.1;
proxy_set_header Connection "";

# Streaming: entrega os bytes conforme chegam. Sem isso o player trava.
proxy_buffering         off;
proxy_request_buffering off;

# Alto o bastante para upload de vídeo, mas explícito — diferente de 0.
client_max_body_size 5g;

# Generoso: um player abre várias conexões e, atrás de NAT, muitos usuários
# compartilham o mesmo IP. Revisar se virar produção.
limit_conn perip 100;

proxy_connect_timeout 30s;
proxy_send_timeout    300s;
proxy_read_timeout    300s;

# O header Range é repassado automaticamente (não há cache aqui), o que
# preserva o 206 Partial Content usado pelo seek do player.
