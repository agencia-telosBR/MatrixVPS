#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/matrix-scraper-v1
WFID=W2aWTTZOA8yIoNip
TOKEN=$(cat "$ROOT/.matrix_report_token")

echo "[1] export live published workflow"
docker exec -u root sdr-n8n rm -f /home/node/pdf_live_check.json /home/node/pdf_live_sample.json /home/node/render_live_pdf.js /home/node/pdf_live_check.pdf /home/node/index_live.html
docker exec -u node sdr-n8n n8n export:workflow --id="$WFID" --published --output=/home/node/pdf_live_check.json >/dev/null
docker cp sdr-n8n:/home/node/pdf_live_check.json /tmp/pdf_live_check.json >/dev/null

echo "[2] verify live template markers"
python3 - <<'PY'
import json
x=json.load(open('/tmp/pdf_live_check.json'))
w=x[0] if isinstance(x,list) else x
by={n['name']:n for n in w['nodes']}
for n in ['PDF - Busca inteligência territorial','PDF - Monta relatório determinístico','PDF - Gera HTML premium','PDF - Gotenberg renderiza']:
    assert n in by,n
h=by['PDF - Gera HTML premium']['parameters']['jsCode']
checks=[
 ('raiox','1. Raio-X Competitivo' in h),
 ('regiao','2. Presença por Região' in h),
 ('reputacao','3. Reputação e Presença Digital' in h),
 ('oportunidades','Oportunidades Estratégicas Identificadas' in h),
 ('nullfix',"String(v).trim()===''" in h),
 ('no_footer_note','Este relatório apresenta fatos observados na amostra coletada' not in h),
]
for k,v in checks:
    print(k,v)
    assert v,k
print('LIVE_TEMPLATE_OK')
PY

echo "[3] verify internal territorial API"
curl -fsS -H "X-Matrix-Internal: $TOKEN" http://127.0.0.1:8088/api/internal/report-data/25/1396 > /tmp/territorial_live.json
python3 - <<'PY'
import json
j=json.load(open('/tmp/territorial_live.json'))
assert j.get('ok') is True
assert isinstance(j.get('regional'),list) and len(j['regional'])==3
assert j.get('mapa_local_data_uri','').startswith('data:image/png;base64,')
print('TERRITORIAL_API_OK',j.get('center_label'),len(j.get('regional') or []))
PY

echo "[4] render current live template through Gotenberg"
python3 - <<'PY'
import json
t=json.load(open('/tmp/territorial_live.json'))
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
json.dump({'report':report},open('/tmp/pdf_live_sample.json','w'),ensure_ascii=False)
PY
docker exec -i -u node sdr-n8n sh -c 'cat > /home/node/pdf_live_sample.json' < /tmp/pdf_live_sample.json
cat > /tmp/render_live_pdf.js <<'NODE'
const fs=require('fs');
const wf=JSON.parse(fs.readFileSync('/home/node/pdf_live_check.json','utf8'));
const w=Array.isArray(wf)?wf[0]:wf;
const node=w.nodes.find(n=>n.name==='PDF - Gera HTML premium');
const sample=JSON.parse(fs.readFileSync('/home/node/pdf_live_sample.json','utf8'));
const fn=new Function('$json',node.parameters.jsCode);
const out=fn(sample);
const html=Buffer.from(out[0].binary.data.data,'base64');
fs.writeFileSync('/home/node/index_live.html',html);
(async()=>{
 const fd=new FormData();
 fd.append('files',new Blob([html],{type:'text/html'}),'index.html');
 for(const [k,v] of Object.entries({paperWidth:'8.27',paperHeight:'11.69',marginTop:'0',marginBottom:'0',marginLeft:'0',marginRight:'0',printBackground:'true',preferCssPageSize:'true'})) fd.append(k,v);
 const r=await fetch('http://gotenberg:3000/forms/chromium/convert/html',{method:'POST',body:fd});
 if(!r.ok) throw new Error('Gotenberg '+r.status+' '+await r.text());
 fs.writeFileSync('/home/node/pdf_live_check.pdf',Buffer.from(await r.arrayBuffer()));
 console.log('LIVE_RENDER_OK',fs.statSync('/home/node/pdf_live_check.pdf').size);
})().catch(e=>{console.error(e);process.exit(1)});
NODE
docker exec -i -u node sdr-n8n sh -c 'cat > /home/node/render_live_pdf.js' < /tmp/render_live_pdf.js
docker exec -u node sdr-n8n node /home/node/render_live_pdf.js
docker cp sdr-n8n:/home/node/pdf_live_check.pdf "$ROOT/pdf_v2_live_verified.pdf" >/dev/null
test -s "$ROOT/pdf_v2_live_verified.pdf"
echo "PDF_LIVE_VERIFY_OK"
