#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/matrix-scraper-v1
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT/backup-regional-mobile-export-$TS"
mkdir -p "$BACKUP"

for f in app/matrix_intelligence/regional_v4.py app/main.py app/scraper.py app/index.html app/static/app.js; do
  cp "$ROOT/$f" "$BACKUP/$(basename "$f")"
done

echo "[1/7] Regional: insistir por faixa X/Y/Z até esgotar orçamento"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/matrix_intelligence/regional_v4.py')
s=p.read_text()

def repl(src,start,end,new):
    a=src.find(start)
    b=src.find(end,a+len(start))
    if a<0 or b<0:
        raise SystemExit('PATCH_ABORTADO: '+start)
    return src[:a]+new+'\n\n'+src[b:]

zone="""def zone_points(center,zone,limit=24):
    \"\"\"Amostragem radial densa por faixa; pontos são apenas âncoras de consulta.\"\"\"
    lat,lon=center['lat'],center['lon']
    bearings=(0,45,90,135,180,225,270,315)
    if zone=='X':
        distances=(25,60,95)
        pts=[(lat,lon)]+[destination(lat,lon,d,a) for d in distances for a in bearings]
    elif zone=='Y':
        distances=(120,175,235)
        pts=[destination(lat,lon,d,a) for d in distances for a in bearings]
    elif zone=='Z':
        distances=(280,370,470)
        pts=[destination(lat,lon,d,a) for d in distances for a in bearings]
    else:
        raise ValueError('Faixa regional inválida')
    return pts[:max(1,min(int(limit),36))]
"""
s=repl(s,'def zone_points(','def term_list(',zone)

terms="""def term_list(job):
    raw=job.get('terms') or []
    if isinstance(raw,str):
        try:raw=json.loads(raw)
        except (ValueError,TypeError):raw=raw.split(',')
    base=[str(x).strip() for x in raw if str(x).strip() and signals(str(x),INDUSTRIAL)]
    base += [
        'manutenção de chiller industrial',
        'refrigeração industrial',
        'instalação de chiller industrial',
        'câmara fria industrial',
        'climatização industrial',
    ]
    out=[];seen=set()
    for term in base:
        key=normalize(term)
        if key and key not in seen:
            seen.add(key);out.append(term)
    return out[:6]
"""
s=repl(s,'def term_list(','def db_status(',terms)

verified="""def _verified_candidate(place,origin,source_key,zone):
    loc=coords_from_maps(place.get('maps_url'))
    if not loc:return None
    dist=haversine_km(origin['lat'],origin['lon'],loc['lat'],loc['lon'])
    if band_for_km(dist)!=zone:return None

    if place.get('website_url'):
        try:
            pages,issues=harvest(place['website_url'],max_pages=2,timeout=8)
            fit=classify(place,[{'source_url':x['url'],'text':x['text']} for x in pages if x.get('text')])
            if fit['fit']=='EVIDENCIA_INDUSTRIAL':
                for page in pages:
                    body=page.get('text','')
                    if signals(body, INDUSTRIAL):
                        return {'name':place['name'],'lat':loc['lat'],'lon':loc['lon'],'distance_km':round(dist,2),
                                'maps_url':place['maps_url'],'website_url':place.get('website_url'),
                                'proof_url':page['url'],'proof_text':body[:350], 'source_key':source_key,
                                'source_type':'regional_scraping'}
        except (TimeoutError,OSError,ValueError):
            pass

    maps_text=' '.join(str(place.get(k) or '') for k in (
        'name','category_primary','category_secondary','categories'
    ))
    if signals(maps_text, INDUSTRIAL):
        return {'name':place['name'],'lat':loc['lat'],'lon':loc['lon'],'distance_km':round(dist,2),
                'maps_url':place['maps_url'],'website_url':place.get('website_url'),
                'proof_url':place['maps_url'],'proof_text':maps_text[:350], 'source_key':source_key,
                'source_type':'regional_maps_evidence'}
    return None
"""
s=repl(s,'def _verified_candidate(','async def scan_region(',verified)

