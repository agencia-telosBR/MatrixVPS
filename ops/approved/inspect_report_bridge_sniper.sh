#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
grep -n -A220 -B20 'report-data' app/matrix_intelligence/api.py | sed -n '1,360p'
