#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1

echo "=== APP TREE ==="
find app -maxdepth 3 -type f | sort | sed -n '1,260p'

echo "=== INTELLIGENCE MODULES ==="
for f in app/matrix_intelligence/*.py; do echo "--- $f"; grep -nE '^def |^async def |^class |CREATE TABLE|ALTER TABLE|INSERT INTO|UPDATE ' "$f" | sed -n '1,220p'; done

echo "=== DB TABLES ==="
docker exec matrix_v1_db psql -U postgres -d matrix -Atc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;" | sed -n '1,260p'

echo "=== KEY TABLE SCHEMAS ==="
for t in scrape_jobs searches search_results companies matrix_intelligence_jobs matrix_intelligence_companies matrix_intelligence_regional_jobs matrix_intelligence_regional_searches matrix_intelligence_regional_candidates; do
  echo "--- $t"
  docker exec matrix_v1_db psql -U postgres -d matrix -Atc "SELECT column_name||'|'||data_type||'|'||coalesce(column_default,'') FROM information_schema.columns WHERE table_schema='public' AND table_name='$t' ORDER BY ordinal_position;"
done

echo "=== MAIN ROUTES ==="
grep -nE '^@app\.(get|post|put|delete)' app/main.py | sed -n '1,260p'

echo "=== REQUIREMENTS ==="
cat app/requirements.txt 2>/dev/null || cat requirements.txt 2>/dev/null || true
