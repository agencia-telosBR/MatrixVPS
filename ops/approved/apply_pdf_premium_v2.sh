#!/usr/bin/env bash
set -euo pipefail

ROOT=/opt/matrix-scraper-v1
SDR=/opt/sdr
WFID=W2aWTTZOA8yIoNip
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT/backup-pdf-premium-v2-$TS"
mkdir -p "$BACKUP"

echo "[1/9] Backup"
cp "$ROOT/app/matrix_intelligence/api.py" "$BACKUP/api.py"
cp "$ROOT/compose.yaml" "$BACKUP/matrix-compose.yaml"
docker exec -u node sdr-n8n n8n export:workflow --id="$WFID" --published --pretty --output=/tmp/pdf_workflow_before.json >/dev/null
docker cp sdr-n8n:/tmp/pdf_workflow_before.json "$BACKUP/pdf_workflow_before.json" >/dev/null
docker exec sdr-postgres sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t workflow_entity -t workflow_history' | gzip > "$BACKUP/n8n_workflow_tables.sql.gz"

TOKEN_FILE="$ROOT/.matrix_report_token"
if [ ! -s "$TOKEN_FILE" ]; then
  umask 077
  openssl rand -hex 32 > "$TOKEN_FILE"
fi
TOKEN=$(cat "$TOKEN_FILE")
if ! grep -q '^MATRIX_INTERNAL_REPORT_TOKEN=' "$ROOT/.env"; then
  printf '\nMATRIX_INTERNAL_REPORT_TOKEN=%s\n' "$TOKEN" >> "$ROOT/.env"
else
  sed -i "s/^MATRIX_INTERNAL_REPORT_TOKEN=.*/MATRIX_INTERNAL_REPORT_TOKEN=$TOKEN/" "$ROOT/.env"
fi

echo "[2/9] Patch Matrix internal report endpoint"
curl -fsSL https://raw.githubusercontent.com/agencia-telosBR/MatrixVPS/main/ops/pdf_v2/internal_report_endpoint.txt -o /tmp/internal_report_endpoint.txt
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/matrix_intelligence/api.py')
s=p.read_text()
if 'import base64' not in s:
    s=s.replace('import json\n','import json\nimport base64\nimport os\nimport hmac\n',1)
if 'Header' not in s.split('\n',12)[6:12].__str__():
    s=s.replace('from fastapi import APIRouter,Depends,HTTPException','from fastapi import APIRouter,Depends,HTTPException,Header',1)
snippet=Path('/tmp/internal_report_endpoint.txt').read_text()
marker="    @router.get('/api/internal/report-data/{job_id}/{company_id}')"
if marker not in s:
    anchor='    app.include_router(router)'
    if anchor not in s: raise SystemExit('PATCH_ABORTADO: include_router não encontrado')
    s=s.replace(anchor,snippet+'\n'+anchor,1)
# Regional PNG was retired; approval now requires only the real local map.
s=s.replace("if not maps.get('local') or not maps.get('regional'):missing.append('dois mapas reais')",
            "if not maps.get('local'):missing.append('mapa local real')")
s=s.replace("for key in ('local','regional'):\n                if maps.get(key) and not (folder/maps[key]).is_file():missing.append('arquivo de mapa '+key)",
            "for key in ('local',):\n                if maps.get(key) and not (folder/maps[key]).is_file():missing.append('arquivo de mapa '+key)")
p.write_text(s)
PY

if ! grep -q 'MATRIX_INTERNAL_REPORT_TOKEN' "$ROOT/compose.yaml"; then
  python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/compose.yaml')
s=p.read_text()
needle='      SESSION_SECRET: ${SESSION_SECRET}\n'
if needle not in s: raise SystemExit('PATCH_ABORTADO: SESSION_SECRET não encontrado no compose')
s=s.replace(needle,needle+'      MATRIX_INTERNAL_REPORT_TOKEN: ${MATRIX_INTERNAL_REPORT_TOKEN}\n',1)
p.write_text(s)
PY
fi
python3 -m py_compile "$ROOT/app/matrix_intelligence/api.py"

