# Resultados e evidências

Comprovações do funcionamento, para discussão com o time.

## Placar dos critérios de sucesso

| # | Critério | Status | Evidência |
|---|---|---|---|
| 1 | Vídeo abre e reproduz | pendente | |
| 2 | Acesso exclusivo pelo proxy | pendente | |
| 3 | MinIO não exposto diretamente | pendente | |
| 4 | Certificado apresentado é o do proxy | pendente | |
| 5 | URL expira e retorna 403 | pendente | |
| 6 | Seek funciona (206 Partial Content) | pendente | |
| 7 | Reprodutível do zero | pendente | |
| 8 | Documentado | pendente | |

## Evidências

<!--
Anexar aqui:
- print do vídeo reproduzindo com a URL do proxy na barra de endereço
- print do certificado apresentado
- saída de scripts/04-test-access.sh
- saída mostrando 403 após a expiração
- comprovação de que o MinIO não responde em 127.0.0.1:9000
- trechos de log do NGINX (o log_format 'lab' mostra host, status e range)
-->

## Observações para o ambiente real

<!-- Preencher ao final da PoC, alimentando a seção 18 do CLAUDE.md. -->
