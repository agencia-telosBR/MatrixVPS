#!/usr/bin/env bash
set -euo pipefail
run_sdr_sql(){ docker exec -i sdr-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'; }
run_matrix_sql(){ docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'; }

echo "=== ACTIVE PDF NODE NAMES ==="
run_sdr_sql <<'SQL'
SELECT (elem->>'name') || '|' || (elem->>'type')
FROM workflow_entity w
CROSS JOIN LATERAL jsonb_array_elements(w.nodes::jsonb) AS x(elem)
WHERE w.id='W2aWTTZOA8yIoNip'
  AND ((elem->>'name') ILIKE 'PDF - %' OR (elem->>'name') ILIKE '%dossiê Matrix%')
ORDER BY (elem->>'name');
SQL

echo "=== ACTIVE REPORT-BUILDER CODE ==="
run_sdr_sql <<'SQL'
SELECT '### ' || (elem->>'name') || E'\n' || COALESCE(elem->'parameters'->>'jsCode','')
FROM workflow_entity w
CROSS JOIN LATERAL jsonb_array_elements(w.nodes::jsonb) AS x(elem)
WHERE w.id='W2aWTTZOA8yIoNip'
  AND (
    (elem->>'name') ILIKE 'PDF - Monta%'
    OR (elem->>'name') ILIKE 'PDF - Prepara%'
    OR (elem->>'name') ILIKE '%Monta dossiê Matrix%'
  )
ORDER BY (elem->>'name');
SQL

echo "=== JOB25 INTELLIGENCE COMPANY SAMPLE ==="
run_matrix_sql <<'SQL'
SELECT json_build_object('company_id',company_id,'fit',fit,'snapshot',snapshot,'maps',maps,'ai_status',ai_status)::text
FROM matrix_intelligence_companies
WHERE job_id=25
ORDER BY id
LIMIT 2;
SQL

echo "=== JOB25 REGIONAL RESULT ==="
run_matrix_sql <<'SQL'
SELECT to_jsonb(r)::text
FROM matrix_intelligence_regional_jobs r
WHERE job_id=25;
SQL

echo "=== JOB25 REGIONAL CANDIDATES WITH COMPANY MATCH ==="
run_matrix_sql <<'SQL'
SELECT json_build_object(
 'zone',rc.zone,'source_key',rc.source_key,'name',rc.name,'distance_km',rc.distance_km,
 'rating',c.rating,'review_count',c.review_count,'category',c.category_primary,
 'website',rc.website_url,'source_type',rc.source_type
)::text
FROM matrix_intelligence_regional_candidates rc
LEFT JOIN companies c ON c.source_key=rc.source_key
WHERE rc.job_id=25
ORDER BY rc.zone,rc.distance_km
LIMIT 30;
SQL

echo "=== REGIONAL_V4 KEY LINES ==="
grep -nE "regional_candidates|INSERT INTO matrix_intelligence_regional_candidates|source_key|rating|review|results|zone|presence|presen" /opt/matrix-scraper-v1/app/matrix_intelligence/regional_v4.py | head -240
