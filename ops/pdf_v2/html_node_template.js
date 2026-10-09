const base=$json||{};
const r=base.report||{};
const t=r.territorial||{};
const esc=v=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]));
const txt=v=>String(v??'').trim();
const num=v=>{const n=Number(String(v??'').replace(',','.'));return Number.isFinite(n)?n:null;};
const fmtNota=v=>num(v)===null?'—':num(v).toFixed(1).replace('.',',');
const fmtPos=v=>num(v)===null?'—':`${Math.round(num(v))}º`;
const scoreClass=v=>Number(v)>=80?'green':Number(v)>=60?'blue':Number(v)>=40?'gold':'red';
const norm=v=>txt(v).toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]+/g,' ').trim();
const obs=Array.isArray(r.observacoes)?r.observacoes:[];
const comps=Array.isArray(r.concorrentes)?r.concorrentes.slice(0,3):[];
const found=obs.filter(o=>o&&o.encontrado);
const positions=found.map(o=>num(o.posicao)).filter(v=>v!==null);
const posMedia=num(r.dados_tecnicos?.posicao_media)??(positions.length?positions.reduce((a,b)=>a+b,0)/positions.length:null);
const melhorPos=num(r.dados_tecnicos?.melhor_posicao)??(positions.length?Math.min(...positions):null);
const totalObs=obs.length||Number(r.amostra?.observacoes||0)||0;
const encontrados=found.length;
const pctBusca=totalObs?Math.round((encontrados/totalObs)*100):0;
const job=t.job||{};
const neighborhoods=Array.isArray(job.neighborhoods)?job.neighborhoods.filter(Boolean):[];
const regionals=Array.isArray(t.regional)?t.regional:[];
const lookup=t.competitor_presence||{};
const siteOwn=!!r.identidade?.site_identificado || !!r.reputacao?.site_identificado || txt(r.presenca_digital?.site_identificado).toLowerCase()==='true';
const digitalLabel=(name,isSelf=false)=>{
  if(isSelf) return siteOwn?'Site próprio':(Number(r.scores?.presenca_digital)>=60?'Presença estruturada':'Presença limitada');
  const p=lookup[norm(name)]||lookup[txt(name).toLowerCase()]||null;
  if(!p) return '—';
  return p.site_identificado?'Site próprio':'Sem site identificado';
};
const directRows=[...comps.map(c=>({...c,self:false})),{
  nome:r.identidade?.nome_curto||r.identidade?.nome_completo||'Empresa analisada',
  posicao:num(r.analise_principal?.posicao)??melhorPos,
  nota:r.reputacao?.nota,
  avaliacoes:r.reputacao?.avaliacoes,
  self:true
}].sort((a,b)=>(num(a.posicao)??999)-(num(b.posicao)??999));
const compRows=directRows.map(c=>`<tr class="${c.self?'self':''}"><td>${esc(c.nome)}</td><td class="center">${fmtPos(c.posicao)}</td><td class="center">${fmtNota(c.nota)}</td><td class="center">${esc(c.avaliacoes??'—')}</td><td>${esc(digitalLabel(c.nome,c.self))}</td></tr>`).join('');
const bairroMap=new Map();
for(const o of obs){
  const b=txt(o.bairro)||'Região não informada';
  if(!bairroMap.has(b)) bairroMap.set(b,{bairro:b,positions:[],seen:0,total:0});
  const x=bairroMap.get(b);x.total++;
  if(o.encontrado){x.seen++;const p=num(o.posicao);if(p!==null)x.positions.push(p);}
}
const bairroOrder=(neighborhoods.length?neighborhoods:[...bairroMap.keys()]).slice(0,7);
const bairroRows=bairroOrder.map(b=>{
  const x=bairroMap.get(b)||{positions:[],seen:0,total:0};
  const best=x.positions.length?Math.min(...x.positions):null;
  const appeared=x.seen>0;
  const leitura=appeared?(best<=10?'Boa presença':best<=20?'Presença moderada':'Presença baixa'):(x.total?'Não encontrado':'Sem observação individual');
  return `<tr><td>${esc(b)}</td><td class="center">${fmtPos(best)}</td><td class="center">${appeared?'SIM':'NÃO'}</td><td>${esc(leitura)}</td></tr>`;
}).join('');
const regionByZone=Object.fromEntries(regionals.map(x=>[x.zone,x]));
const regionalRows=['X','Y','Z'].map(z=>{
  const x=regionByZone[z]||null;
  const faixa=z==='X'?'0–100 km':z==='Y'?'100–250 km':'250–500 km';
  if(!x||!x.name) return `<tr><td><b>${z}</b> · ${faixa}</td><td class="center">—</td><td>Não identificado na amostra</td><td class="center">—</td><td class="center">—</td><td>Não identificado</td></tr>`;
  return `<tr><td><b>${z}</b> · ${faixa}</td><td class="center">${esc(num(x.distance_km)?.toFixed(0)??'—')} km</td><td>${esc(x.name)}</td><td class="center">${fmtNota(x.rating)}</td><td class="center">${esc(x.review_count??'—')}</td><td>${esc(x.presence_label||'Identificado em ≥1 busca')}</td></tr>`;
}).join('');
const searchedList=neighborhoods.length?neighborhoods.join(' • '):[...bairroMap.keys()].join(' • ');
const vis=Number(r.scores?.visibilidade||0), rep=Number(r.scores?.reputacao||0), dig=Number(r.scores?.presenca_digital||0);
const reviews=Number(r.reputacao?.avaliacoes||0);
const bestCompetitor=comps[0]||null;
const strongest = rep>=80?'Reputação bem avaliada':dig>=80?'Presença digital estruturada':vis>=65?'Boa visibilidade local':'Base de presença já identificada';
const weakness = vis<50?'Baixa recorrência nas buscas':reviews<20?'Baixo volume de prova social':pctBusca<60?'Cobertura territorial parcial':'Consistência ainda pode evoluir';
const opportunity = vis<60?'Expandir presença nos bairros pesquisados':reviews<50?'Ampliar prova social com avaliações recentes':'Defender posições fortes e ampliar cobertura';
const reputationStrengths=[];
if(num(r.reputacao?.nota)>=4.5) reputationStrengths.push(`Nota Google de ${fmtNota(r.reputacao?.nota)}, sinalizando boa percepção de quem avaliou.`);
if(siteOwn) reputationStrengths.push('Site próprio identificado, reforçando a estrutura de presença digital.');
if(pctBusca>=60) reputationStrengths.push(`Presença observada em ${encontrados} de ${totalObs} buscas analisadas.`);
if(!reputationStrengths.length) reputationStrengths.push('Há ativos digitais e sinais de presença que podem ser fortalecidos.');
const attention=[];
if(reviews<20) attention.push(`Apenas ${reviews} avaliações: a prova social ainda é limitada para comparação competitiva.`);
if(pctBusca<60 && totalObs) attention.push(`A empresa apareceu em ${encontrados} de ${totalObs} buscas observadas.`);
if(posMedia!==null && posMedia>10) attention.push(`Posição média observada de ${fmtPos(posMedia)}, fora do primeiro bloco de resultados.`);
if(!attention.length) attention.push('Manter monitoramento de posição, avaliações e cobertura regional.');
const repTable=[
 ['Nota Google',fmtNota(r.reputacao?.nota),num(r.reputacao?.nota)>=4.5?'Muito positiva':'Pode evoluir'],
 ['Avaliações',reviews,reviews>=50?'Prova social forte':reviews>=20?'Prova social moderada':'Prova social limitada'],
 ['Site próprio',siteOwn?'Identificado':'Não identificado',siteOwn?'Base digital estruturada':'Oportunidade digital'],
 ['Telefone público',txt(r.dados_tecnicos?.telefone)?'Identificado':'Não identificado',txt(r.dados_tecnicos?.telefone)?'Canal comercial disponível':'Revisar dados públicos'],
 ['Categoria principal',r.dados_tecnicos?.categoria||r.identidade?.categoria_google||'—','Aderência ao segmento'],
 ['Presença nas buscas',totalObs?`${encontrados}/${totalObs} buscas`:'—',pctBusca>=60?'Boa recorrência':pctBusca>=35?'Recorrência moderada':'Baixa recorrência'],
 ['Melhor posição observada',fmtPos(melhorPos),melhorPos!==null&&melhorPos<=10?'Competitiva':'Há espaço para ganho'],
 ['Posição média',fmtPos(posMedia),posMedia!==null&&posMedia<=10?'Forte':posMedia!==null&&posMedia<=20?'Moderada':'Baixa'],
 ['Cobertura por bairro',`${new Set(found.map(o=>txt(o.bairro)).filter(Boolean)).size}/${Math.max(neighborhoods.length,new Set(obs.map(o=>txt(o.bairro)).filter(Boolean)).size)||'—'} bairros`,'Cobertura observada']
];
const repRows=repTable.map(x=>`<tr><td><b>${esc(x[0])}</b></td><td>${esc(x[1])}</td><td>${esc(x[2])}</td></tr>`).join('');
const organico=Array.isArray(r.plano?.organico)?r.plano.organico.slice(0,4):[];
const ads=Array.isArray(r.plano?.ads)?r.plano.ads.slice(0,4):[];
const steps=(arr,kind='')=>arr.map((x,i)=>`<div class="step"><div class="stepn ${kind}">${i+1}</div><div class="stept">${esc(x.titulo||x.nome||x.acao||'Ação')}</div><div class="stepd">${esc(x.descricao||x.detalhe||x.texto||'')}</div></div>`).join('');
const priority=[
 {n:'1',title:'Visibilidade local',evidence:totalObs?`Presença em ${encontrados} de ${totalObs} buscas observadas`:`Visibilidade: ${vis}/100`},
 {n:'2',title:'Reputação',evidence:`Nota ${fmtNota(r.reputacao?.nota)} com ${reviews} avaliações`},
 {n:'3',title:'Cobertura regional',evidence:`${new Set(found.map(o=>txt(o.bairro)).filter(Boolean)).size} bairros com presença observada`}
];
const oppRows=[
 ['Ganhar recorrência local',totalObs?`${totalObs-encontrados} de ${totalObs} buscas sem presença observada`:'Visibilidade abaixo do potencial','Priorizar perfil e conteúdo para bairros/termos de maior intenção.'],
 ['Fortalecer prova social',`Nota ${fmtNota(r.reputacao?.nota)} · ${reviews} avaliações`,'Criar rotina contínua de avaliações reais e recentes.'],
 ['Ampliar cobertura territorial',searchedList||'Regiões pesquisadas na amostra','Atuar organicamente e com mídia paga nas áreas de menor presença.'],
 ...(bestCompetitor?[[ 'Reduzir diferença competitiva',`${bestCompetitor.nome}: ${fmtPos(bestCompetitor.posicao)} · ${bestCompetitor.avaliacoes??'—'} avaliações`,'Monitorar concorrência e defender termos com maior potencial comercial.' ]]:[])
].slice(0,4).map(x=>`<tr><td><b>${esc(x[0])}</b></td><td>${esc(x[1])}</td><td>${esc(x[2])}</td></tr>`).join('');
const direction=vis<50&&rep>=70
 ?'A prioridade é transformar a boa reputação existente em maior recorrência de aparição. O plano deve combinar expansão da presença nos bairros estratégicos, aumento da prova social e mídia paga orientada por intenção enquanto a presença orgânica evolui.'
 :vis<60
 ?'A empresa já possui uma base de presença, mas precisa ganhar consistência. Recomenda-se concentrar esforços nas regiões e termos em que há maior espaço competitivo, reforçando reputação e captação simultaneamente.'
 :'A presença observada já oferece uma base competitiva. O foco recomendado é defender posições fortes, expandir cobertura para novas regiões e aumentar a capacidade de conversão da demanda já existente.';
