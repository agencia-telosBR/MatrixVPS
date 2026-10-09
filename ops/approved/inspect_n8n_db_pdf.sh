#!/usr/bin/env bash
set -euo pipefail

echo "=== N8N WORKFLOW NAMES ==="
docker exec sdr-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT id || E''\t'' || name || E''\t'' || active FROM workflow_entity ORDER BY \"updatedAt\" DESC LIMIT 100;"'

echo "=== PDF-RELATED N8N WORKFLOWS ==="
docker exec sdr-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT id || E''\t'' || name || E''\t'' || active FROM workflow_entity WHERE lower(name) ~ E''radar|compet|pdf|relat|report'' OR lower(nodes::text) ~ E''radar competitivo|gotenberg|pdf|relat.rio|report'' ORDER BY \"updatedAt\" DESC LIMIT 50;"'

echo "=== MATCHING WORKFLOW STRUCTURE ==="
docker exec sdr-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT json_build_object(''''id'''',id,''''name'''',name,''''active'''',active,''''nodes'''',nodes)::text FROM workflow_entity WHERE lower(name) ~ E''radar|compet|pdf|relat|report'' OR lower(nodes::text) ~ E''radar competitivo|gotenberg|pdf|relat.rio|report'' ORDER BY \"updatedAt\" DESC LIMIT 8;"' | python3 -c '
import sys,json,re
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: w=json.loads(line)
    except Exception:
        print(line[:2000]); continue
    print("--- WORKFLOW",w.get("id"),w.get("name"),"active=",w.get("active"))
    for n in w.get("nodes") or []:
        s=json.dumps(n,ensure_ascii=False)
        if re.search(r"radar|competitivo|pdf|gotenberg|relat[oó]rio|report",s,re.I):
            print("NODE",n.get("name"),n.get("type"))
            print(json.dumps(n.get("parameters",{}),ensure_ascii=False)[:6000])
'
