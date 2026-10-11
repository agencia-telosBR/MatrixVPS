#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== MAIN SEND ENDPOINT ==="
grep -n -B8 -A45 'send-to-sheet' app/main.py || true
echo "=== APP JS SEND FUNCTION ==="
grep -n -A70 -B10 'async function sendCurrentJobToSheet' app/static/app.js || true
echo "=== SHEET FUNCTION NAMES ==="
grep -nE '^def |^async def ' app/sheet_integration.py
echo "=== SHEET TARGET SECTION ==="
grep -n -A45 -B35 'target = int' app/sheet_integration.py || true
echo "=== SHEET SELECTED REFS ==="
grep -n -A25 -B20 -E 'job_m2_selected_leads|selected_order|mobile_phone|phone_normalized' app/sheet_integration.py || true
