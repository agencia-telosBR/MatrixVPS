#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1

echo "=== REGIONAL SCAN ==="
sed -n '1,430p' app/matrix_intelligence/regional_v4.py

echo "=== JOB META / LIMIT / EXPORT REFS ==="
grep -RIn --exclude-dir=.git -E "meta.{0,20}job|job.{0,20}meta|target|meta_lead|lead_goal|max_leads|limit.*lead|export.*mobile|phone_is_mobile|celular|telefone.*m[oó]vel|export" app | sed -n '1,420p'
