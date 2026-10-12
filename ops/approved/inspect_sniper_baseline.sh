#!/usr/bin/env bash
set -u
cd /opt/matrix-scraper-v1

echo "=== ROOT ==="
find . -maxdepth 1 -type f -printf '%f\n' | sort

echo "=== SNIPER V2 API ==="
sed -n '1,360p' app/sniper_v2/api.py

echo "=== SNIPER V2 CORE ==="
sed -n '1,520p' app/sniper_v2/core.py

echo "=== SNIPER V2 HTML ==="
sed -n '1,420p' app/sniper_v2/sniper.html

echo "=== MAIN SNIPER IMPORTS/ROUTES ==="
grep -n -A60 -B30 -E 'sniper_v2|matrix_intelligence|include_router' app/main.py | sed -n '1,520p'

echo "=== DB BOOTSTRAP ==="
sed -n '1,360p' app/db.py

echo "=== REQUIREMENTS ==="
cat app/requirements.txt

echo "=== DB TABLES VIA APP ENV ==="
docker exec matrix_v1_app python - <<'PY'
from db import get_conn
with get_conn() as conn:
  with conn.cursor() as cur:
    cur.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")
    print("\n".join(r[0] for r in cur.fetchall()))
PY
