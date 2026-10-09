#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/matrix-scraper-v1
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT/backup-regional-status-local-only-$TS"
mkdir -p "$BACKUP"
cp "$ROOT/app/matrix_intelligence/regional_v4.py" "$BACKUP/regional_v4.py"

echo "[1/5] Patch status: regional map intentionally retired"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/matrix_intelligence/regional_v4.py')
s=p.read_text()
old="    regional_done=False\n"
new="    # O mapa regional de 500 km foi descontinuado; a etapa regional é considerada concluída pelos dados X/Y/Z.\n    regional_done=True\n"
if old in s:
    s=s.replace(old,new,1)
elif 'regional_done=True' not in s:
    raise SystemExit('PATCH_ABORTADO: regional_done não localizado')

s=s.replace("        wrote+=int(local_done and regional_done)", "        wrote+=int(local_done)")
p.write_text(s)
PY
python3 -m py_compile "$ROOT/app/matrix_intelligence/regional_v4.py"

echo "[2/5] Rebuild intelligence"
cd "$ROOT"
docker compose build app >/tmp/status-build.log 2>&1 || { tail -120 /tmp/status-build.log; exit 1; }
docker compose up -d app intelligence >/tmp/status-up.log 2>&1 || { cat /tmp/status-up.log; exit 1; }
sleep 4

echo "[3/5] Regenerate maps/status for validation job"
if [ -x "$ROOT/ops/matrix_control.sh" ]; then
  "$ROOT/ops/matrix_control.sh" maps_only 25
else
  docker exec matrix_v1_intelligence python -m matrix_intelligence.cli maps-only --job 25
fi

echo "[4/5] Verify local-only contract"
MAP="$ROOT/matrix_intel_exports/25/1396/mapa_local_observado.png"
test -s "$MAP"
file "$MAP"
COUNT=$(find "$ROOT/matrix_intel_exports" -type f -name 'mapa_raio_500km_top3.png' 2>/dev/null | wc -l)
echo "REGIONAL_PNG_COUNT=$COUNT"
test "$COUNT" -eq 0

docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' <<'SQL'
SELECT 'REGIONAL_STATUS='||status||'|SEARCH_COUNT='||search_count
FROM matrix_intelligence_regional_jobs
WHERE job_id=25;
SQL

echo "[5/5] Health"
docker ps --filter name=matrix_v1_app --filter name=matrix_v1_intelligence --format '{{.Names}}|{{.Status}}'
echo "BACKUP=$BACKUP"
echo "LOCAL_ONLY_STATUS_OK"
