#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1

echo "=== FILE TREE ==="
find app -maxdepth 3 -type f | sort | sed -n '1,260p'

echo "=== COMPOSE ==="
sed -n '1,260p' docker-compose.yml

echo "=== DB TABLES ==="
docker exec matrix_v1_db psql -U ${POSTGRES_USER:-postgres} -d ${POSTGRES_DB:-postgres} -Atc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;" 2>/dev/null || docker exec matrix_v1_db psql -U postgres -Atc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;" 2>/dev/null || true

echo "=== SCRAPER MAIN HOOKS ==="
grep -nE '^def |^async def |lead_target|m2_|intelligence|run_job|process_job|status' app/scraper.py | sed -n '1,360p'

echo "=== MAIN API ROUTES ==="
grep -nE '^@app\.(get|post|put|delete)|^def |^async def ' app/main.py | sed -n '1,420p'

echo "=== INTELLIGENCE FILES ==="
find app/matrix_intelligence -maxdepth 2 -type f -print -exec sh -c 'echo "--- $1"; grep -nE "^def |^async def |CREATE TABLE|INSERT INTO|UPDATE " "$1" | head -180' _ {} \; 2>/dev/null | sed -n '1,780p'
