#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1

echo "=== REGIONAL SCAN CORE ==="
sed -n '180,285p' app/matrix_intelligence/regional_v4.py

echo "=== SCRAPER META CORE ==="
sed -n '1380,1940p' app/scraper.py

echo "=== MAIN PAYLOAD + EXPORT M2 ==="
sed -n '40,75p' app/main.py
sed -n '1490,1545p' app/main.py
sed -n '2670,3075p' app/main.py

echo "=== INDEX + APP JS RELEVANT ==="
sed -n '20,48p' app/index.html
sed -n '1,105p' app/static/app.js
sed -n '165,220p' app/static/app.js
