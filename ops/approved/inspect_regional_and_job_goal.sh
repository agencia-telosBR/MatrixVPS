#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== UI META REFS ==="
grep -nE "Meta|META|lead_target|exportMeta" app/index.html app/static/app.js || true
echo "=== EXPORT MOBILE ROUTE ==="
sed -n '2676,2865p' app/main.py | grep -nE "mode|mobile_phone|phone_normalized|target|enriched|if False" || true
echo "=== REGIONAL CONFIG ==="
grep -nE "MATRIX_REGION_SEARCHES_PER_BAND|MATRIX_REGION_RESULTS_PER_SEARCH|MATRIX_REGION_CANDIDATES_PER_SEARCH|distances=" app/matrix_intelligence/regional_v4.py
