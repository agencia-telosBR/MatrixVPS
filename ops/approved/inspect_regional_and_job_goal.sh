#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== REGIONAL 200-270 ==="; sed -n '200,270p' app/matrix_intelligence/regional_v4.py
echo "=== MAIN 2670-2865 ==="; sed -n '2670,2865p' app/main.py
echo "=== MAIN 45-70 ==="; sed -n '45,70p' app/main.py
echo "=== SCRAPER 1600-1740 ==="; sed -n '1600,1740p' app/scraper.py
echo "=== SCRAPER 1770-1935 ==="; sed -n '1770,1935p' app/scraper.py
