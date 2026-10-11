#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/matrix-scraper-v1
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT/backup-remove-meta-final-$TS"
mkdir -p "$BACKUP"
cp "$ROOT/app/static/app.js" "$BACKUP/app.js"
cp "$ROOT/app/sheet_integration.py" "$BACKUP/sheet_integration.py"
cp "$ROOT/app/main.py" "$BACKUP/main.py"

echo "[1/6] Remove META wording/logic from UI"
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/opt/matrix-scraper-v1/app/static/app.js')
s=p.read_text()

s=re.sub(
    r'\nconst exportMetaSdr\s*=\s*\n?\s*document\.getElementById\("exportMetaSdr"\);.*?(?=\nconst exportAllSdr|\n\(function|\nfunction|\nasync function)',
    '\n',
    s,
    flags=re.S,
)

repls={
'Envio manual: somente META móvel + observações M2 desses leads.':'Envio manual: todos os leads com celular + observações M2 disponíveis.',
'Job #${job.id} finalizado. META móvel e M2 disponíveis.':'Job #${job.id} finalizado. Leads com celular e M2 disponíveis.',
'O envio será liberado quando META móvel e M2 estiverem concluídos.':'O envio será liberado quando a raspagem e o enriquecimento estiverem concluídos.',
'Este job não possui uma META móvel M2 concluída para envio.':'Este job não possui leads com celular prontos para envio.',
'Job #${job.id} pronto. Serão enviados SOMENTE os leads META móveis e suas observações M2.':'Job #${job.id} pronto. Serão enviados todos os leads com celular e as observações M2 disponíveis.',
'Enviar SOMENTE a META MÓVEL do Job #${jobId} para a planilha do SDR?\\n\\nO universo TODOS não será enviado.':'Enviar todos os leads com celular do Job #${jobId} para a planilha do SDR?',
'ENVIANDO META MÓVEL...':'ENVIANDO LEADS COM CELULAR...',
}
for a,b in repls.items():
    s=s.replace(a,b)

s=s.replace('const target = Number(job.lead_target || 0);','const target = 0;')
s=s.replace('const metaReached = Boolean(job.meta_contatos_atingida || job.target_reached);','const metaReached = completedSearches >= totalSearches || job.m2_phase === "ANALYSIS_DEPTH" || job.status === "enriching";')
s=s.replace('const contactRatio = target > 0 ? Math.min(mobile / target, 1) : 0;','const contactRatio = 0;')
s=s.replace('Math.round((contactRatio * 38 + searchRatio * 16) * 100) / 100','Math.round(searchRatio * 54)')
s=s.replace('const selected = Math.max(Number(job.m2_selected_count || target || 0), 1);','const selected = Math.max(Number(job.m2_selected_count || mobile || 0), 1);')
s=s.replace('Number(job.m2_selected_count || job.lead_target || 0) > 0','Number(job.mobile_leads_count || job.prospectable_companies || job.m2_selected_count || 0) > 0')

s=re.sub(r'\n\s*\["leadTarget", "lead_target", "target", "lead-target"\]\.forEach\(id => \{.*?\n\s*\}\);', '', s, flags=re.S)

s=s.replace('META móvel', 'leads com celular')
s=s.replace('META MÓVEL', 'LEADS COM CELULAR')
s=s.replace('META congelada', 'Seleção M2')
p.write_text(s)
PY

echo "[2/6] Sheet payload = every valid mobile lead"
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/opt/matrix-scraper-v1/app/sheet_integration.py')
s=p.read_text()

s=s.replace(
'''    if not selected_rows:
        raise ValueError("O job nao possui META M2 congelada.")

    selected_order = {
''',
'''    selected_order = {
'''
)

s=s.replace(
'''        cid = company["company_id"]
        if cid not in selected_order:
            continue

        mobile = _mobile_value(company)
''',
'''        cid = company["company_id"]

        mobile = _mobile_value(company)
'''
)

s=re.sub(
    r'\n\s*target = int\(job\.get\("lead_target"\) or 0\)\n\s*if target > 0:\n\s*enriched = enriched\[:target\]\n',
    '\n',
    s,
    count=1,
)

s=s.replace('Nenhum lead movel elegivel encontrado na META.','Nenhum lead com celular válido foi encontrado neste job.')
s=s.replace('"job_meta_leads"', '"job_celulares_exportados"')
s=s.replace('"job_meta_atingida"', '"job_raspagem_concluida"')
s=s.replace('"job_meta_alta"', '"job_m2_prioridade_alta"')
s=s.replace('"job_meta_validar_fallback"', '"job_m2_validar"')

s=s.replace(
'''            job["id"], job.get("lead_target"), job.get("total_searches"),
            job.get("completed_searches"), job.get("observed_results"),
            job.get("unique_companies"), job.get("prospectable_companies"),
            job.get("meta_contatos_atingida"),
''',
'''            job["id"], len(enriched), job.get("total_searches"),
            job.get("completed_searches"), job.get("observed_results"),
            job.get("unique_companies"), job.get("prospectable_companies"),
            bool(job.get("finished_at")),
'''
)

p.write_text(s)
PY
python3 -m py_compile "$ROOT/app/sheet_integration.py"

echo "[3/6] Neutralize send route comments"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/main.py')
s=p.read_text()
s=s.replace(
'''    # IMPORTANTE: esta rota NUNCA usa o modo TODOS.
    # O payload e construido exclusivamente com a META MOVEL congelada.
''',
'''    # Envia todos os leads do Job que possuem celular brasileiro válido.
    # Não existe corte por meta/quantidade-alvo.
'''
)
p.write_text(s)
PY
python3 -m py_compile "$ROOT/app/main.py"

echo "[4/6] Rebuild/recreate app and worker"
cd "$ROOT"
docker compose build app worker >/tmp/remove-meta-build.log 2>&1 || { tail -160 /tmp/remove-meta-build.log; exit 1; }
docker compose up -d --force-recreate app worker >/tmp/remove-meta-up.log 2>&1 || { cat /tmp/remove-meta-up.log; exit 1; }
sleep 5

echo "[5/6] Verify deployed behavior"
! grep -nE 'META móvel|META MÓVEL|Meta de leads|meta de leads|META congelada' "$ROOT/app/index.html" "$ROOT/app/static/app.js"
! grep -q 'enriched = enriched\[:target\]' "$ROOT/app/sheet_integration.py"
! grep -q 'if cid not in selected_order' "$ROOT/app/sheet_integration.py"
grep -q 'todos os leads com celular' "$ROOT/app/static/app.js"
grep -q 'Nenhum lead com celular válido' "$ROOT/app/sheet_integration.py"
docker exec matrix_v1_app sh -lc '! grep -q "enriched = enriched\[:target\]" /app/sheet_integration.py'
docker exec matrix_v1_app sh -lc 'grep -q "todos os leads com celular" /app/static/app.js'

echo "[6/6] Health"
docker ps --filter name=matrix_v1_app --filter name=matrix_v1_worker --filter name=matrix_v1_intelligence --format '{{.Names}}|{{.Status}}'
echo "BACKUP=$BACKUP"
echo "NO_META_ALL_MOBILE_OK"
