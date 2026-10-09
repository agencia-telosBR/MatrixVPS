#!/usr/bin/env bash
set -euo pipefail

run_sdr_sql(){ docker exec -i sdr-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'; }
run_matrix_sql(){ docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'; }

echo "=== ACTIVE PDF NODES ==="
run_sdr_sql <<'SQL'
SELECT elem->>'name' || '|' || elem->>'type'
FROM workflow_entity w
CROSS JOIN LATERAL jsonb_array_elements(w.nodes::jsonb) AS x(elem)
WHERE w.id='W2aWTTZOA8yIoNip'
  AND (
    elem->>'name' ILIKE 'PDF - %'
    OR elem->>'name' ILIKE '%dossiê Matrix%'
    OR elem->>'name' ILIKE '%relatório%'
  )
ORDER BY elem->>'name';
SQL

echo "=== ACTIVE PDF CODE NODES (EXCEPT HTML) ==="
run_sdr_sql <<'SQL'
SELECT '---NODE---' || elem->>'name' || E'\n' ||
       COALESCE(elem->'parameters'->>'jsCode', elem->'parameters'->>'query', left((elem->'parameters')::text,8000))
FROM workflow_entity w
CROSS JOIN LATERAL jsonb_array_elements(w.nodes::jsonb) AS x(elem)
WHERE w.id='W2aWTTZOA8yIoNip'
  AND (
    elem->>'name' ILIKE 'PDF - %'
    OR elem->>'name' ILIKE '%dossiê Matrix%'
  )
  AND elem->>'name' <> 'PDF - Gera HTML premium'
ORDER BY elem->>'name';
SQL

echo "=== RJ CONFORT SDR ROW SUMMARY ==="
run_sdr_sql <<'SQL'
SELECT json_build_object(
 'source_key',source_key,'company_id',company_id,'job_id',job_id,'nome',nome,
 'nota_google',nota_google,'quantidade_avaliacoes',quantidade_avaliacoes,
 'm2_bairros_observados',m2_bairros_observados,'m2_observacoes_coletadas',m2_observacoes_coletadas,
 'm2_nao_encontrado_em',m2_nao_encontrado_em,'ranking',m2_ranking_observacoes,
 'matrix_payload',matrix_payload
)::text
FROM sdr_matrix_leads
WHERE nome ILIKE '%RJ%Confort%'
ORDER BY job_id DESC,ultima_importacao_em DESC
LIMIT 1;
SQL

echo "=== MATRIX INTELLIGENCE TABLE SCHEMAS ==="
run_matrix_sql <<'SQL'
SELECT table_name || '|' || column_name || '|' || data_type
FROM information_schema.columns
WHERE table_schema='public'
 AND table_name IN (
 'matrix_intelligence_jobs',
 'matrix_intelligence_companies',
 'matrix_intelligence_regional_jobs',
 'matrix_intelligence_regional_searches',
 'matrix_intelligence_regional_candidates',
 'companies',
 'scrape_jobs'
 )
ORDER BY table_name,ordinal_position;
SQL

echo "=== RJ CONFORT MATRIX COMPANY ==="
run_matrix_sql <<'SQL'
SELECT to_jsonb(c)::text
FROM companies c
WHERE c.name ILIKE '%RJ%Confort%'
ORDER BY c.id DESC
LIMIT 1;
SQL

echo "=== N8N CLI HELP ==="
docker exec -u node sdr-n8n n8n export:workflow --help 2>&1 | head -80 || true
docker exec -u node sdr-n8n n8n import:workflow --help 2>&1 | head -100 || true
docker exec -u node sdr-n8n n8n update:workflow --help 2>&1 | head -100 || true
