#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/matrix-scraper-v1"
FILE="$BASE/app/matrix_intelligence/regional_v4.py"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backup-remove-regional-map-$STAMP"

mkdir -p "$BACKUP"
cp -a "$FILE" "$BACKUP/regional_v4.py"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("/opt/matrix-scraper-v1/app/matrix_intelligence/regional_v4.py")
s = p.read_text(encoding="utf-8")

# Desativa somente a geração do PNG regional de 500 km.
old = """    region_file=root/'mapa_raio_500km_top3.png'
    regional_done=False
    if key:
        try:
            data=png(regional_real_map((origin['lat'],origin['lon']),report))
            temp=region_file.with_suffix('.tmp');temp.write_bytes(data);temp.replace(region_file)
            regional_done=True
        except Exception as exc:
            report['limitations'].append('Mapa regional pendente: '+type(exc).__name__)
    else:report['limitations'].append('Sem chave MapTiler Static Maps válida: dois mapas reais pendentes')
"""

new = """    # V5: o mapa regional de 500 km foi descontinuado.
    # Os dados X/Y/Z continuam disponíveis em regional_top3/regional_bands.
    region_file=root/'mapa_raio_500km_top3.png'
    regional_done=False
"""

if old in s:
    s = s.replace(old, new, 1)
else:
    # Fallback tolerante a pequenas diferenças de formatação.
    pattern = re.compile(
        r"\s+region_file=root/'mapa_raio_500km_top3\.png'\n"
        r"\s+regional_done=False\n"
        r"\s+if key:\n"
        r"(?:.|\n)*?"
        r"\s+else:report\['limitations'\]\.append\([^\n]+\)\n",
        re.M
    )
    m = pattern.search(s)
    if not m:
        raise SystemExit("PATCH_ABORTADO: bloco regional de mapa não encontrado; nenhum arquivo alterado.")
    s = s[:m.start()] + "\n    # V5: mapa regional de 500 km descontinuado.\n    region_file=root/'mapa_raio_500km_top3.png'\n    regional_done=False\n" + s[m.end():]

# Não copiar mapa regional para as pastas das empresas.
s = re.sub(
    r"\n\s+if regional_done:\n\s+import shutil\n\s+shutil\.copy2\(region_file,reg_file\)",
    "",
    s,
    count=1,
)

# O payload mantém os dados regionais, mas o caminho de imagem fica nulo.
s = s.replace(
    "'regional':'mapa_raio_500km_top3.png' if regional_done else None,",
    "'regional':None,"
)

compile(s, str(p), "exec")
p.write_text(s, encoding="utf-8")
print("PATCH_PYTHON_OK")
PY

python3 -m py_compile "$FILE"

# Remove somente artefatos regionais antigos; preserva mapas locais.
find "$BASE/matrix_intel_exports" -type f -name 'mapa_raio_500km_top3.png' -delete 2>/dev/null || true

docker cp "$FILE" matrix_v1_intelligence:/app/matrix_intelligence/regional_v4.py
docker restart matrix_v1_intelligence >/dev/null
sleep 3

echo "PATCH_OK"
echo "Mapa regional de 500 km desativado."
echo "Dados regionais X/Y/Z preservados em regional_top3 e regional_bands."
echo "Backup: $BACKUP"
