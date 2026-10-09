#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1

echo "=== FRONTEND GEO MAP REFERENCES ==="
grep -RIn --exclude-dir=.git -E "fitBounds|setView|MAPA DE COBERTURA LOCAL|CARREGAR MAPA|neighborhood|selectedAreas|selected_areas|areas proximas|áreas próximas|L\.map|Leaflet" app/static app/templates 2>/dev/null | sed -n '1,320p'

echo "=== MAP RENDERER REFERENCES ==="
grep -RIn --exclude-dir=.git -E "fitBounds|setView|Leaflet|OpenStreetMap|mapa_local_observado|local_observations|bounds|zoom" app/matrix_intelligence 2>/dev/null | sed -n '1,360p'
