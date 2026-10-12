#!/usr/bin/env bash
set -u
cd /opt/matrix-scraper-v1

echo "=== SNIPER API FUNCTIONS ==="
grep -nE '^def |^async def |@router\.|CREATE TABLE|ALTER TABLE|INSERT INTO|UPDATE |DELETE FROM|register' app/sniper_v2/api.py | sed -n '1,520p'

echo "=== SNIPER API 220-760 ==="
sed -n '220,760p' app/sniper_v2/api.py

echo "=== SNIPER MAIN REFERENCES ==="
grep -RIn --exclude-dir=__pycache__ 'sniper_v2\|register_sniper\|/api/sniper\|sniper.html' app | sed -n '1,260p'

echo "=== DB TABLES ==="
docker exec matrix_v1_app python -c "from db import get_conn; c=get_conn(); cur=c.cursor(); cur.execute(\"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename\"); print('\\n'.join(r['tablename'] for r in cur.fetchall())); cur.close(); c.close()" || true

echo "=== SNIPER TABLE DEFINITIONS ==="
docker exec matrix_v1_app python -c "from db import get_conn; c=get_conn(); cur=c.cursor(); cur.execute(\"SELECT table_name,column_name,data_type FROM information_schema.columns WHERE table_schema='public' AND table_name LIKE 'sniper%' ORDER BY table_name,ordinal_position\"); [print(r) for r in cur.fetchall()]; cur.close(); c.close()" || true
