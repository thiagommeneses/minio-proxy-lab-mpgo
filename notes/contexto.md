# Contexto

Origem da demanda, transcrições e material de apoio.

## Demanda original

Conversa com o André sobre o fluxo atual de entrega de vídeos: a URL
pré-assinada gerada pelo MinIO aponta diretamente para o endpoint do storage,
expondo a infraestrutura ao cliente final.

## Material de apoio

- `MapaDoProjeto.png` — diagrama do fluxo discutido.

## Glossário

| Termo | Significado |
|---|---|
| "Miniayô" (transcrição) | MinIO |
| URL pré-assinada | URL temporária assinada com SigV4, dá acesso ao objeto sem credencial |
| SigV4 | AWS Signature Version 4, algoritmo de assinatura usado pelo protocolo S3 |
