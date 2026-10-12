#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== INCLUDED ROUTER DETAILS ==="
docker exec matrix_v1_app python - <<'PY'
import main
for i,r in enumerate(main.app.routes):
    if type(r).__name__ == '_IncludedRouter':
        print('IDX',i,'DICT',getattr(r,'__dict__',{}))
        print('DIR',[x for x in dir(r) if not x.startswith('_')])
PY

echo "=== HTTP SNIPER STATUS ==="
for p in /sniper /api/sniper/health /api/sniper/accounts; do
  code=$(curl -sS -o /tmp/body -w '%{http_code}' http://127.0.0.1:8088$p || true)
  echo "$p -> $code"
  head -c 300 /tmp/body || true; echo
done

echo "=== WORKER TOP/FLOW ==="
sed -n '1,300p' app/worker.py

echo "=== SCRAPER FINISH TAIL ==="
sed -n '1880,2005p' app/scraper.py
