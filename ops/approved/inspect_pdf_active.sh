#!/usr/bin/env bash
set -euo pipefail

run_sdr_sql() {
  docker exec -i sdr-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'
}
run_matrix_sql() {
  docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'
}

echo "=== ACTIVE WORKFLOW PDF NODE NAMES ==="
run_sdr_sql <<'SQL'
SELECT n->>'name' || '|' || n->>'type'
FROM workflow_entity w
CROSS JOIN LATERAL jsonb_array_elements(w.nodes::jsonb) n
WHERE w.id='W2aWTTZOA8yIoNip'
  AND (n->>'name' ILIKE 'PDF - %' OR n->>'name' ILIKE '%dossiê%' OR n->>'name' ILIKE '%Matrix%')
ORDER BY n->>'name';
SQL

echo "=== PDF GERA HTML PREMIUM ==="
run_sdr_sql <<'SQL'
SELECT (n->'parameters'->>'jsCode')
FROM workflow_entity w
CROSS JOIN LATERAL jsonb_array_elements(w.nodes::jsonb) n
WHERE w.id='W2aWTTZOA8yIoNip'
  AND n->>'name'='PDF - Gera HTML premium';
SQL

echo "=== PDF DATA / QUERY NODES ==="
run_sdr_sql <<'SQL'
SELECT '--- ' || n->>'name' || E'\n' || left((n->'parameters')::text,12000)
FROM workflow_entity w
CROSS JOIN LATERAL jsonb_array_elements(w.nodes::jsonb) n
WHERE w.id='W2aWTTZOA8yIoNip'
  AND (
    n->>'name' ILIKE 'PDF - %'
    OR n->>'name' ILIKE '%Monta dossiê Matrix%'
    OR n->>'name' ILIKE '%Busca dados relatório%'
  )
  AND n->>'name' <> 'PDF - Gera HTML premium'
ORDER BY n->>'name';
SQL

echo "=== SDR MATRIX LEADS COLUMNS ==="
run_sdr_sql <<'SQL'
SELECT column_name || '|' || data_type
FROM information_schema.columns
WHERE table_name='sdr_matrix_leads'
ORDER BY ordinal_position;
SQL

echo "=== MATRIX TABLES LIKELY ==="
run_matrix_sql <<'SQL'
SELECT table_name
FROM information_schema.tables
WHERE table_schema='public'
  AND (
    table_name ILIKE '%intell%'
    OR table_name ILIKE '%company%'
    OR table_name ILIKE '%compan%'
    OR table_name ILIKE '%job%'
    OR table_name ILIKE '%regional%'
  )
ORDER BY table_name;
SQL

echo "=== MATRIX RELEVANT COLUMNS ==="
run_matrix_sql <<'SQL'
SELECT table_name || '|' || column_name || '|' || data_type
FROM information_schema.columns
WHERE table_schema='public'
  AND (
    column_name ILIKE '%regional%'
    OR column_name ILIKE '%mapa%'
    OR column_name ILIKE '%ranking%'
    OR column_name ILIKE '%reput%'
    OR column_name ILIKE '%presenca%'
    OR column_name ILIKE '%bairro%'
    OR column_name ILIKE '%avaliac%'
    OR column_name ILIKE '%nota%'
  )
ORDER BY table_name,ordinal_position;
SQL
