#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/matrix-scraper-v1
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$ROOT/backup-geo-map-pdf-$TS"
mkdir -p "$BACKUP"

echo "[1/7] Backup"
cp "$ROOT/app/matrix_intelligence/real_maps_v4.py" "$BACKUP/real_maps_v4.py"
docker exec -u node sdr-n8n n8n export:workflow --id=W2aWTTZOA8yIoNip --published --pretty --output=/home/node/geo_pdf_before.json >/dev/null
docker cp sdr-n8n:/home/node/geo_pdf_before.json "$BACKUP/pdf_workflow_before.json" >/dev/null

echo "[2/7] Align local map viewport with Matrix GEO"
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/opt/matrix-scraper-v1/app/matrix_intelligence/real_maps_v4.py')
s=p.read_text()

# Leaflet standard tiles use a 256px world tile size.
s=s.replace('world = 512 * (2 ** zoom)', 'world = 256 * (2 ** zoom)')
s=s.replace('(width*.44)/(512*max(xratio,1e-7))', '(width*.44)/(256*max(xratio,1e-7))')
s=s.replace('(height*.40)/(512*max(yratio,1e-7))', '(height*.40)/(256*max(yratio,1e-7))')

helper=r'''
def _inverse_mercator(x, y):
    lon = float(x) * 360.0 - 180.0
    n = math.pi * (1.0 - 2.0 * float(y))
    lat = math.degrees(math.atan(math.sinh(n)))
    return lat, lon


def frontend_primary_view(geo, neighborhoods, width=W, height=MAP_H, padding=80, max_zoom=13):
    """Replica o fitBounds do mapa GEO do frontend: bairro principal + padding 80 + maxZoom 13."""
    if not neighborhoods:
        return None
    rings=list(_chosen_polygons(geo, neighborhoods[:1]))
    coords=[p for ring in rings for p in ring if isinstance(p,(list,tuple)) and len(p)>=2]
    if not coords:
        return None
    projected=[mercator(float(p[0]),float(p[1])) for p in coords]
    xs=[p[0] for p in projected]; ys=[p[1] for p in projected]
    minx,maxx=min(xs),max(xs); miny,maxy=min(ys),max(ys)
    cx=(minx+maxx)/2.0; cy=(miny+maxy)/2.0
    lat,lon=_inverse_mercator(cx,cy)
    spanx=max(maxx-minx,1e-9); spany=max(maxy-miny,1e-9)
    usable_w=max(64,float(width)-2*float(padding))
    usable_h=max(64,float(height)-2*float(padding))
    scale=min(usable_w/(256.0*spanx),usable_h/(256.0*spany))
    zoom=max(1,min(int(max_zoom),math.floor(math.log2(max(scale,1e-9)))))
    return (lat,lon),zoom
'''

if 'def frontend_primary_view(' not in s:
    anchor='def local_real_map(company, center, geo, neighborhoods, fetch=fetch_basemap):'
    if anchor not in s:
        raise SystemExit('PATCH_ABORTADO: local_real_map não encontrado')
    s=s.replace(anchor,helper+'\n\n'+anchor,1)

pattern=r"""def local_real_map\(company, center, geo, neighborhoods, fetch=fetch_basemap\):\n(?:    .*\n)+?    return im\n"""
m=re.search(pattern,s)
if not m:
    raise SystemExit('PATCH_ABORTADO: corpo local_real_map não localizado')

