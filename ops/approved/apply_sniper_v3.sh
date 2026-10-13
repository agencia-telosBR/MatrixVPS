#!/usr/bin/env bash
set -euo pipefail

ROOT=/opt/matrix-scraper-v1
cd "$ROOT"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT/backup-sniper-v4-$TS"
mkdir -p "$BACKUP"

for f in app/main.py app/index.html app/worker.py app/scraper.py app/db.py; do
  [ -f "$f" ] && cp "$f" "$BACKUP/$(basename "$f")"
done
[ -d app/sniper_v3 ] && cp -a app/sniper_v3 "$BACKUP/sniper_v3" || true

echo "[1/10] Install Matrix Sniper 4.0 sources"
mkdir -p app/sniper_v3
BASE="https://raw.githubusercontent.com/agencia-telosBR/MatrixVPS/main/ops/sniper_v3"
for f in __init__.py core.py research.py api.py sniper.html schema.sql; do
  curl -fsSL "$BASE/$f" -o "app/sniper_v3/$f"
done

echo "[2/10] Register Account Intelligence routes"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/main.py')
s=p.read_text()
block='''

# ===== MATRIX SNIPER / ACCOUNT INTELLIGENCE =====
from sniper_v3 import register_sniper_v3_routes
register_sniper_v3_routes(app, get_conn, require_user)
'''
if 'register_sniper_v3_routes' not in s:
    s=s.rstrip()+block+'\n'
p.write_text(s)
PY

echo "[3/10] Make Sniper the primary Matrix interface"
if [ -f app/index.html ] && [ ! -f app/index_legacy.html ]; then
  cp app/index.html app/index_legacy.html
fi
cp app/sniper_v3/sniper.html app/index.html

echo "[4/10] Integrate persistent Account Research worker"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/worker.py')
s=p.read_text()

if 'from sniper_v3.research import enqueue_job, process_queue' not in s:
    anchor='from enricher import enrichment_loop\n'
    if anchor in s:
        s=s.replace(anchor,anchor+'from sniper_v3.research import enqueue_job, process_queue\n')
    else:
        s='from sniper_v3.research import enqueue_job, process_queue\n'+s

helper='''

def _enqueue_sniper_if_completed(job_id):
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT status FROM scrape_jobs WHERE id=%s",(job_id,))
                row=cur.fetchone()
            if row and row["status"] in ("completed","completed_with_errors"):
                total=enqueue_job(conn,job_id)
                with conn.cursor() as cur:
                    cur.execute("""UPDATE matrix_query_plans SET status='completed',finished_at=now(),
                                   stop_reason=COALESCE(stop_reason,'all_configured_queries_executed')
                                   WHERE job_id=%s AND status<>'completed'""",(job_id,))
                print(f"[sniper] job {job_id} enfileirado: {total} contas",flush=True)
    except Exception as exc:
        print(f"[sniper] falha ao enfileirar job {job_id}: {type(exc).__name__}: {exc}",flush=True)

async def sniper_research_loop():
    print("[sniper] Account Research worker iniciado",flush=True)
    while True:
        try:
            result=await asyncio.to_thread(process_queue,get_conn,None,1)
            await asyncio.sleep(0.35 if result.get("processed") else 3.0)
        except Exception as exc:
            print(f"[sniper] fila falhou: {type(exc).__name__}: {exc}",flush=True)
            await asyncio.sleep(5.0)
'''
if '_enqueue_sniper_if_completed' not in s:
    pos=s.find('\nasync def discovery_loop():')
    if pos<0:
        raise SystemExit('worker.py incompatível: discovery_loop não encontrado')
    s=s[:pos]+helper+s[pos:]

if 'await asyncio.to_thread(_enqueue_sniper_if_completed, job_id)' not in s:
    target='            await run_job(job_id)\n'
    if target not in s:
        raise SystemExit('worker.py incompatível: run_job call não encontrado')
    s=s.replace(target,target+'            await asyncio.to_thread(_enqueue_sniper_if_completed, job_id)\n',1)

if 'sniper_research_loop(),' not in s:
    target='        enrichment_loop(),\n'
    if target in s:
        s=s.replace(target,target+'        sniper_research_loop(),\n',1)
    else:
        target='        discovery_loop(),\n'
        if target not in s:
            raise SystemExit('worker.py incompatível: asyncio.gather não encontrado')
        s=s.replace(target,target+'        sniper_research_loop(),\n',1)

