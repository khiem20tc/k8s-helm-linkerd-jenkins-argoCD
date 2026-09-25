#!/bin/bash
# Shared helpers for the on-prem (local kind) lab.
#
# SAFETY: every kubectl/helm/linkerd call goes through k/h/l below, which pin the
# isolated kubeconfig in on-prem/.kube/config and the kind context explicitly.
# The default ~/.kube/config (which may point at a real cluster) is never used.

set -euo pipefail

ONPREM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ONPREM_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$ONPREM_DIR/config.env"
if [ -f "$ONPREM_DIR/.env" ]; then
    # shellcheck source=/dev/null
    source "$ONPREM_DIR/.env"
fi

BIN_DIR="$ONPREM_DIR/.bin"
export PATH="$BIN_DIR:$PATH"

export KUBECONFIG="$ONPREM_DIR/.kube/config"
# Keep helm repositories/cache inside on-prem/ as well
export HELM_CONFIG_HOME="$ONPREM_DIR/.helm/config"
export HELM_CACHE_HOME="$ONPREM_DIR/.helm/cache"
export HELM_DATA_HOME="$ONPREM_DIR/.helm/data"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
die()  { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

# Refuse to continue unless the isolated kubeconfig points at the local kind cluster.
guard_local_cluster() {
    [ -f "$KUBECONFIG" ] || die "Local kubeconfig $KUBECONFIG not found. Run 'make cluster' first."

    local server
    server=$(kubectl --kubeconfig "$KUBECONFIG" config view \
        -o jsonpath="{.clusters[?(@.name==\"${KUBE_CONTEXT}\")].cluster.server}")
    case "$server" in
        https://127.0.0.1:*|https://localhost:*) ;;
        *) die "Context ${KUBE_CONTEXT} points at '${server:-<missing>}', not a local kind cluster. Aborting." ;;
    esac
}

k() { kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" "$@"; }
h() { helm --kubeconfig "$KUBECONFIG" --kube-context "$KUBE_CONTEXT" "$@"; }
l() { linkerd --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" "$@"; }

require_tools() {
    local missing=()
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [ ${#missing[@]} -eq 0 ] || die "Missing tools: ${missing[*]}. Run 'make tools'."
}

enabled() { [ "${1:-false}" = "true" ]; }

# Wait until a command succeeds (used for resources created asynchronously)
wait_for() {
    local description=$1 timeout=$2
    shift 2
    local waited=0
    until "$@" >/dev/null 2>&1; do
        if [ "$waited" -ge "$timeout" ]; then
            die "Timed out after ${timeout}s waiting for ${description}"
        fi
        sleep 5
        waited=$((waited + 5))
    done
}
