#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/matrix-scraper-v1
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT/backup-geo-map-final-$TS"
mkdir -p "$BACKUP"

cp "$ROOT/app/matrix_intelligence/real_maps_v4.py" "$BACKUP/real_maps_v4.py"
cp "$ROOT/app/matrix_intelligence/api.py" "$BACKUP/api.py"
docker exec -u node sdr-n8n n8n export:workflow --id=W2aWTTZOA8yIoNip --published --pretty --output=/home/node/geo_final_before.json >/dev/null
docker cp sdr-n8n:/home/node/geo_final_before.json "$BACKUP/pdf_workflow_before.json" >/dev/null

echo "[1/7] Match Matrix GEO visible extent"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/matrix_intelligence/real_maps_v4.py')
s=p.read_text()
old="""    if primary_view:
        map_center,zoom=primary_view
    else:
        map_center=(center[0],center[1])
        zoom=13
"""
new="""    if primary_view:
        map_center,zoom=primary_view
        # O PNG é mais largo que o painel GEO. +1 mantém aproximadamente a mesma extensão geográfica visível.
        zoom=min(19,zoom+1)
    else:
        map_center=(center[0],center[1])
        # No frontend, ponto/centro usa zoom 13 em ~900 px; em 1440 px usamos 14 para preservar o enquadramento.
        zoom=14
"""
if old not in s:
    if 'zoom=14' not in s:
        raise SystemExit('PATCH_ABORTADO: bloco de viewport não encontrado')
else:
    s=s.replace(old,new,1)
p.write_text(s)
PY
python3 -m py_compile "$ROOT/app/matrix_intelligence/real_maps_v4.py"

echo "[2/7] PDF API serves only the map viewport, without internal header/footer"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/matrix_intelligence/api.py')
s=p.read_text()
if 'from PIL import Image' not in s:
    anchor='from fastapi.responses import FileResponse,JSONResponse,Response,StreamingResponse\n'
    if anchor not in s: raise SystemExit('PATCH_ABORTADO: import anchor')
    s=s.replace(anchor,anchor+'from PIL import Image\n',1)

old="""            if path.is_file():
                map_data='data:image/png;base64,'+base64.b64encode(path.read_bytes()).decode('ascii')
"""
new="""            if path.is_file():
                raw=path.read_bytes()
                try:
                    im=Image.open(io.BytesIO(raw)).convert('RGB')
                    # O arquivo interno traz cabeçalho/rodapé; no relatório exibimos exatamente a área cartográfica.
                    if im.height >= 900 and im.width >= 1200:
                        im=im.crop((0,80,im.width,min(im.height,770)))
                    out=io.BytesIO();im.save(out,'PNG',optimize=True)
                    raw=out.getvalue()
                except Exception:
                    pass
                map_data='data:image/png;base64,'+base64.b64encode(raw).decode('ascii')
"""
if old in s:
    s=s.replace(old,new,1)
elif 'im.crop((0,80' not in s:
    raise SystemExit('PATCH_ABORTADO: bloco map_data não encontrado')
p.write_text(s)
PY
python3 -m py_compile "$ROOT/app/matrix_intelligence/api.py"

echo "[3/7] Rebuild Matrix API/intelligence"
cd "$ROOT"
docker compose build app >/tmp/geo-final-build.log 2>&1 || { tail -150 /tmp/geo-final-build.log; exit 1; }
docker compose up -d app intelligence >/tmp/geo-final-up.log 2>&1 || { cat /tmp/geo-final-up.log; exit 1; }
sleep 4

echo "[4/7] Increase PDF map box"
docker exec -u node sdr-n8n n8n export:workflow --id=W2aWTTZOA8yIoNip --published --output=/home/node/geo_final_edit.json >/dev/null
docker cp sdr-n8n:/home/node/geo_final_edit.json /tmp/geo_final_edit.json >/dev/null
python3 - <<'PY'
import json
p='/tmp/geo_final_edit.json'
x=json.load(open(p)); is_list=isinstance(x,list); w=x[0] if is_list else x
by={n['name']:n for n in w['nodes']}
node=by['PDF - Gera HTML premium']
h=node['parameters']['jsCode']
h=h.replace('height:76mm;border:.3mm solid #d0d8df','height:82mm;border:.3mm solid #d0d8df')
h=h.replace('height:69mm;border:.3mm solid #d0d8df','height:82mm;border:.3mm solid #d0d8df')
node['parameters']['jsCode']=h
json.dump([w] if is_list else w,open(p,'w'),ensure_ascii=False)
PY
docker exec -i -u node sdr-n8n sh -c 'cat > /home/node/geo_final_import.json' < /tmp/geo_final_edit.json
docker exec -u node sdr-n8n n8n import:workflow --input=/home/node/geo_final_import.json >/tmp/geo-final-import.log 2>&1 || { cat /tmp/geo-final-import.log; exit 1; }
docker exec -u node sdr-n8n n8n publish:workflow --id=W2aWTTZOA8yIoNip >/tmp/geo-final-publish.log 2>&1 || { cat /tmp/geo-final-publish.log; exit 1; }
docker restart sdr-n8n >/dev/null
sleep 4
docker network connect matrix_v1_network sdr-n8n 2>/dev/null || true

echo "[5/7] Regenerate validation map"
if [ -x "$ROOT/ops/matrix_control.sh" ]; then
  "$ROOT/ops/matrix_control.sh" maps_only 25
else
  docker exec matrix_v1_intelligence python -m matrix_intelligence.cli maps-only --job 25
fi

echo "[6/7] Verify contract"
test -s "$ROOT/matrix_intel_exports/25/1396/mapa_local_observado.png"
file "$ROOT/matrix_intel_exports/25/1396/mapa_local_observado.png"
COUNT=$(find "$ROOT/matrix_intel_exports" -type f -name 'mapa_raio_500km_top3.png' | wc -l)
echo "REGIONAL_PNG_COUNT=$COUNT"
test "$COUNT" -eq 0
docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' <<'SQL'
SELECT status||'|'||search_count FROM matrix_intelligence_regional_jobs WHERE job_id=25;
SQL

echo "[7/7] Health"
docker ps --filter name=matrix_v1_app --filter name=matrix_v1_intelligence --filter name=sdr-n8n --format '{{.Names}}|{{.Status}}'
echo "BACKUP=$BACKUP"
echo "GEO_MAP_FINAL_OK"
