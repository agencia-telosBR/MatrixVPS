#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/matrix-scraper-v1"
CONTAINER="matrix_v1_intelligence"
APPROVED_DIR="$BASE/ops/approved"

action="${1:-}"
arg2="${2:-}"
arg3="${3:-}"

valid_job_id() {
  [[ "$1" =~ ^[1-9][0-9]{0,9}$ ]]
}

case "$action" in
  status)
    cd "$BASE"
    echo "=== containers ==="
    docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'NAMES|matrix_' || true
    echo
    echo "=== intelligence ==="
    docker logs --tail 40 "$CONTAINER" 2>&1 || true
    ;;

  regional_status)
    valid_job_id "$arg2" || { echo "INVALID_JOB_ID"; exit 2; }
    docker exec "$CONTAINER" python -m matrix_intelligence.cli regional-status "$arg2"
    ;;

  maps_only)
    valid_job_id "$arg2" || { echo "INVALID_JOB_ID"; exit 2; }
    docker exec "$CONTAINER" python -m matrix_intelligence.cli maps-only "$arg2"
    ;;

  logs)
    docker logs --tail 120 "$CONTAINER" 2>&1
    ;;

  restart_intelligence)
    docker restart "$CONTAINER"
    sleep 3
    docker ps --filter "name=$CONTAINER" --format 'table {{.Names}}\t{{.Status}}'
    ;;

  run_approved_patch)
    patch_id="$arg3"
    [[ "$patch_id" =~ ^[a-z0-9][a-z0-9_-]{0,79}$ ]] || {
      echo "INVALID_PATCH_ID"
      exit 2
    }
    script="$APPROVED_DIR/${patch_id}.sh"
    [[ -f "$script" ]] || { echo "PATCH_NOT_FOUND: $script"; exit 3; }
    [[ ! -L "$script" ]] || { echo "PATCH_SYMLINK_NOT_ALLOWED"; exit 4; }
    owner="$(stat -c '%U' "$script")"
    [[ "$owner" == "root" ]] || { echo "PATCH_OWNER_MUST_BE_ROOT"; exit 5; }
    echo "=== running approved patch: $patch_id ==="
    /usr/bin/env bash "$script"
    ;;

  *)
    echo "ACTION_NOT_ALLOWED"
    exit 2
    ;;
esac
