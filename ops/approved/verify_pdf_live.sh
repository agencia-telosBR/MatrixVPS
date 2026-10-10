#!/usr/bin/env bash
set -euo pipefail

ROOT=/opt/matrix-scraper-v1
JOB=26
COMPANY_NAME='Manutenção e Reparo de Chiller Industrial Refrigeração/ Câmara Fria Climática Frigorífica/ Ar Condicionado Precisão - EGELAR'
WFID=W2aWTTZOA8yIoNip
OUT="$ROOT/job26-egelar-radar-competitivo.pdf"

run_matrix_sql(){ docker exec -i matrix_v1_db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'; }

echo "[1/7] Locate company"
TARGET=$(run_matrix_sql <<SQL
SELECT json_build_object(
  'company_id',c.id,
  'name',c.name,
  'rating',c.rating,
  'review_count',c.review_count,
  'category',c.category_primary,
  'website',c.website_url,
  'source_key',c.source_key
)::text
FROM companies c
JOIN search_results sr ON sr.company_id=c.id
JOIN searches s ON s.id=sr.search_id
WHERE s.job_id=$JOB
  AND lower(c.name)=lower('$COMPANY_NAME')
GROUP BY c.id
ORDER BY c.id DESC
LIMIT 1;
SQL
)
if [ -z "$TARGET" ]; then
  echo "TARGET_NOT_FOUND"
  exit 2
fi
printf '%s' "$TARGET" > /tmp/egelar_target.json
COMPANY_ID=$(python3 - <<'PY'
import json
print(json.load(open('/tmp/egelar_target.json'))['company_id'])
PY
)
echo "COMPANY_ID=$COMPANY_ID"

echo "[2/7] Load territorial intelligence"
TOKEN=$(cat "$ROOT/.matrix_report_token")
curl -fsS -H "X-Matrix-Internal: $TOKEN" "http://127.0.0.1:8088/api/internal/report-data/$JOB/$COMPANY_ID" > /tmp/egelar_territorial.json

run_matrix_sql <<SQL > /tmp/egelar_intel.json
SELECT json_build_object(
  'snapshot',mic.snapshot,
  'maps',mic.maps,
  'fit',mic.fit,
  'approval_status',mic.approval_status,
  'ai_status',mic.ai_status
)::text
FROM matrix_intelligence_companies mic
WHERE mic.job_id=$JOB AND mic.company_id=$COMPANY_ID
LIMIT 1;
SQL

echo "[3/7] Build real report payload"
python3 - <<'PY'
import json, math, re
target=json.load(open('/tmp/egelar_target.json'))
terr=json.load(open('/tmp/egelar_territorial.json'))
txt=open('/tmp/egelar_intel.json').read().strip()
intel=json.loads(txt) if txt else {}
snap=intel.get('snapshot') or {}
company=snap.get('company') or {}

def n(v):
    try: return float(v)
    except: return None

loc=snap.get('local_observations') or []
obs=[]
for x in loc:
    p=x.get('position')
    obs.append({
        'termo':x.get('term') or x.get('query') or '',
        'bairro':x.get('neighborhood') or '',
        'cidade':x.get('city') or '',
        'estado':x.get('state') or '',
        'encontrado':p is not None,
        'posicao':p,
    })

positions=[n(o.get('posicao')) for o in obs if o.get('encontrado')]
positions=[x for x in positions if x is not None]
pos_media=(sum(positions)/len(positions)) if positions else None
melhor=min(positions) if positions else None
total=len(obs)
seen=sum(1 for o in obs if o.get('encontrado'))
vis=round((seen/total)*100) if total else 0
rating=n(target.get('rating'))
reviews=int(target.get('review_count') or 0)
rep=round(min(100, ((rating or 0)/5)*72 + min(reviews,120)/120*28)) if rating is not None else min(100,reviews)
dig=86 if target.get('website') else 58

# Build direct competitors from snapshot/analysis using only observed data.
cand=[]
for holder in (snap, snap.get('analysis') or {}, snap.get('ranking') or {}):
    if not isinstance(holder,dict): continue
    for key in ('competitors','concorrentes','local_competitors','ranking','ranking_observations'):
        v=holder.get(key)
        if isinstance(v,list) and v:
            cand=v; break
    if cand: break

comps=[]
for c in cand:
    if not isinstance(c,dict): continue
    name=c.get('name') or c.get('nome') or c.get('company_name')
    if not name: continue
    if str(name).strip().casefold()==str(target.get('name','')).strip().casefold(): continue
    comps.append({
        'nome':name,
        'posicao':c.get('position') or c.get('posicao') or c.get('rank'),
        'nota':c.get('rating') or c.get('nota'),
        'avaliacoes':c.get('review_count') or c.get('avaliacoes'),
    })
    if len(comps)>=3: break

segment=target.get('category') or company.get('category_primary') or company.get('category') or 'Serviços de climatização e refrigeração'
job=terr.get('job') or {}
city=job.get('city') or company.get('city') or ''
state=job.get('state') or company.get('state') or ''
local=f"{city}/{state}".strip('/')

report={
 'identidade':{
   'nome_curto':'EGELAR',
   'nome_completo':target.get('name') or 'EGELAR',
   'segmento':segment,
   'mes_ano':'Outubro 2026',
   'site_identificado':bool(target.get('website')),
   'categoria_google':segment,
   'local':local,
 },
 'scores':{
   'visibilidade':vis,'reputacao':rep,'presenca_digital':dig,
   'labels':{
     'visibilidade':'Forte' if vis>=80 else 'Moderada' if vis>=50 else 'Baixa',
     'reputacao':'Forte' if rep>=80 else 'Moderada' if rep>=60 else 'Baixa',
     'presenca_digital':'Forte' if dig>=80 else 'Moderada' if dig>=60 else 'Baixa',
   }
 },
 'reputacao':{'nota':rating,'avaliacoes':reviews,'site_identificado':bool(target.get('website'))},
 'observacoes':obs,
 'analise_principal':{
   'posicao':melhor,
   'bairro':obs[0].get('bairro') if obs else '',
   'termo':obs[0].get('termo') if obs else '',
 },
 'concorrentes':comps,
 'plano':{
   'organico':[
     {'titulo':'Cobertura local','descricao':'Reforçar presença nos bairros e termos em que a empresa ainda não aparece com consistência.'},
     {'titulo':'Perfil Google','descricao':'Manter categorias, serviços e informações do perfil alinhados às buscas observadas.'},
     {'titulo':'Avaliações','descricao':'Ampliar a prova social com avaliações reais e recentes de forma contínua.'},
     {'titulo':'Monitoramento','descricao':'Acompanhar posição, recorrência e cobertura territorial ao longo do tempo.'}
   ],
   'ads':[
     {'titulo':'Campanhas por serviço','descricao':'Separar campanhas pelos serviços e termos com maior intenção comercial.'},
     {'titulo':'Segmentação regional','descricao':'Priorizar as regiões com menor presença orgânica observada.'},
     {'titulo':'Conversão direta','descricao':'Direcionar a captação para canais de contato de resposta rápida.'},
     {'titulo':'Otimização contínua','descricao':'Concentrar investimento nos termos e regiões que gerarem melhores oportunidades.'}
   ]
 },
 'dados_tecnicos':{
   'categoria':segment,
   'posicao_media':pos_media,
   'melhor_posicao':melhor
 },
 'territorial':terr
}
json.dump({'report':report},open('/tmp/egelar_sample.json','w'),ensure_ascii=False)
print('TARGET_OK', target.get('name'))
print('OBS',total,'FOUND',seen,'POS_MEDIA',pos_media,'BEST',melhor)
print('REGIONAL',[(x.get('zone'),x.get('name')) for x in terr.get('regional') or []])
PY

echo "[4/7] Export live Premium V2 template"
docker exec -u root sdr-n8n rm -f /home/node/egelar_workflow.json /home/node/egelar_sample.json /home/node/egelar_render.js /home/node/egelar_report.pdf /home/node/egelar_index.html
docker exec -u node sdr-n8n n8n export:workflow --id="$WFID" --published --output=/home/node/egelar_workflow.json >/dev/null
docker exec -i -u node sdr-n8n sh -c 'cat > /home/node/egelar_sample.json' < /tmp/egelar_sample.json

echo "[5/7] Render PDF with Gotenberg"
cat > /tmp/egelar_render.js <<'NODE'
const fs=require('fs');
const wf=JSON.parse(fs.readFileSync('/home/node/egelar_workflow.json','utf8'));
const w=Array.isArray(wf)?wf[0]:wf;
const node=w.nodes.find(n=>n.name==='PDF - Gera HTML premium');
if(!node) throw new Error('HTML node not found');
const sample=JSON.parse(fs.readFileSync('/home/node/egelar_sample.json','utf8'));
const fn=new Function('$json',node.parameters.jsCode);
const out=fn(sample);
const html=Buffer.from(out[0].binary.data.data,'base64');
fs.writeFileSync('/home/node/egelar_index.html',html);
(async()=>{
  const fd=new FormData();
  fd.append('files',new Blob([html],{type:'text/html'}),'index.html');
  for(const [k,v] of Object.entries({
    paperWidth:'8.27',paperHeight:'11.69',
    marginTop:'0',marginBottom:'0',marginLeft:'0',marginRight:'0',
    printBackground:'true',preferCssPageSize:'true'
  })) fd.append(k,v);
  const r=await fetch('http://gotenberg:3000/forms/chromium/convert/html',{method:'POST',body:fd});
  if(!r.ok) throw new Error('Gotenberg '+r.status+' '+await r.text());
  fs.writeFileSync('/home/node/egelar_report.pdf',Buffer.from(await r.arrayBuffer()));
  console.log('PDF_OK',fs.statSync('/home/node/egelar_report.pdf').size);
})().catch(e=>{console.error(e);process.exit(1)});
NODE
docker exec -i -u node sdr-n8n sh -c 'cat > /home/node/egelar_render.js' < /tmp/egelar_render.js
docker exec -u node sdr-n8n node /home/node/egelar_render.js
docker cp sdr-n8n:/home/node/egelar_report.pdf "$OUT" >/dev/null

echo "[6/7] Validate"
test -s "$OUT"
file "$OUT"
if command -v pdfinfo >/dev/null 2>&1; then pdfinfo "$OUT" | grep -E 'Pages:|Page size:|File size:'; fi

echo "[7/7] Done"
echo "COMPANY_ID=$COMPANY_ID"
echo "OUTPUT=$OUT"
echo "EGELAR_REPORT_OK"

cp /opt/matrix-scraper-v1/job26-egelar-radar-competitivo.pdf /opt/matrix-scraper-v1/pdf_v2_live_verified.pdf