scan="""async def scan_region(conn,job,origin):
    \"\"\"Busca até 1 concorrente verificado por faixa, esgotando tentativas antes de deixar vazio.\"\"\"
    from playwright.async_api import async_playwright
    import inspect
    from scraper import collect_result_items,extract_place,ProviderBlockedError
    if len(inspect.signature(collect_result_items).parameters)!=3 or len(inspect.signature(extract_place).parameters)!=5:
        raise RuntimeError('Assinatura do scraper mudou; revisão necessária antes da investigação regional')

    selected=load_candidates(conn,job['id'])
    baseline=original_urls(conn,job['id'])
    exclude={canonical(x['maps_url']) for x in baseline if canonical(x['maps_url'])}
    exclude_names={normalize(x['name']) for x in baseline if x.get('name')}
    used={x['source_key'] for x in selected.values() if x}
    terms=term_list(job)

    budget=max(6,min(int(os.getenv('MATRIX_REGION_SEARCHES_PER_BAND','24')),36))
    result_limit=max(8,min(int(os.getenv('MATRIX_REGION_RESULTS_PER_SEARCH','15')),20))
    inspect_limit=max(8,min(int(os.getenv('MATRIX_REGION_CANDIDATES_PER_SEARCH','10')),15))

    browser=None;blocked=False
    try:
        async with async_playwright() as playwright:
            browser=await playwright.chromium.launch(headless=True,args=['--no-sandbox','--disable-dev-shm-usage'])
            context=await browser.new_context(locale='pt-BR')
            page=await context.new_page()

            for zone in ('X','Y','Z'):
                if selected.get(zone):continue
                attempts=0
                points=zone_points(origin,zone,36)

                for point in points:
                    if selected.get(zone) or attempts>=budget or blocked:break
                    for term in terms:
                        if selected.get(zone) or attempts>=budget or blocked:break
                        attempts+=1
                        q=f'{term} perto de {point[0]:.5f},{point[1]:.5f}'
                        try:
                            items=await collect_result_items(page,q,result_limit)
                            verified=0
                            for item in items[:min(inspect_limit,result_limit)]:
                                slug=canonical(item['href'])
                                if not slug or slug in exclude or slug in used:continue
                                place=await extract_place(page,item['href'],item.get('name_hint'),job['city'],job['state'])
                                place.pop('phone_raw',None);place.pop('phone_normalized',None)
                                if normalize(place.get('name')) in exclude_names:continue
                                source_key=canonical(place.get('maps_url'))
                                if not source_key or source_key in exclude or source_key in used:continue
                                c=_verified_candidate(place,origin,source_key,zone)
                                if c:
                                    save_candidate(conn,job['id'],zone,c)
                                    selected[zone]=c;used.add(source_key)
                                    verified=1
                                    break
                            save_scan(conn,job['id'],zone,point,q,len(items),'completed')
                            if verified:break
                        except ProviderBlockedError:
                            conn.rollback()
                            save_scan(conn,job['id'],zone,point,q,0,'blocked_provider','CAPTCHA / tráfego incomum')
                            blocked=True;break
                        except (TimeoutError,OSError) as exc:
                            conn.rollback()
                            save_scan(conn,job['id'],zone,point,q,0,'error',type(exc).__name__[:70])
                        await asyncio.sleep(2)

                print('[REGIONAL] job',job['id'],'faixa',zone,'tentativas',attempts,
                      'resultado',selected.get(zone,{}).get('name') if selected.get(zone) else 'não encontrado',
                      flush=True)
                if blocked:break

            await context.close()
    finally:
        if browser:await browser.close()
    return load_candidates(conn,job['id']),blocked
"""
s=repl(s,'async def scan_region(','def _load_geo(',scan)
p.write_text(s)
PY
python3 -m py_compile "$ROOT/app/matrix_intelligence/regional_v4.py"

echo "[2/7] Remover meta operacional do Job"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/main.py')
s=p.read_text()
s=s.replace("default=100,\n        ge=0,", "default=0,\n        ge=0,", 1)
p.write_text(s)

p=Path('/opt/matrix-scraper-v1/app/scraper.py')
s=p.read_text()
s=s.replace('    lead_target = job.get("lead_target", 0) or 0\n',
            '    lead_target = 0  # sem meta: executar todas as buscas configuradas\n',1)
s=s.replace("f\"meta={lead_target if lead_target else 'sem_meta'}\"",
            "f\"modo=todos_os_leads_com_celular\"")
s=s.replace("f\"[job {job_id}] concluido | META={len(selected_ids)}/{lead_target} | \"",
            "f\"[job {job_id}] concluido | celulares_selecionados={len(selected_ids)} | \"")
s=s.replace("current_query = 'Agente 2: finalizando enriquecimento dos leads META'",
            "current_query = 'Agente 2: finalizando enriquecimento dos leads com celular'")
p.write_text(s)
PY
python3 -m py_compile "$ROOT/app/main.py" "$ROOT/app/scraper.py"

