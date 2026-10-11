#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== APP JS SEND ONLY ==="
sed -n '475,535p' app/static/app.js
echo "=== MAIN SHEET ROUTES ONLY ==="
grep -n -A55 -B15 -E "@app\.(post|get).*sheet|send.*sheet|sheet.*send" app/main.py | head -260
echo "=== SHEET INTEGRATION CORE ONLY ==="
sed -n '250,375p' app/sheet_integration.py
