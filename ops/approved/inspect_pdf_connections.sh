#!/usr/bin/env bash
set -euo pipefail
docker exec -u node sdr-n8n n8n export:workflow --id=W2aWTTZOA8yIoNip --published --output=/tmp/pdfwf.json >/dev/null
docker cp sdr-n8n:/tmp/pdfwf.json /tmp/pdfwf.json >/dev/null
python3 - <<'PY'
import json
w=json.load(open('/tmp/pdfwf.json'))
if isinstance(w,list): w=w[0]
names={n['name'] for n in w.get('nodes',[]) if n.get('name','').startswith('PDF - ') or n.get('name') in ['M2 - Monta dossiê Matrix','M0 - Monta dossiê relatório manual']}
print("NODES")
for n in w.get('nodes',[]):
    if n.get('name') in names:
        print(n.get('name'),n.get('type'),n.get('position'),n.get('id'))
print("CONNECTIONS")
for src,outs in w.get('connections',{}).items():
    if src in names or any(c.get('node') in names for arr in outs.values() for branch in arr for c in branch):
        print(src, json.dumps(outs,ensure_ascii=False))
PY
rm -f /tmp/pdfwf.json
