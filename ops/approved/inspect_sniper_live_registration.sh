#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== MAIN TAIL HOST ==="
tail -80 app/main.py
echo "=== DOCKERFILE ==="
cat app/Dockerfile
echo "=== MAIN TAIL CONTAINER ==="
docker exec matrix_v1_app sh -lc 'tail -80 /app/main.py'
echo "=== SNIPER FILES CONTAINER ==="
docker exec matrix_v1_app sh -lc 'find /app/sniper_v3 -maxdepth 1 -type f -printf "%f\n" | sort'
echo "=== ROUTE TYPES ==="
docker exec matrix_v1_app python -c "import main; print([(type(r).__name__,getattr(r,'path',None),getattr(r,'prefix',None)) for r in main.app.routes[-20:]])"
