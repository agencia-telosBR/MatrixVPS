#!/usr/bin/env bash
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/agencia-telosBR/MatrixVPS/main/ops/approved/apply_sniper_v3.sh -o /tmp/apply_sniper_v4.sh
chmod 700 /tmp/apply_sniper_v4.sh
bash /tmp/apply_sniper_v4.sh