echo "[3/9] Rebuild Matrix API"
cd "$ROOT"
docker compose build app >/tmp/pdfv2-build.log 2>&1 || { tail -120 /tmp/pdfv2-build.log; exit 1; }
docker compose up -d app >/tmp/pdfv2-up.log 2>&1 || { cat /tmp/pdfv2-up.log; exit 1; }
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8088/login >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS http://127.0.0.1:8088/login >/dev/null

echo "[4/9] Connect n8n to Matrix private network"
docker network inspect matrix_v1_network >/dev/null
docker network connect matrix_v1_network sdr-n8n 2>/dev/null || true
# Keep the extra network on future compose recreations.
SDR_WORKDIR=$(docker inspect sdr-n8n --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}')
SDR_SERVICE=$(docker inspect sdr-n8n --format '{{ index .Config.Labels "com.docker.compose.service" }}')
SDR_CONFIG=$(docker inspect sdr-n8n --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}')
if [ -n "$SDR_WORKDIR" ] && [ -n "$SDR_SERVICE" ]; then
  case "$SDR_CONFIG" in
    *docker-compose*) OVERRIDE="$SDR_WORKDIR/docker-compose.override.yml" ;;
    *) OVERRIDE="$SDR_WORKDIR/compose.override.yaml" ;;
  esac
  if [ ! -f "$OVERRIDE" ] || ! grep -q 'matrix_v1_network' "$OVERRIDE"; then
    cp -f "$OVERRIDE" "$BACKUP/$(basename "$OVERRIDE").before" 2>/dev/null || true
    cat > "$OVERRIDE" <<EOF
services:
  $SDR_SERVICE:
    networks:
      matrix_v1_network: {}
networks:
  matrix_v1_network:
    external: true
    name: matrix_v1_network
EOF
  fi
fi

echo "[5/9] Test internal API from n8n"
docker exec -e MATRIX_REPORT_TOKEN="$TOKEN" sdr-n8n node - <<'NODE'
const token=process.env.MATRIX_REPORT_TOKEN;
fetch('http://matrix_v1_app:8000/api/internal/report-data/25/1396',{headers:{'X-Matrix-Internal':token}})
 .then(async r=>{if(!r.ok)throw new Error('HTTP '+r.status+' '+await r.text());const j=await r.json();console.log('REPORT_API_OK',j.ok,!!j.job,j.regional?.length,!!j.mapa_local_data_uri);})
 .catch(e=>{console.error(e);process.exit(1);});
NODE

echo "[6/9] Patch published n8n workflow"
curl -fsSL https://raw.githubusercontent.com/agencia-telosBR/MatrixVPS/main/ops/pdf_v2/html_node_template.js -o /tmp/html_node_template.js
cp "$BACKUP/pdf_workflow_before.json" /tmp/pdf_workflow_edit.json
export MATRIX_REPORT_TOKEN="$TOKEN"
python3 - <<'PY'
import json,os,re,uuid
from pathlib import Path
p=Path('/tmp/pdf_workflow_edit.json')
raw=json.load(open(p))
is_list=isinstance(raw,list)
w=raw[0] if is_list else raw
nodes=w['nodes']; con=w['connections']
by={n['name']:n for n in nodes}
needed=['PDF - Só segue se reservado','PDF - Monta relatório determinístico','PDF - Gera HTML premium','PDF - Gotenberg renderiza']
missing=[x for x in needed if x not in by]
if missing: raise SystemExit('PATCH_ABORTADO nodes: '+','.join(missing))
# Report builder receives the territorial API response, while retaining the original trigger via $().
rb=by['PDF - Monta relatório determinístico']['parameters']['jsCode']
if "const intel=$json||{};" not in rb:
    old="const gat=$json||{};"
    new="const gat=$('PDF - Só segue se reservado').item.json||{};\nconst intel=$json||{};"
    if old not in rb: raise SystemExit('PATCH_ABORTADO: início do report builder mudou')
    rb=rb.replace(old,new,1)
