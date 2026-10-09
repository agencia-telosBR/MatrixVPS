#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== COMPOSE SERVICES/NETWORKS ==="
sed -n '1,260p' compose.yaml
echo "=== MAIN.PY STRUCTURE ==="
grep -nE "^@app\.|def |FastAPI|include_router|matrix_intelligence|StaticFiles" app/main.py | head -260
echo "=== DB HELPER ==="
grep -nE "def get_conn|DB_HOST|psycopg|connect" app/main.py | head -100
echo "=== N8N NETWORKS ==="
docker inspect sdr-n8n --format '{{json .NetworkSettings.Networks}}'
echo "=== MATRIX APP NETWORKS ==="
docker inspect matrix_v1_app --format '{{json .NetworkSettings.Networks}}'
echo "=== MATRIX INTEL NETWORKS ==="
docker inspect matrix_v1_intelligence --format '{{json .NetworkSettings.Networks}}'