p.write_text(s)
PY

echo "[5/10] Static preflight"
python3 -m py_compile   app/sniper_v3/core.py   app/sniper_v3/research.py   app/sniper_v3/api.py   app/main.py   app/worker.py
echo "PY_COMPILE_OK"

echo "[6/10] Apply Sniper database model"
docker cp app/sniper_v3/schema.sql matrix_v1_app:/tmp/sniper_schema.sql
docker exec matrix_v1_app python - <<'PY'
from db import get_conn
sql=open('/tmp/sniper_schema.sql',encoding='utf-8').read()
with get_conn() as c:
    with c.cursor() as cur:
        cur.execute(sql)
print('SCHEMA_OK')
PY

echo "[7/10] Rebuild Matrix app + worker"
docker compose build app worker >/tmp/sniper-v4-build.log 2>&1 || { tail -240 /tmp/sniper-v4-build.log; exit 1; }
docker compose up -d --force-recreate app worker >/tmp/sniper-v4-up.log 2>&1 || { cat /tmp/sniper-v4-up.log; exit 1; }
sleep 7

echo "[8/10] Live route/schema verification"
for p in / /sniper /api/sniper/health /api/sniper/accounts /api/sniper/ontology /api/sniper/kpis; do
  code=$(curl -sS -o /tmp/sniper-http-body -w '%{http_code}' "http://127.0.0.1:8088$p")
  if [ "$code" = "404" ] || [ "$code" = "500" ]; then
    echo "FAIL $p -> $code"
    cat /tmp/sniper-http-body
    exit 1
  fi
  echo "$p -> $code"
done

docker exec matrix_v1_app python - <<'PY'
from db import get_conn
required={
'matrix_accounts','matrix_account_company_links','matrix_account_locations','matrix_account_contacts',
'matrix_account_services','matrix_account_evidence','matrix_google_observations','matrix_account_signals',
'matrix_research_packs','matrix_research_queue','matrix_source_cache','matrix_sniper_feedback',
'matrix_query_plans','matrix_query_plan_items','matrix_sniper_runs'
}
with get_conn() as c:
    with c.cursor() as cur:
        cur.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
        tables={r['tablename'] for r in cur.fetchall()}
missing=required-tables
assert not missing,missing
print('LIVE_SCHEMA_OK',len(required))
PY

echo "[9/10] Core acceptance preflight"
docker exec matrix_v1_app python - <<'PY'
from sniper_v3.core import query_plan,deterministic_score
q=query_plan('São Paulo','SP',['Lapa','Pinheiros'],['chiller_rental','chiller_maintenance','industrial_refrigeration'])
assert len(q)>=12
ctx={
 'services_confirmed':[{'service_id':'chiller_rental','confidence':.95}],
 'b2b_confirmed':True,'entity_resolution_ok':True,'active':True,
 'source_count':2,'source_types':['website','google_maps'],'primary_source_count':1,
 'segments_served':[{'sector_id':'industria'}],'geography_evidenced':True,
 'google_presence':{'queries_checked':8,'coverage_score':25,'competitive_gap_score':70,'reputation_gap_score':20,'site_gap_score':0},
 'b2b_maturity_score':70,'industrial_depth_score':80,
 'trigger_signals':[{'recency_weight':1.0,'relevance_weight':.8}],
 'research_confidence':.90,'negative_signals':[]
}
x=deterministic_score(ctx)
assert x['breakdown']['commercial_maturity']['points']>0,x
assert 0<=x['score']<=100
assert x['tier'] in ('A+','A','B','C')
print('CORE_ACCEPTANCE_OK',len(q),x['score'],x['tier'],x['breakdown'])
PY

echo "[10/10] Worker + UI verification"
docker exec matrix_v1_worker python - <<'PY'
from sniper_v3.research import enqueue_job,process_queue,build_pack
print('WORKER_SNIPER_IMPORT_OK')
PY
docker exec matrix_v1_app grep -q "Account Intelligence" /app/index.html
docker logs --tail 80 matrix_v1_worker 2>&1 | grep -E '\[sniper\].*worker iniciado' >/dev/null

docker ps --filter name=matrix_v1_app --filter name=matrix_v1_worker --filter name=matrix_v1_intelligence --format '{{.Names}}|{{.Status}}'
echo "BACKUP=$BACKUP"
echo "MATRIX_SNIPER_V4_DEPLOY_OK"
