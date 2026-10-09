#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== intelligence/api.py ==="
sed -n '1,320p' app/matrix_intelligence/api.py
echo "=== intelligence db refs ==="
grep -RIn "def get_conn\|psycopg.connect\|connect(" app/matrix_intelligence | head -100
echo "=== search schemas ==="
docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' <<'SQL'
SELECT table_name||'|'||column_name||'|'||data_type
FROM information_schema.columns
WHERE table_name IN ('searches','search_results','company_m2_analysis','m2_company_analysis','m2_analyses')
ORDER BY table_name,ordinal_position;
SQL
