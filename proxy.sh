#!/bin/ash
# Route10 DNSCrypt proxy wrapper for operational scripts.

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="${PROJECT_DIR}/scripts"

usage() {
    cat <<'EOF'
Usage: proxy.sh <command> [args...]

Commands:
  start [args...]           Run scripts/start.sh
  updater [args...]         Run scripts/updater.sh
  update-filters [args...]  Run scripts/update-filters.sh
  uninstall [args...]       Run scripts/uninstall.sh
EOF
}

cmd="${1:-}"
if [ -z "$cmd" ]; then
    usage
    exit 1
fi
shift || true

case "$cmd" in
    start|start.sh)
        exec /bin/ash "${SCRIPTS_DIR}/start.sh" "$@"
        ;;
    updater|updater.sh)
        exec /bin/ash "${SCRIPTS_DIR}/updater.sh" "$@"
        ;;
    update-filters|update-filters.sh|filters)
        exec /bin/ash "${SCRIPTS_DIR}/update-filters.sh" "$@"
        ;;
    uninstall|uninstall.sh)
        exec /bin/ash "${SCRIPTS_DIR}/uninstall.sh" "$@"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        usage
        exit 1
        ;;
esac
