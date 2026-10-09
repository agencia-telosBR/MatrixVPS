#!/usr/bin/env bash
set -euo pipefail

docker exec -u node sdr-n8n n8n export:workflow --all --output=/tmp/matrix_workflows.json >/tmp/n8n_export.log 2>&1 || {
  cat /tmp/n8n_export.log
  exit 1
}
docker cp sdr-n8n:/tmp/matrix_workflows.json /tmp/matrix_workflows.json >/dev/null

python3 -c '
import json,re
p="/tmp/matrix_workflows.json"
data=json.load(open(p))
if isinstance(data,dict): data=[data]
print("COUNT",len(data))
terms=re.compile(r"radar|competitivo|pdf|gotenberg|relat[oó]rio|report",re.I)
for w in data:
    s=json.dumps(w,ensure_ascii=False)
    if terms.search(s):
        print("--- WORKFLOW",w.get("id"),w.get("name"),"active=",w.get("active"))
        for n in w.get("nodes",[]):
            ns=json.dumps(n,ensure_ascii=False)
            if terms.search(ns):
                print("NODE",n.get("name"),n.get("type"))
                print(json.dumps(n.get("parameters",{}),ensure_ascii=False)[:5000])
'
rm -f /tmp/matrix_workflows.json
