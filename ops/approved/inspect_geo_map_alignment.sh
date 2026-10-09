#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== FRONTEND APP.JS GEO BLOCK ==="
sed -n '920,1040p' app/static/app.js
echo "=== REAL MAPS V4 ==="
sed -n '1,360p' app/matrix_intelligence/real_maps_v4.py
echo "=== MAPS.PY LOCAL ==="
grep -n -A220 -B40 -E "mapa_local_observado|render.*local|local.*map|fetch_basemap|fitBounds|bounds" app/matrix_intelligence/maps.py app/matrix_intelligence/real_maps_v4.py 2>/dev/null || true
