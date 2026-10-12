#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/matrix-scraper-v1
cd "$ROOT"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT/backup-sniper-v3-$TS"
mkdir -p "$BACKUP"
cp app/main.py "$BACKUP/main.py"
cp app/index.html "$BACKUP/index.html"
[ -d app/sniper_v3 ] && cp -a app/sniper_v3 "$BACKUP/sniper_v3" || true

echo "[1/8] Download Matrix Sniper V3"
mkdir -p app/sniper_v3
BASE="https://raw.githubusercontent.com/agencia-telosBR/MatrixVPS/500e8c0db2e02822d162454cd76fba441e3735af/ops/sniper_v3"
for f in __init__.py core.py research.py api.py sniper.html schema.sql; do
  curl -fsSL "$BASE/$f" -o "app/sniper_v3/$f"
done

echo "[2/8] Register routes in FastAPI"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/main.py')
s=p.read_text()
block='''\n# ===== MATRIX SNIPER V3 / ACCOUNT INTELLIGENCE =====\nfrom sniper_v3 import register_sniper_v3_routes\nregister_sniper_v3_routes(app, get_conn, require_user)\n'''
if 'register_sniper_v3_routes' not in s:
    s=s.rstrip()+block+'\n'
p.write_text(s)
PY

echo "[3/8] Add Sniper entry point to Matrix UI"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/index.html')
s=p.read_text()
marker='matrix-sniper-entry-v3'
if marker not in s:
    widget='''<a id="matrix-sniper-entry-v3" href="/sniper" style="position:fixed;right:18px;bottom:18px;z-index:9999;background:#20df82;color:#042217;text-decoration:none;font:800 13px system-ui;padding:11px 15px;border-radius:999px;box-shadow:0 8px 28px #0008">SNIPER · ACCOUNT INTELLIGENCE</a>'''
    s=s.replace('</body>',widget+'\n</body>')
p.write_text(s)
PY

echo "[4/8] Static compile/preflight"
python3 -m py_compile app/sniper_v3/core.py app/sniper_v3/research.py app/sniper_v3/api.py app/main.py
echo "PY_COMPILE_OK"

echo "[5/8] Apply database schema"
docker cp app/sniper_v3/schema.sql matrix_v1_app:/tmp/sniper_v3_schema.sql
docker exec matrix_v1_app python -c "from db import get_conn; c=get_conn(); c.execute(open('/tmp/sniper_v3_schema.sql',encoding='utf-8').read()); c.commit(); c.close(); print('SCHEMA_OK')"

echo "[6/8] Rebuild/recreate app"
docker compose build app >/tmp/sniper-v3-build.log 2>&1 || { tail -220 /tmp/sniper-v3-build.log; exit 1; }
docker compose up -d --force-recreate app >/tmp/sniper-v3-up.log 2>&1 || { cat /tmp/sniper-v3-up.log; exit 1; }
sleep 6

echo "[7/8] Verify live"
docker exec matrix_v1_app python -c "import main; paths={r.path for r in main.app.routes}; required={'/sniper','/api/sniper/health','/api/sniper/query-plan','/api/sniper/accounts','/api/sniper/approved','/api/sniper/jobs/{job_id}/research'}; missing=required-paths; assert not missing,missing; print('LIVE_ROUTES_OK',len(paths))"
docker exec matrix_v1_app python -c "from sniper_v3.core import query_plan,deterministic_score; q=query_plan('São Paulo','SP',['Tucuruvi'],['chiller_rental','chiller_maintenance']); assert len(q)>=6; x=deterministic_score({'services_confirmed':[{'service_id':'chiller_rental'}],'b2b_confirmed':True,'entity_resolution_ok':True,'active':True,'source_count':2,'primary_source_count':1,'segments_served':[{}],'geography_evidenced':True,'google_presence':{'queries_checked':4,'coverage_score':25,'competitive_gap_score':60,'reputation_gap_score':30,'site_gap_score':0},'maturity':{'b2b_maturity_score':60,'industrial_depth_score':70},'trigger_signals':[],'research_confidence':.85}); assert 0 <= x['score'] <= 100; print('CORE_PREFLIGHT_OK',len(q),x['score'],x['tier'])"
docker exec matrix_v1_app python -c "from db import get_conn; c=get_conn(); cur=c.cursor(); cur.execute(\"SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'matrix_%' ORDER BY tablename\"); tables={r['tablename'] for r in cur.fetchall()}; required={'matrix_accounts','matrix_account_evidence','matrix_account_services','matrix_google_observations','matrix_account_signals','matrix_research_packs','matrix_research_queue','matrix_source_cache'}; assert required <= tables,required-tables; print('LIVE_SCHEMA_OK',len(tables)); cur.close(); c.close()"

echo "[8/8] Health"
docker ps --filter name=matrix_v1_app --filter name=matrix_v1_worker --filter name=matrix_v1_intelligence --format '{{.Names}}|{{.Status}}'
echo "BACKUP=$BACKUP"
echo "SNIPER_V3_DEPLOY_OK"