if 'territorial:intel' not in rb:
    marker='const report={'
    if marker not in rb: raise SystemExit('PATCH_ABORTADO: const report não encontrado')
    extra="""const __foundPositions=observacoes.filter(o=>o.encontrado&&o.posicao!==null&&o.posicao!==undefined).map(o=>Number(o.posicao)).filter(Number.isFinite);
const __posMedia=__foundPositions.length?__foundPositions.reduce((a,b)=>a+b,0)/__foundPositions.length:null;
const __melhorPos=__foundPositions.length?Math.min(...__foundPositions):null;
"""
    rb=rb.replace(marker,extra+marker+"\n  territorial:intel,\n  dados_tecnicos:{telefone:txt(mx.telefone||mx.telefone_normalizado),categoria:txt(d.identidade?.categoria_google||mx.categoria_google),posicao_media:__posMedia,melhor_posicao:__melhorPos},",1)
by['PDF - Monta relatório determinístico']['parameters']['jsCode']=rb

# Preserve the exact current cover image while replacing pages 2-5 with Premium V2.
oldhtml=by['PDF - Gera HTML premium']['parameters']['jsCode']
m=re.search(r"const arch='[^']*';",oldhtml,re.S)
if not m: raise SystemExit('PATCH_ABORTADO: imagem da capa não encontrada')
tpl=Path('/tmp/html_node_template.js').read_text()
if '__ARCH_DECL__' not in tpl: raise SystemExit('PATCH_ABORTADO: placeholder ARCH ausente')
newhtml=tpl.replace('__ARCH_DECL__',m.group(0))
by['PDF - Gera HTML premium']['parameters']['jsCode']=newhtml

# Add/replace the internal territorial-data request node.
name='PDF - Busca inteligência territorial'
token=os.environ['MATRIX_REPORT_TOKEN']
http_version=max([float(n.get('typeVersion',4)) for n in nodes if n.get('type')=='n8n-nodes-base.httpRequest'] or [4.2])
params={
  'url':"={{ 'http://matrix_v1_app:8000/api/internal/report-data/' + ($json.matrix_job_id || $json.matrix_lead?.job_id || $json.job_id) + '/' + ($json.company_id || $json.matrix_lead?.company_id) }}",
  'sendHeaders':True,
  'headerParameters':{'parameters':[{'name':'X-Matrix-Internal','value':token}]},
  'options':{'timeout':15000}
}
if name in by:
    by[name]['parameters']=params
else:
    node={'parameters':params,'id':str(uuid.uuid4()),'name':name,'type':'n8n-nodes-base.httpRequest','typeVersion':http_version,'position':[6550,2832]}
    nodes.append(node);by[name]=node
con['PDF - Só segue se reservado']={'main':[[{'node':name,'type':'main','index':0}]]}
con[name]={'main':[[{'node':'PDF - Monta relatório determinístico','type':'main','index':0}]]}

# Bump report template version everywhere without changing other behavior.
def walk(x):
    if isinstance(x,dict): return {k:walk(v) for k,v in x.items()}
    if isinstance(x,list): return [walk(v) for v in x]
    if isinstance(x,str): return x.replace('premium-v1','premium-v2')
    return x
w=walk(w)
out=[w] if is_list else w
json.dump(out,open(p,'w'),ensure_ascii=False)
print('PATCH_WORKFLOW_OK',len(w['nodes']))
PY

docker exec -i -u node sdr-n8n sh -c 'cat > /home/node/pdf_workflow_v2.json' < /tmp/pdf_workflow_edit.json
docker exec -u node sdr-n8n n8n import:workflow --input=/home/node/pdf_workflow_v2.json >/tmp/pdfv2-import.log 2>&1 || { cat /tmp/pdfv2-import.log; exit 1; }
cat /tmp/pdfv2-import.log
docker exec -u node sdr-n8n n8n publish:workflow --id="$WFID" >/tmp/pdfv2-publish.log 2>&1 || { cat /tmp/pdfv2-publish.log; exit 1; }
cat /tmp/pdfv2-publish.log
docker exec -u node sdr-n8n n8n update:workflow --id="$WFID" --active=true >/tmp/pdfv2-activate.log 2>&1 || { cat /tmp/pdfv2-activate.log; exit 1; }
cat /tmp/pdfv2-activate.log

