#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
grep -n -A80 -B50 -E "with_both_maps|maps_pending|regional_done" app/matrix_intelligence/regional_v4.py | sed -n '1,260p'
echo "=== LOCAL MAP FILE ==="
ls -lh matrix_intel_exports/25/1396/mapa_local_observado.png
file matrix_intel_exports/25/1396/mapa_local_observado.png
