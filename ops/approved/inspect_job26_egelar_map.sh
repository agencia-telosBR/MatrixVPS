#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/matrix-scraper-v1
JOB=26
COMPANY_ID=2183

echo "=== TARGET INTELLIGENCE ==="
docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' <<SQL
SELECT json_build_object(
 'job_id',job_id,
 'company_id',company_id,
 'fit',fit,
 'approval_status',approval_status,
 'ai_status',ai_status,
 'maps',maps,
 'snapshot',snapshot
)::text
FROM matrix_intelligence_companies
WHERE job_id=$JOB AND company_id=$COMPANY_ID;
SQL

echo "=== TARGET COMPANY ==="
docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' <<SQL
SELECT json_build_object(
 'id',id,'name',name,'maps_url',maps_url,'rating',rating,'review_count',review_count,
 'category',category_primary,'website',website_url
)::text
FROM companies WHERE id=$COMPANY_ID;
SQL

echo "=== JOB GEO ==="
docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' <<SQL
SELECT json_build_object('id',id,'city',city,'state',state,'neighborhoods',neighborhoods,'terms',terms,'status',status)::text
FROM scrape_jobs WHERE id=$JOB;
SQL

echo "=== FILE CHECK ==="
find "$ROOT/matrix_intel_exports/$JOB/$COMPANY_ID" -maxdepth 1 -type f -printf '%f|%s bytes\n' 2>/dev/null || true

echo "=== API MAP FLAG ==="
TOKEN=$(cat "$ROOT/.matrix_report_token")
curl -fsS -H "X-Matrix-Internal: $TOKEN" "http://127.0.0.1:8088/api/internal/report-data/$JOB/$COMPANY_ID" |
python3 -c "import sys,json; j=json.load(sys.stdin); print('map?',bool(j.get('mapa_local_data_uri')),'center',j.get('center_label'),'regional',j.get('regional_status'))"