echo "[7/9] Restart n8n and reattach network"
docker restart sdr-n8n >/dev/null
for i in $(seq 1 45); do
  if docker inspect sdr-n8n --format '{{.State.Running}}' | grep -q true; then
    if docker exec sdr-n8n node -e "process.exit(0)" >/dev/null 2>&1; then break; fi
  fi
  sleep 2
done
docker network connect matrix_v1_network sdr-n8n 2>/dev/null || true

echo "[8/9] Verify published workflow and create isolated test PDF"
docker exec -u root sdr-n8n rm -f /home/node/pdf_workflow_after.json /home/node/pdfv2_sample.json /home/node/render_pdfv2_test.js /home/node/index.html /home/node/pdf_v2_test.pdf
docker exec -u node sdr-n8n n8n export:workflow --id="$WFID" --published --output=/home/node/pdf_workflow_after.json >/dev/null
docker cp sdr-n8n:/home/node/pdf_workflow_after.json "$BACKUP/pdf_workflow_after.json" >/dev/null
python3 - <<'PY'
import json
w=json.load(open('/opt/matrix-scraper-v1/'+'backup-pdf-premium-v2-' + open('/dev/null','w').name)) if False else None
p=max(__import__('pathlib').Path('/opt/matrix-scraper-v1').glob('backup-pdf-premium-v2-*'),key=lambda x:x.stat().st_mtime)/'pdf_workflow_after.json'
x=json.load(open(p)); w=x[0] if isinstance(x,list) else x
by={n['name']:n for n in w['nodes']}
h=by['PDF - Gera HTML premium']['parameters']['jsCode']
assert '1. Raio-X Competitivo' in h
assert '2. Presença por Região' in h
assert '3. Reputação e Presença Digital' in h
assert 'Oportunidades Estratégicas Identificadas' in h
assert 'PDF - Busca inteligência territorial' in by
assert 'premium-v2' in json.dumps(w,ensure_ascii=False)
print('WORKFLOW_V2_OK')
PY

