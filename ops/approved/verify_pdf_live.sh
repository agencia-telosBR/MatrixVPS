#!/usr/bin/env bash
set -euo pipefail

ROOT=/opt/matrix-scraper-v1
JOB=26
COMPANY_ID=2183
OUTDIR="$ROOT/matrix_intel_exports/$JOB/$COMPANY_ID"
mkdir -p "$OUTDIR"

echo "[1/4] Forçar geração do mapa local real do Job 26 / EGELAR"

docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' <<SQL > /tmp/egelar_map_payload.json
SELECT json_build_object(
  'company', json_build_object(
    'name', c.name,
    'maps_url', c.maps_url
  ),
  'job', json_build_object(
    'id', j.id,
    'city', j.city,
    'state', j.state,
    'neighborhoods', j.neighborhoods
  ),
  'center', json_build_object(
    'lat', r.center_lat,
    'lon', r.center_lon
  ),
  'geo', (
    SELECT g.geojson
    FROM geo_area_cache g
    WHERE lower(g.city)=lower(j.city) AND upper(g.state)=upper(j.state)
    LIMIT 1
  )
)::text
FROM companies c
CROSS JOIN scrape_jobs j
LEFT JOIN matrix_intelligence_regional_jobs r ON r.job_id=j.id
WHERE c.id=$COMPANY_ID AND j.id=$JOB;
SQL

test -s /tmp/egelar_map_payload.json

docker cp /tmp/egelar_map_payload.json matrix_v1_intelligence:/tmp/egelar_map_payload.json >/dev/null

cat > /tmp/force_egelar_map.py <<'PY'
import json
from pathlib import Path
from matrix_intelligence.real_maps_v4 import local_real_map, png
from matrix_intelligence.regional_v4 import coords_from_maps

data=json.load(open('/tmp/egelar_map_payload.json'))
company=data['company']
job=data['job']
center=data.get('center') or {}
geo=data.get('geo')
if isinstance(geo,str):
    geo=json.loads(geo)

loc=coords_from_maps(company.get('maps_url'))
if not loc:
    raise SystemExit('SEM_COORDENADAS_DA_EMPRESA')
if not center.get('lat') or not center.get('lon'):
    raise SystemExit('SEM_CENTRO_DO_JOB')
neighborhoods=job.get('neighborhoods') or []
if not isinstance(neighborhoods,list):
    neighborhoods=[str(neighborhoods)]

img=local_real_map(
    {'name':company['name'],'location':loc},
    (float(center['lat']),float(center['lon'])),
    geo,
    neighborhoods
)
Path('/tmp/egelar_map.png').write_bytes(png(img))
print('MAPA_GERADO',loc,'bairros',neighborhoods)
PY

docker cp /tmp/force_egelar_map.py matrix_v1_intelligence:/tmp/force_egelar_map.py >/dev/null
docker exec matrix_v1_intelligence python /tmp/force_egelar_map.py
docker cp matrix_v1_intelligence:/tmp/egelar_map.png "$OUTDIR/mapa_local_observado.png" >/dev/null
test -s "$OUTDIR/mapa_local_observado.png"
file "$OUTDIR/mapa_local_observado.png"

echo "[2/4] Registrar mapa no dado de inteligência"
docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' <<SQL
UPDATE matrix_intelligence_companies
SET maps = coalesce(maps,'{}'::jsonb) || jsonb_build_object('local','mapa_local_observado.png','regional',NULL)
WHERE job_id=$JOB AND company_id=$COMPANY_ID;
SQL

TOKEN=$(cat "$ROOT/.matrix_report_token")
curl -fsS -H "X-Matrix-Internal: $TOKEN" "http://127.0.0.1:8088/api/internal/report-data/$JOB/$COMPANY_ID" > /tmp/egelar_report_data.json
python3 - <<'PY'
import json
j=json.load(open('/tmp/egelar_report_data.json'))
ok=bool(j.get('mapa_local_data_uri'))
print('MAP_DATA_URI_OK',ok,'center=',j.get('center_label'))
if not ok:
    raise SystemExit('MAPA_NAO_CHEGOU_AO_GERADOR_PDF')
PY

echo "[3/4] Gerar PDF final da EGELAR"
curl -fsSL https://raw.githubusercontent.com/agencia-telosBR/MatrixVPS/main/ops/approved/generate_job26_egelar_report.sh -o /tmp/generate_job26_egelar_report.sh
chmod 700 /tmp/generate_job26_egelar_report.sh
bash /tmp/generate_job26_egelar_report.sh

test -s "$ROOT/job26-egelar-radar-competitivo.pdf"
cp "$ROOT/job26-egelar-radar-competitivo.pdf" "$ROOT/pdf_v2_live_verified.pdf"

echo "[4/4] Validar PDF"
file "$ROOT/pdf_v2_live_verified.pdf"
if command -v pdfinfo >/dev/null 2>&1; then
  pdfinfo "$ROOT/pdf_v2_live_verified.pdf" | grep -E 'Pages:|Page size:|File size:'
fi

echo "EGELAR_JOB26_MAP_AND_PDF_OK"
