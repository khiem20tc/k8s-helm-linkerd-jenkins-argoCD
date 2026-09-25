#!/bin/bash
# Download pinned CLI tools into on-prem/.bin (nothing is installed system-wide).
source "$(dirname "$0")/lib.sh"

mkdir -p "$BIN_DIR"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "Unsupported architecture: $arch" ;;
esac

version_of() { [ -x "$BIN_DIR/$1" ] && cat "$BIN_DIR/.$1.version" 2>/dev/null || true; }
mark() { echo "$2" > "$BIN_DIR/.$1.version"; }

if [ "$(version_of kind)" != "$KIND_VERSION" ]; then
    log "Downloading kind ${KIND_VERSION}"
    curl -fsSLo "$BIN_DIR/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${os}-${arch}"
    chmod +x "$BIN_DIR/kind"
    mark kind "$KIND_VERSION"
fi

if [ "$(version_of helm)" != "$HELM_VERSION" ]; then
    log "Downloading helm ${HELM_VERSION}"
    tmp=$(mktemp -d)
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-${os}-${arch}.tar.gz" | tar -xz -C "$tmp"
    mv "$tmp/${os}-${arch}/helm" "$BIN_DIR/helm"
    rm -rf "$tmp"
    mark helm "$HELM_VERSION"
fi

if [ "$(version_of linkerd)" != "$LINKERD_VERSION" ]; then
    log "Downloading linkerd ${LINKERD_VERSION}"
    suffix="${os}-${arch}"
    [ "$os-$arch" = "darwin-amd64" ] && suffix="darwin"
    curl -fsSLo "$BIN_DIR/linkerd" \
        "https://github.com/linkerd/linkerd2/releases/download/${LINKERD_VERSION}/linkerd2-cli-${LINKERD_VERSION}-${suffix}"
    chmod +x "$BIN_DIR/linkerd"
    mark linkerd "$LINKERD_VERSION"
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl is required (brew install kubectl)"
command -v docker >/dev/null 2>&1 || die "docker is required"

ok "Tools ready in $BIN_DIR"
kind version
helm version --short
linkerd version --client --short
