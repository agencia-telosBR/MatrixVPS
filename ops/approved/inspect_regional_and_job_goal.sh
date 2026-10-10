#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== APP JS 250-530 ==="
sed -n '250,530p' app/static/app.js
echo "=== MAIN SEND/SHEET ROUTES ==="
grep -n -A90 -B20 -E "send.*sdr|sheet|planilha|META móvel|meta_contatos|job_m2_selected_leads" app/main.py app/sheet_integration.py | sed -n '1,520p'