__ARCH_DECL__
const coverRightWords='POSIÇÃO<br>REPUTAÇÃO<br>PRESENÇA<br>OPORTUNIDADE';
const mapData=txt(t.mapa_local_data_uri);
const mapHtml=mapData?`<img src="${mapData}" alt="Mapa local observado">`:'<div class="map-empty">Mapa local não disponível para este job histórico.</div>';
const html=`<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8"><style>
@page{size:A4;margin:0}*{box-sizing:border-box}body{margin:0;background:#eef1f3;font-family:Arial,Helvetica,sans-serif;color:#243746;-webkit-print-color-adjust:exact;print-color-adjust:exact}.page{width:210mm;height:297mm;background:#fff;position:relative;overflow:hidden;page-break-after:always}.page:last-child{page-break-after:auto}.content{padding:15mm 16mm 14mm}.topbar{height:10mm;background:#102b42;color:#fff;display:flex;align-items:center;justify-content:space-between;padding:0 16mm;font-size:8pt;letter-spacing:.35px}.footer{position:absolute;left:16mm;right:16mm;bottom:7mm;border-top:.3mm solid #d2dae1;padding-top:2.5mm;display:flex;justify-content:space-between;color:#75818c;font-size:7.2pt}.h1{font-size:20pt;line-height:1.08;color:#102b42;margin:0 0 2.5mm;font-weight:700}.h2{font-size:12.5pt;color:#1b4969;margin:0 0 2.2mm;font-weight:700}.lead{font-size:9.6pt;line-height:1.38;color:#455867;margin:0 0 3.5mm}.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:2.5mm;margin:3mm 0 4mm}.score{border:.3mm solid #d5dde4;border-top:1.4mm solid #247ba0;border-radius:1.5mm;padding:3.2mm 1.5mm;text-align:center;background:#fff}.score.red{border-top-color:#db4b55}.score.green{border-top-color:#2a9d8f}.score.gold{border-top-color:#d3a33e}.score.blue{border-top-color:#247ba0}.score .n{font-size:17pt;font-weight:800;color:#102b42}.score .l{font-size:8.2pt;font-weight:700;margin-top:.8mm}.score .s{font-size:7pt;color:#7b8791;margin-top:.6mm}.card{border:.3mm solid #d5dde4;border-radius:1.5mm;background:#fff;padding:3.4mm;margin:2.5mm 0}.card.accent{border-left:1.3mm solid #247ba0}.card.orange{border-top:1.1mm solid #d8a246}.card.teal{border-top:1.1mm solid #2a9d8f}.card.navy{border-top:1.1mm solid #102b42}.card h3{font-size:10pt;color:#102b42;margin:0 0 1.2mm}.card p{font-size:8.8pt;line-height:1.36;color:#465966;margin:0}.tri{display:grid;grid-template-columns:repeat(3,1fr);gap:2.5mm;margin-top:3mm}.tri .card{margin:0;min-height:25mm}.tri .tag{font-size:7pt;text-transform:uppercase;letter-spacing:.7px;color:#7c8993;font-weight:700}.tri strong{display:block;color:#102b42;font-size:9.2pt;margin-top:1.7mm;line-height:1.28}table{border-collapse:collapse;width:100%;font-size:8pt;margin:2.5mm 0 4mm}th{background:#102b42;color:#fff;text-align:left;padding:2.4mm 2mm;font-size:7.8pt}td{border:.25mm solid #d0d8df;padding:2.25mm 2mm;vertical-align:middle}.center{text-align:center}.self td{background:#e4f4e9;font-weight:700}.section-label{font-size:8.5pt;font-weight:700;color:#102b42;margin:2mm 0 1.3mm}.map-grid{display:grid;grid-template-columns:1.5fr .9fr;gap:3mm;margin:2.5mm 0 3mm}.mapbox{height:69mm;border:.3mm solid #d0d8df;border-radius:1.6mm;overflow:hidden;background:#edf2f5}.mapbox img{width:100%;height:100%;object-fit:cover}.map-empty{height:100%;display:flex;align-items:center;justify-content:center;text-align:center;padding:8mm;color:#71808b;font-size:9pt}.mini-grid{display:grid;grid-template-columns:1fr 1fr;gap:2mm}.mini{border:.3mm solid #d5dde4;border-radius:1.2mm;padding:2.6mm;min-height:20.5mm}.mini .k{font-size:6.7pt;color:#75818c}.mini .v{font-size:10pt;color:#102b42;font-weight:800;margin-top:1mm;line-height:1.15}.areas{border:.3mm solid #d5dde4;border-radius:1.2mm;padding:2.6mm 3mm;font-size:7.5pt;line-height:1.4;color:#51636f;margin-bottom:2.6mm}.two{display:grid;grid-template-columns:1fr 1fr;gap:3mm}.bullet{display:grid;grid-template-columns:4mm 1fr;gap:1mm;margin:1.6mm 0}.bullet span{width:2mm;height:2mm;border-radius:50%;background:#247ba0;margin-top:1.4mm}.bullet p{font-size:8.4pt;line-height:1.32;margin:0;color:#455867}.steps{border:.3mm solid #d2dbe2;border-radius:1.3mm;overflow:hidden;margin:2.2mm 0 3mm}.steptitle{background:#edf2f6;padding:2.3mm 3mm;color:#102b42;font-size:9.5pt;font-weight:700}.step{display:grid;grid-template-columns:9mm 37mm 1fr;min-height:13mm;border-top:.25mm solid #d2dbe2}.stepn{display:flex;align-items:center;justify-content:center;background:#2a9d8f;color:#fff;font-size:12pt;font-weight:800}.stepn.ads{background:#247ba0}.stept{padding:2.6mm;font-weight:700;font-size:8pt;display:flex;align-items:center}.stepd{padding:2.6mm;font-size:7.8pt;line-height:1.3;color:#4b5d69;display:flex;align-items:center}.priority{display:grid;grid-template-columns:repeat(3,1fr);gap:2.5mm;margin:2.5mm 0}.priority>div{border:.3mm solid #d5dde4;border-top:1.2mm solid #247ba0;border-radius:1.3mm;padding:3mm}.priority .pn{font-size:7pt;color:#75818c}.priority h3{font-size:9.3pt;color:#102b42;margin:1mm 0}.priority p{font-size:7.6pt;line-height:1.28;color:#51636f;margin:0}.note{font-size:6.4pt;color:#7b8792;margin-top:1mm;line-height:1.2}.cover{background:#f5f2ec}.cover-left{position:absolute;left:0;top:0;width:68%;height:100%;background:#f7f5f0}.cover-right{position:absolute;right:0;top:0;width:32%;height:100%;background:#0e293e}.cover-goldline{position:absolute;left:67.2%;top:0;width:.45mm;height:100%;background:#b8924a}.cover-kicker{position:absolute;left:15mm;top:28mm;font-size:9pt;letter-spacing:3px;font-weight:700;color:#122d43}.cover-title{position:absolute;left:15mm;top:59mm;font-family:Georgia,'Times New Roman',serif;font-size:41pt;line-height:.92;color:#0d2b42}.cover-title span{display:block;color:#9a7737}.cover-company{position:absolute;left:15mm;top:119mm;font-family:Georgia,'Times New Roman',serif;font-size:26pt;color:#0d2b42}.cover-sub{position:absolute;left:15mm;top:141mm;width:92mm;font-size:13pt;line-height:1.4;color:#45525d}.cover-date{position:absolute;left:15mm;top:185mm;font-size:9.5pt;letter-spacing:2.5px;color:#45525d}.cover-slogan{position:absolute;left:15mm;top:216mm;font-size:8.2pt;line-height:1.65;letter-spacing:2.3px;color:#68747d}.cover-words{position:absolute;right:10mm;top:14mm;width:29mm;color:#d7dfe5;font-size:7.2pt;line-height:1.8;letter-spacing:2.2px}.cover-words:after{content:'';display:block;width:8mm;height:.5mm;background:#b8924a;margin-top:5mm}.cover-arch{position:absolute;left:119mm;top:54mm;width:78mm;height:132mm;border-radius:50%;overflow:hidden;border:.5mm solid #b8924a;background:#162f43}.cover-arch img{width:100%;height:100%;object-fit:cover}.cover-circle{position:absolute;left:105mm;top:50mm;width:95mm;height:143mm;border:.25mm solid rgba(184,146,74,.55);border-radius:50%}.cover-right-copy{position:absolute;right:9mm;top:154mm;width:32mm;color:#d5dde3;font-size:7pt;line-height:1.75;letter-spacing:2px}.cover-footer{position:absolute;left:0;right:0;bottom:0;height:27mm;border-top:.3mm solid #9da7af;background:rgba(255,255,255,.55);display:grid;grid-template-columns:1.4fr 1fr 1fr;padding:8mm 15mm 0;gap:8mm;font-size:7.6pt;color:#394956}.cover-footer b{color:#102b42}.cover-divider{border-left:.3mm solid #909ba4;padding-left:7mm}.brandline{width:15mm;height:.6mm;background:#b8924a;margin-bottom:4mm}
</style></head><body>
<section class="page cover">
 <div class="cover-left"></div><div class="cover-right"></div><div class="cover-goldline"></div>
 <div class="cover-kicker"><div class="brandline"></div>RELATÓRIO EXECUTIVO</div>
 <div class="cover-title">Radar<span>Competitivo</span></div>
 <div class="cover-company">${esc(r.identidade?.nome_curto)}</div>
 <div class="cover-sub">Diagnóstico de presença local, competitividade e oportunidade no Google</div>
 <div class="cover-date">${esc(r.identidade?.mes_ano)}</div>
 <div class="cover-slogan">DADOS QUE REVELAM<br>OPORTUNIDADES.<br>ESTRATÉGIAS QUE GERAM<br>RESULTADOS.</div>
 <div class="cover-words">${coverRightWords}</div>
 <div class="cover-circle"></div><div class="cover-arch"><img src="${arch}"></div>
 <div class="cover-right-copy">MAIS<br>VISIBILIDADE<br>MAIS<br>OPORTUNIDADES</div>
 <div class="cover-footer"><div><b>Cliente:</b> ${esc(r.identidade?.nome_completo)}</div><div class="cover-divider"><b>Segmento:</b> ${esc(r.identidade?.segmento)}</div><div class="cover-divider">Documento B2B | Confidencial</div></div>
</section>
<section class="page"><div class="topbar"><b>${esc(r.identidade?.nome_curto)} | Radar Competitivo</b><span>Visão executiva da competitividade</span></div><div class="content">
 <h1 class="h1">1. Raio-X Competitivo</h1><p class="lead">Leitura consolidada da posição da empresa, reputação e força digital frente aos concorrentes mais relevantes observados.</p>
 <div class="cards">
  <div class="score ${scoreClass(100-(Math.min(posMedia??40,40)/40*80))}"><div class="n">${fmtPos(posMedia)}</div><div class="l">Posição média</div><div class="s">nas buscas encontradas</div></div>
  <div class="score ${scoreClass(vis)}"><div class="n">${esc(vis)}/100</div><div class="l">Visibilidade</div><div class="s">${esc(r.scores?.labels?.visibilidade||'')}</div></div>
  <div class="score ${scoreClass(rep)}"><div class="n">${esc(rep)}/100</div><div class="l">Reputação</div><div class="s">${esc(r.scores?.labels?.reputacao||'')}</div></div>
  <div class="score ${scoreClass(dig)}"><div class="n">${esc(dig)}/100</div><div class="l">Presença digital</div><div class="s">${esc(r.scores?.labels?.presenca_digital||'')}</div></div>
 </div>
 <h2 class="h2">Comparativo direto</h2>
 <table><thead><tr><th>Empresa</th><th class="center">Posição</th><th class="center">Nota</th><th class="center">Avaliações</th><th>Presença digital</th></tr></thead><tbody>${compRows}</tbody></table>
 <div class="tri">
  <div class="card teal"><div class="tag">Maior força</div><strong>${esc(strongest)}</strong></div>
  <div class="card orange"><div class="tag">Maior fraqueza</div><strong>${esc(weakness)}</strong></div>
  <div class="card accent"><div class="tag">Maior oportunidade</div><strong>${esc(opportunity)}</strong></div>
 </div>
 </div><div class="footer"><span>Documento confidencial</span><span>Página 2</span></div></section>
<section class="page"><div class="topbar"><b>${esc(r.identidade?.nome_curto)} | Radar Competitivo</b><span>Presença por região</span></div><div class="content">
 <h1 class="h1">2. Presença por Região</h1><p class="lead">Cobertura local observada nas áreas pesquisadas e leitura técnica dos principais concorrentes identificados em um raio de até 500 km.</p>
 <div class="map-grid"><div class="mapbox">${mapHtml}</div><div class="mini-grid">
  <div class="mini"><div class="k">Bairro-base</div><div class="v">${esc(t.center_label||neighborhoods[0]||r.analise_principal?.bairro||'—')}</div></div>
  <div class="mini"><div class="k">Cidade</div><div class="v">${esc(job.city||r.identidade?.local||'—')}</div></div>
  <div class="mini"><div class="k">Bairros pesquisados</div><div class="v">${esc(neighborhoods.length||new Set(obs.map(o=>o.bairro).filter(Boolean)).size)}</div></div>
  <div class="mini"><div class="k">Buscas realizadas</div><div class="v">${esc(job.completed_searches??totalObs)}</div></div>
  <div class="mini"><div class="k">Empresas encontradas</div><div class="v">${esc(job.unique_companies??'—')}</div></div>
  <div class="mini"><div class="k">Concorrentes diretos</div><div class="v">${esc(comps.length)}</div></div>
 </div></div>
 <div class="areas"><b>Bairros analisados:</b> ${esc(searchedList||'Não informado')}</div>
 <div class="section-label">Presença por bairro</div>
 <table><thead><tr><th>Bairro pesquisado</th><th class="center">Melhor posição</th><th class="center">Apareceu?</th><th>Leitura</th></tr></thead><tbody>${bairroRows}</tbody></table>
 <div class="section-label">Concorrência regional — até 500 km</div>
 <table><thead><tr><th>Faixa</th><th class="center">Distância</th><th>Concorrente</th><th class="center">Nota Google</th><th class="center">Avaliações</th><th>Presença na busca</th></tr></thead><tbody>${regionalRows}</tbody></table>
 </div><div class="footer"><span>Documento confidencial</span><span>Página 3</span></div></section>
<section class="page"><div class="topbar"><b>${esc(r.identidade?.nome_curto)} | Radar Competitivo</b><span>Reputação e presença digital</span></div><div class="content">
 <h1 class="h1">3. Reputação e Presença Digital</h1><p class="lead">Leitura técnica dos principais dados públicos coletados sobre a empresa, sua prova social, estrutura digital e consistência de presença nas buscas.</p>
 <div class="cards">
  <div class="score ${scoreClass((num(r.reputacao?.nota)||0)*20)}"><div class="n">${fmtNota(r.reputacao?.nota)}</div><div class="l">Nota Google</div><div class="s">avaliação pública</div></div>
  <div class="score ${reviews>=50?'green':reviews>=20?'blue':reviews>=5?'gold':'red'}"><div class="n">${esc(reviews)}</div><div class="l">Avaliações</div><div class="s">prova social</div></div>
  <div class="score ${scoreClass(dig)}"><div class="n">${esc(dig)}/100</div><div class="l">Presença digital</div><div class="s">${siteOwn?'site próprio identificado':'estrutura observada'}</div></div>
  <div class="score ${scoreClass(rep)}"><div class="n">${esc(rep)}/100</div><div class="l">Reputação geral</div><div class="s">${esc(r.scores?.labels?.reputacao||'')}</div></div>
 </div>
 <h2 class="h2">Dados técnicos coletados</h2>
 <table><thead><tr><th>Indicador</th><th>Dado observado</th><th>Leitura</th></tr></thead><tbody>${repRows}</tbody></table>
 <div class="two">
  <div class="card teal"><h3>Forças de reputação</h3>${reputationStrengths.slice(0,3).map(x=>`<div class="bullet"><span></span><p>${esc(x)}</p></div>`).join('')}</div>
  <div class="card orange"><h3>Pontos de atenção</h3>${attention.slice(0,3).map(x=>`<div class="bullet"><span></span><p>${esc(x)}</p></div>`).join('')}</div>
 </div>
 </div><div class="footer"><span>Documento confidencial</span><span>Página 4</span></div></section>
<section class="page"><div class="topbar"><b>${esc(r.identidade?.nome_curto)} | Radar Competitivo</b><span>Plano de melhoria e captação</span></div><div class="content">
 <h1 class="h1">4. Plano de Melhoria e Captação</h1><p class="lead">Plano orientado pelos dados observados, combinando evolução orgânica e captação paga para transformar presença digital em novas oportunidades comerciais.</p>
 <div class="priority">${priority.map(p=>`<div><div class="pn">PRIORIDADE ${p.n}</div><h3>${esc(p.title)}</h3><p>${esc(p.evidence)}</p></div>`).join('')}</div>
 <div class="steps"><div class="steptitle">Frente 1 — Presença orgânica</div>${steps(organico,'')}</div>
 <div class="steps"><div class="steptitle">Frente 2 — Captação via Google Ads</div>${steps(ads,'ads')}</div>
 <h2 class="h2">Oportunidades Estratégicas Identificadas</h2>
 <table><thead><tr><th>Oportunidade</th><th>Evidência Observada</th><th>Ação Recomendada</th></tr></thead><tbody>${oppRows}</tbody></table>
 <div class="card navy"><h3>Direção recomendada</h3><p>${esc(direction)}</p></div>
 <div class="note">Este relatório apresenta fatos observados na amostra coletada e interpretações determinísticas baseadas nesses dados. Não representa garantia de posição futura ou de volume de clientes.</div>
 </div><div class="footer"><span>Documento confidencial</span><span>Página 5</span></div></section>
</body></html>`;
return [{json:{...base,html_chars:html.length,pdf_template_version:'premium-v2'},binary:{data:{data:Buffer.from(html,'utf8').toString('base64'),mimeType:'text/html',fileName:'index.html',fileExtension:'html'}}}];