#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== APP JS SEND ==="
sed -n '475,530p' app/static/app.js
echo "=== MAIN SHEETS ENDPOINTS ==="
grep -nE "@app\.(post|get).*sheet|sheets|send.*sheet|sheet.*send" app/main.py | sed -n '1,180p'
echo "=== SHEET INTEGRATION 240-380 ==="
sed -n '240,380p' app/sheet_integration.py
