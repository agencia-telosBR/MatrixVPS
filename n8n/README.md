# Ponte n8n -> VPS

Objetivo: permitir ações controladas na VPS sem expor um shell arbitrário.

## Fluxo

Webhook POST -> validação de token -> SSH -> `/opt/matrix-scraper-v1/ops/matrix_control.sh`

## Ações permitidas

- `status`
- `regional_status`
- `maps_only`
- `logs`
- `restart_intelligence`
- `run_approved_patch`

## Patch atual

`remove_regional_map_keep_table`

Esse patch:
- desativa o PNG regional de 500 km;
- mantém a pesquisa regional;
- mantém `regional_top3` e `regional_bands`;
- mantém o mapa local;
- remove PNGs regionais antigos.

## Segurança

Não coloque neste repositório:
- senha da VPS;
- chave SSH privada;
- token do webhook;
- arquivos `.env`;
- credenciais do n8n.

Use credenciais do próprio n8n para SSH e um token secreto no header do webhook.
