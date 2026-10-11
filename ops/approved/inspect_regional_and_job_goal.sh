#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
sed -n '126,250p' app/sheet_integration.py
