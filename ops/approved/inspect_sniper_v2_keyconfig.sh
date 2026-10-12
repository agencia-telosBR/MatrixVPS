#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
sed -n '1,95p' app/sniper_v2/api.py