new='''def local_real_map(company, center, geo, neighborhoods, fetch=fetch_basemap):
    """Mapa local com o mesmo enquadramento visto no painel GEO ao iniciar a raspagem."""
    loc=company['location'];lat,lon=loc['lat'],loc['lon']
    rings=list(_chosen_polygons(geo,neighborhoods))
    primary_view=frontend_primary_view(geo,neighborhoods)
    if primary_view:
        map_center,zoom=primary_view
    else:
        map_center=(center[0],center[1])
        zoom=13
    bg=fetch(map_center,zoom,read_map_key())
    im=canvas(bg,'MAPA DE COBERTURA LOCAL',
        f"Bairro principal: {neighborhoods[0] if neighborhoods else 'não identificado'}  •  Áreas selecionadas: {len(neighborhoods)}",
        'Mapa cartográfico: © OpenStreetMap contributors  •  Mesmo enquadramento GEO utilizado no início da raspagem.')
    overlay=Image.new('RGBA',(W,H));d=ImageDraw.Draw(overlay)
    primary_norm=normalize(neighborhoods[0]) if neighborhoods else ''
    for ring in rings:
        pp=[pixel(p,map_center,zoom) for p in ring]
        pp=[(x,y+MAP_TOP) for x,y in pp]
        if len(pp)>2:d.polygon(pp,fill=(30,173,111,42),outline=(27,198,117,210),width=3)
    c=pixel([center[1],center[0]],map_center,zoom)
    x,y=c
    if 0<x<W and 0<y<MAP_H:
        d.ellipse((x-8,y+MAP_TOP-8,x+8,y+MAP_TOP+8),fill='#1dce8b',outline='white',width=2)
        d.text((x+10,y+MAP_TOP+7),'Centro do Job',font=font(16,True),fill='white',stroke_width=2,stroke_fill='#15352b')
    pin(d,pixel([lon,lat],map_center,zoom),company['name'])
    im=Image.alpha_composite(im.convert('RGBA'),overlay).convert('RGB')
    return im
'''
s=s[:m.start()]+new+s[m.end():]
p.write_text(s)
PY
python3 -m py_compile "$ROOT/app/matrix_intelligence/real_maps_v4.py"

echo "[3/7] Rebuild Matrix intelligence"
cd "$ROOT"
docker compose build app >/tmp/geo-map-build.log 2>&1 || { tail -120 /tmp/geo-map-build.log; exit 1; }
docker compose up -d app intelligence >/tmp/geo-map-up.log 2>&1 || { cat /tmp/geo-map-up.log; exit 1; }
sleep 4

echo "[4/7] Enlarge PDF map box"
docker exec -u node sdr-n8n n8n export:workflow --id=W2aWTTZOA8yIoNip --published --output=/home/node/geo_pdf_edit.json >/dev/null
docker cp sdr-n8n:/home/node/geo_pdf_edit.json /tmp/geo_pdf_edit.json >/dev/null
python3 - <<'PY'
import json
p='/tmp/geo_pdf_edit.json'
x=json.load(open(p)); is_list=isinstance(x,list); w=x[0] if is_list else x
by={n['name']:n for n in w['nodes']}
node=by.get('PDF - Gera HTML premium')
if not node: raise SystemExit('PATCH_ABORTADO: HTML node não encontrado')
h=node['parameters']['jsCode']
h=h.replace('grid-template-columns:1.5fr .9fr;gap:3mm', 'grid-template-columns:1.68fr .82fr;gap:3mm')
h=h.replace('height:69mm;border:.3mm solid #d0d8df', 'height:76mm;border:.3mm solid #d0d8df')
node['parameters']['jsCode']=h
json.dump([w] if is_list else w,open(p,'w'),ensure_ascii=False)
PY
docker exec -i -u node sdr-n8n sh -c 'cat > /home/node/geo_pdf_import.json' < /tmp/geo_pdf_edit.json
docker exec -u node sdr-n8n n8n import:workflow --input=/home/node/geo_pdf_import.json >/tmp/geo-pdf-import.log 2>&1 || { cat /tmp/geo-pdf-import.log; exit 1; }
docker exec -u node sdr-n8n n8n publish:workflow --id=W2aWTTZOA8yIoNip >/tmp/geo-pdf-publish.log 2>&1 || { cat /tmp/geo-pdf-publish.log; exit 1; }
docker restart sdr-n8n >/dev/null
sleep 5
docker network connect matrix_v1_network sdr-n8n 2>/dev/null || true

echo "[5/7] Regenerate local maps for validation job"
if [ -x "$ROOT/ops/matrix_control.sh" ]; then
  "$ROOT/ops/matrix_control.sh" maps_only 25
else
  docker exec matrix_v1_intelligence python -m matrix_intelligence.cli maps-only --job 25
fi

echo "[6/7] Validate new map file"
MAP="$ROOT/matrix_intel_exports/25/1396/mapa_local_observado.png"
test -s "$MAP"
python3 - <<'PY'
from PIL import Image
p='/opt/matrix-scraper-v1/matrix_intel_exports/25/1396/mapa_local_observado.png'
im=Image.open(p)
print('LOCAL_MAP_OK',im.size)
assert im.width>=1000 and im.height>=700
PY

echo "[7/7] Health"
docker ps --filter name=matrix_v1_app --filter name=matrix_v1_intelligence --filter name=sdr-n8n --format '{{.Names}}|{{.Status}}'
echo "BACKUP=$BACKUP"
echo "GEO_MAP_PDF_ALIGNMENT_OK"