echo "[3/7] Exportação M2 = todos os leads com celular, sem corte por meta"
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/matrix-scraper-v1/app/main.py')
s=p.read_text()
start=s.index('@app.get("/api/jobs/{job_id}/export-sdr-m2.xlsx")')
end=s.find('\n@app.',start+10)
if end<0:end=len(s)
block=s[start:end]
block=block.replace('mode: str = "target"', 'mode: str = "all"')
block=block.replace('mode = (mode or "target").lower()', 'mode = "all"  # exportação única: todos os leads com celular')
block=block.replace("""AND (
                        c.phone_normalized IS NOT NULL
                        OR c.mobile_phone IS NOT NULL
                        OR c.landline_phone IS NOT NULL
                    )""",
"""AND (
                        c.mobile_phone IS NOT NULL
                        OR c.phone_normalized ~ '^55[1-9][0-9]9[0-9]{8}$'
                    )""")
block=block.replace('if mode == "target" and selected_order and cid not in selected_order:', 'if False and selected_order and cid not in selected_order:')
block=block.replace('if mode == "target" and not selected_order:', 'if False and not selected_order:')
block=block.replace('if mode == "target" and selected_order:', 'if False and selected_order:')
block=block.replace('if mode == "target":', 'if False:')
block=block.replace('"META_MOVEL_M2_V6" if mode == "target" else "TODOS_M2_V6"', '"TODOS_CELULAR_M2_V7"')
s=s[:start]+block+s[end:]
p.write_text(s)
PY
python3 -m py_compile "$ROOT/app/main.py"

echo "[4/7] Interface: retirar Meta e deixar uma exportação única"
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/opt/matrix-scraper-v1/app/index.html')
s=p.read_text()
s=s.replace('<label>Meta de leads com celular</label>\n<input id="lead_target" type="number" value="100" min="0" max="5000">\n','')
s=s.replace('<button id="exportMetaSdr" type="button">EXPORTAR META MÓVEL + M2</button>\n','')
s=s.replace('<button id="exportAllSdr" type="button">EXPORTAR TODOS + M2 V4</button>',
            '<button id="exportAllSdr" type="button">EXPORTAR TODOS COM CELULAR + M2</button>')
p.write_text(s)

p=Path('/opt/matrix-scraper-v1/app/static/app.js')
s=p.read_text()
s=re.sub(r'lead_target:\s*Number\(\s*document\.getElementById\("lead_target"\)\.value\s*\)', 'lead_target: 0', s, count=1)
s=s.replace('+ ` | Meta: ${job.prospectable_companies}/${job.lead_target || "sem meta"}`\n        + (job.meta_contatos_atingida ? " ✓ META CONGELADA" : "")',
            '+ ` | Celulares: ${job.prospectable_companies || 0}`')
s=s.replace('`Celulares: ${mobile}/${target || "sem meta"} · Buscas: ${completedSearches}/${job.total_searches || 0}`',
            '`Celulares: ${mobile} · Buscas: ${completedSearches}/${job.total_searches || 0}`')
s=s.replace('`META congelada: ${job.m2_selected_count || target || 0} · Profundidade M2: ${ready}/${selected}`',
            '`Leads com celular selecionados: ${job.m2_selected_count || mobile || 0} · Profundidade M2: ${ready}/${selected}`')
p.write_text(s)
PY

echo "[5/7] Rebuild/restart"
cd "$ROOT"
docker compose build app worker intelligence >/tmp/mobile-export-build.log 2>&1 || { tail -160 /tmp/mobile-export-build.log; exit 1; }
docker compose up -d --force-recreate app worker intelligence >/tmp/mobile-export-up.log 2>&1 || { cat /tmp/mobile-export-up.log; exit 1; }
sleep 5

echo "[6/7] Validações"
grep -q 'EXPORTAR TODOS COM CELULAR + M2' "$ROOT/app/index.html"
! grep -q 'Meta de leads com celular' "$ROOT/app/index.html"
! grep -q 'EXPORTAR META MÓVEL' "$ROOT/app/index.html"
grep -q 'default=0' "$ROOT/app/main.py"
grep -q "MATRIX_REGION_SEARCHES_PER_BAND','24'" "$ROOT/app/matrix_intelligence/regional_v4.py"
grep -q "c.mobile_phone IS NOT NULL" "$ROOT/app/main.py"
docker exec matrix_v1_worker sh -lc 'grep -q "lead_target = 0  # sem meta" /app/scraper.py'
docker exec matrix_v1_app sh -lc 'grep -q "EXPORTAR TODOS COM CELULAR + M2" /app/index.html'

echo "[7/7] Health"
docker ps --filter name=matrix_v1_app --filter name=matrix_v1_worker --filter name=matrix_v1_intelligence --format '{{.Names}}|{{.Status}}'
echo "BACKUP=$BACKUP"
echo "REGIONAL_AND_MOBILE_EXPORT_OK"
