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
BASE="https://raw.githubusercontent.com/agencia-telosBR/MatrixVPS/78fc63f7b2eed131ea85860b5d5d1e3bd544c507/ops/sniper_v3"
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

echo "[4/9] Integrate persistent Sniper research worker"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/worker.py')
s=p.read_text()
if 'from sniper_v3.research import enqueue_job, process_queue' not in s:
    s=s.replace('from enricher import enrichment_loop\n',
                'from enricher import enrichment_loop\nfrom sniper_v3.research import enqueue_job, process_queue\n')
helper='''

def _enqueue_sniper_if_completed(job_id):
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT status FROM scrape_jobs WHERE id=%s",(job_id,))
                row=cur.fetchone()
            if row and row["status"] in ("completed","completed_with_errors"):
                total=enqueue_job(conn,job_id)
                print(f"[sniper] job {job_id} enfileirado: {total} contas",flush=True)
    except Exception as exc:
        print(f"[sniper] falha ao enfileirar job {job_id}: {type(exc).__name__}: {exc}",flush=True)

async def sniper_research_loop():
    print("[sniper] Account Research worker iniciado",flush=True)
    while True:
        try:
            result=await asyncio.to_thread(process_queue,get_conn,None,1)
            await asyncio.sleep(0.4 if result.get("processed") else 4.0)
        except Exception as exc:
            print(f"[sniper] fila falhou: {type(exc).__name__}: {exc}",flush=True)
            await asyncio.sleep(5.0)
'''
if '_enqueue_sniper_if_completed' not in s:
    s=s.replace('\nasync def discovery_loop():',helper+'\nasync def discovery_loop():')
if 'await asyncio.to_thread(_enqueue_sniper_if_completed, job_id)' not in s:
    s=s.replace('            await run_job(job_id)\n',
                '            await run_job(job_id)\n            await asyncio.to_thread(_enqueue_sniper_if_completed, job_id)\n')
if 'sniper_research_loop(),' not in s:
    s=s.replace('        enrichment_loop(),\n', '        enrichment_loop(),\n        sniper_research_loop(),\n')
p.write_text(s)
PY

echo "[5/9] Static compile/preflight"
python3 -m py_compile app/sniper_v3/core.py app/sniper_v3/research.py app/sniper_v3/api.py app/main.py
echo "PY_COMPILE_OK"

echo "[6/9] Apply database schema"
docker cp app/sniper_v3/schema.sql matrix_v1_app:/tmp/sniper_v3_schema.sql
docker exec matrix_v1_app python -c "from db import get_conn; c=get_conn(); c.execute(open('/tmp/sniper_v3_schema.sql',encoding='utf-8').read()); c.commit(); c.close(); print('SCHEMA_OK')"

echo "[7/9] Rebuild/recreate app + worker"
docker compose build app worker >/tmp/sniper-v3-build.log 2>&1 || { tail -220 /tmp/sniper-v3-build.log; exit 1; }
docker compose up -d --force-recreate app worker >/tmp/sniper-v3-up.log 2>&1 || { cat /tmp/sniper-v3-up.log; exit 1; }
sleep 6

echo "[8/9] Verify live"
for p in /sniper /api/sniper/health /api/sniper/accounts /api/sniper/ontology; do
  code=$(curl -sS -o /tmp/sniper-http-body -w '%{http_code}' "http://127.0.0.1:8088$p")
  test "$code" != "404"
done
echo "LIVE_HTTP_ROUTES_OK"
docker exec matrix_v1_worker python -c "from sniper_v3.research import enqueue_job,process_queue; print('WORKER_SNIPER_IMPORT_OK')"

docker exec matrix_v1_app python -c "from sniper_v3.core import query_plan,deterministic_score; q=query_plan('São Paulo','SP',['Tucuruvi'],['chiller_rental','chiller_maintenance']); assert len(q)>=6; x=deterministic_score({'services_confirmed':[{'service_id':'chiller_rental'}],'b2b_confirmed':True,'entity_resolution_ok':True,'active':True,'source_count':2,'primary_source_count':1,'segments_served':[{}],'geography_evidenced':True,'google_presence':{'queries_checked':4,'coverage_score':25,'competitive_gap_score':60,'reputation_gap_score':30,'site_gap_score':0},'maturity':{'b2b_maturity_score':60,'industrial_depth_score':70},'trigger_signals':[],'research_confidence':.85}); assert 0 <= x['score'] <= 100; print('CORE_PREFLIGHT_OK',len(q),x['score'],x['tier'])"
docker exec matrix_v1_app python -c "from db import get_conn; c=get_conn(); cur=c.cursor(); cur.execute(\"SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'matrix_%' ORDER BY tablename\"); tables={r['tablename'] for r in cur.fetchall()}; required={'matrix_accounts','matrix_account_evidence','matrix_account_services','matrix_google_observations','matrix_account_signals','matrix_research_packs','matrix_research_queue','matrix_source_cache'}; assert required <= tables,required-tables; print('LIVE_SCHEMA_OK',len(tables)); cur.close(); c.close()"

echo "[9/9] Health"
docker ps --filter name=matrix_v1_app --filter name=matrix_v1_worker --filter name=matrix_v1_intelligence --format '{{.Names}}|{{.Status}}'
docker logs --tail 40 matrix_v1_worker 2>&1 | grep -E '\[sniper\].*worker iniciado' >/dev/null
echo "BACKUP=$BACKUP"
echo "SNIPER_V3_FULL_DEPLOY_OK"