# Pull real territorial payload for the render-only test.
curl -fsS -H "X-Matrix-Internal: $TOKEN" http://127.0.0.1:8088/api/internal/report-data/25/1396 > /tmp/territorial_test.json
python3 - <<'PY'
import json
t=json.load(open('/tmp/territorial_test.json'))
snap=(t.get('company_intelligence') or {}).get('snapshot') or {}
loc=snap.get('local_observations') or []
obs=[{'termo':x.get('term'),'bairro':x.get('neighborhood'),'cidade':x.get('city'),'estado':x.get('state'),'encontrado':x.get('position') is not None,'posicao':x.get('position')} for x in loc]
report={
 'identidade':{'nome_curto':'Chiller Tech','nome_completo':'Chiller Tech Refrigeração','segmento':'Climatização e refrigeração','mes_ano':'Outubro 2026','site_identificado':True,'categoria_google':'Serviço de manutenção de máquinas','local':'São Paulo/SP'},
 'scores':{'visibilidade':88,'reputacao':84,'presenca_digital':86,'labels':{'visibilidade':'Forte','reputacao':'Forte','presenca_digital':'Forte'}},
 'reputacao':{'nota':4.8,'avaliacoes':87},
 'observacoes':obs[:8],
 'analise_principal':{'posicao':1,'bairro':'Tucuruvi','termo':'Manutenção de chiller'},
 'concorrentes':[{'nome':'Concorrente A','posicao':2,'nota':4.7,'avaliacoes':120},{'nome':'Concorrente B','posicao':4,'nota':4.6,'avaliacoes':75},{'nome':'Concorrente C','posicao':7,'nota':4.9,'avaliacoes':42}],
 'plano':{'organico':[{'titulo':'Cobertura local','descricao':'Reforçar bairros prioritários com serviços e informações consistentes.'},{'titulo':'Perfil','descricao':'Manter categorias, serviços e descrições alinhados às buscas.'},{'titulo':'Avaliações','descricao':'Aumentar avaliações reais e recentes de forma contínua.'},{'titulo':'Monitoramento','descricao':'Acompanhar posições e cobertura por região.'}],
          'ads':[{'titulo':'Campanhas por serviço','descricao':'Separar campanhas pelos serviços com maior intenção comercial.'},{'titulo':'Segmentação regional','descricao':'Priorizar regiões com menor presença orgânica.'},{'titulo':'Conversão direta','descricao':'Direcionar para WhatsApp, ligação ou formulário.'},{'titulo':'Otimização contínua','descricao':'Concentrar verba nos termos e regiões que geram contatos.'}]},
 'dados_tecnicos':{'telefone':'11999999999','categoria':'Serviço de manutenção de máquinas','posicao_media':1,'melhor_posicao':1},
 'territorial':t
}
json.dump({'report':report},open('/tmp/pdfv2_sample.json','w'),ensure_ascii=False)
PY
docker exec -i -u node sdr-n8n sh -c 'cat > /home/node/pdfv2_sample.json' < /tmp/pdfv2_sample.json
cat > /tmp/render_pdfv2_test.js <<'NODE'
const fs=require('fs');
const wf=JSON.parse(fs.readFileSync('/home/node/pdf_workflow_after.json','utf8'));
const w=Array.isArray(wf)?wf[0]:wf;
const node=w.nodes.find(n=>n.name==='PDF - Gera HTML premium');
const sample=JSON.parse(fs.readFileSync('/home/node/pdfv2_sample.json','utf8'));
const fn=new Function('$json',node.parameters.jsCode);
const out=fn(sample);
const html=Buffer.from(out[0].binary.data.data,'base64');
fs.writeFileSync('/home/node/index.html',html);
(async()=>{
 const fd=new FormData();
 fd.append('files',new Blob([html],{type:'text/html'}),'index.html');
 for(const [k,v] of Object.entries({paperWidth:'8.27',paperHeight:'11.69',marginTop:'0',marginBottom:'0',marginLeft:'0',marginRight:'0',printBackground:'true',preferCssPageSize:'true'})) fd.append(k,v);
 const r=await fetch('http://gotenberg:3000/forms/chromium/convert/html',{method:'POST',body:fd});
 if(!r.ok) throw new Error('Gotenberg '+r.status+' '+await r.text());
 fs.writeFileSync('/home/node/pdf_v2_test.pdf',Buffer.from(await r.arrayBuffer()));
 console.log('TEST_PDF_OK',fs.statSync('/home/node/pdf_v2_test.pdf').size);
})().catch(e=>{console.error(e);process.exit(1)});
NODE
docker exec -i -u node sdr-n8n sh -c 'cat > /home/node/render_pdfv2_test.js' < /tmp/render_pdfv2_test.js
docker exec -u node sdr-n8n node /home/node/render_pdfv2_test.js
docker cp sdr-n8n:/home/node/pdf_v2_test.pdf "$ROOT/pdf_v2_test.pdf" >/dev/null
if command -v pdfinfo >/dev/null 2>&1; then pdfinfo "$ROOT/pdf_v2_test.pdf" | grep -E 'Pages:|Page size:|File size:'; fi
if command -v pdftotext >/dev/null 2>&1; then
  pdftotext "$ROOT/pdf_v2_test.pdf" /tmp/pdfv2.txt
  grep -q 'Raio-X Competitivo' /tmp/pdfv2.txt
  grep -q 'Presença por Região' /tmp/pdfv2.txt
  grep -q 'Reputação e Presença Digital' /tmp/pdfv2.txt
  grep -q 'Oportunidades Estratégicas Identificadas' /tmp/pdfv2.txt
  echo TEXT_VERIFY_OK
fi

echo "[9/9] Final health"
docker ps --filter name=matrix_v1_app --filter name=sdr-n8n --filter name=gotenberg --format '{{.Names}}|{{.Status}}'
echo "BACKUP=$BACKUP"
echo "PDF_V2_DEPLOY_OK"
