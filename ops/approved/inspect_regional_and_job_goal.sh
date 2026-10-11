#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
sed -n '1,260p' app/matrix_intelligence/cli.py
