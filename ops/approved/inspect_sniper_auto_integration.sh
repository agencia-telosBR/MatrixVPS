#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-scraper-v1
echo "=== WORKER ==="
sed -n '1,360p' app/worker.py
echo "=== SCRAPER RUN END ==="
grep -n -A140 -B80 -E 'def run_job|async def run_job|completed.*finished_at|SET status.*completed|status = .completed' app/scraper.py | tail -520
echo "=== CREATE JOB ==="
grep -n -A180 -B30 -E '@app.post\("/api/jobs"|def create_job|async def create_job' app/main.py | head -300
