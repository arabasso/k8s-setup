#!/usr/bin/env bash
#
# Prepares a Debian 13 (trixie) or CentOS Stream 10 node and creates or joins
# a Kubernetes cluster:
#   - disables swap
#   - kernel modules and sysctl required by kubeadm/Calico
#   - SELinux permissive, firewalld off and NetworkManager ignoring the Calico
#     interfaces (when present, as kubeadm and Calico require)
#   - base packages
#   - containerd (Docker repository)
#   - kubeadm and kubelet (+ kubectl on control planes) from pkgs.k8s.io
#   - control planes: Helm and the kube-vip static pod for the VIP
#   - first control plane: 'kubeadm init', Calico (VXLAN) with Windows support
#     and metrics-server (kubectl top, HorizontalPodAutoscaler)
#   - other nodes: 'kubeadm join' as control plane or worker
#   - additional control planes: restart the system Deployments (CoreDNS,
#     Calico, tigera-operator) so their pods spread off the first node
#
# Usage (https://github.com/arabasso/k8s-setup):
#   curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | sudo bash -s -- [options]
#   sudo ./k8s-setup.sh [options]   (downloaded copy; see --help)
#
# The commands this script prints for other nodes follow the way it was run:
# 'curl ... | sudo bash -s --' when piped, 'sudo ./k8s-setup.sh' from a file.
#
# Examples (the same options work with 'curl ... | sudo bash -s --'):
#   # first control plane (prints the commands to join the other nodes)
#   sudo ./k8s-setup.sh -t control-plane -m init -a 192.168.1.70 -n k8s-endpoint -i eth0
#
#   # additional control plane
#   sudo ./k8s-setup.sh -k 1.37.2 -t control-plane -m join -a 192.168.1.70 -n k8s-endpoint -i eth0 \
#       --token abcdef.0123456789abcdef --ca-cert-hash sha256:<hash> --certificate-key <key>
#
#   # Linux worker
#   sudo ./k8s-setup.sh -k 1.37.2 -t worker -a 192.168.1.70 -n k8s-endpoint \
#       --token abcdef.0123456789abcdef --ca-cert-hash sha256:<hash>
#
#   # on a control plane: print fresh join commands for new nodes
#   sudo ./k8s-setup.sh --print-join
#
# Every option can also be given as an environment variable (CONTAINERD_VERSION,
# K8S_VERSION, NODE_TYPE, MODE, VIP, VIP_HOSTNAME, INTERFACE, TOKEN, ...).
# Whatever the node needs and was not given is asked interactively.

set -euo pipefail

# Where the scripts are published. Set K8S_SETUP_REF to a tag (e.g. v1.0.0) in
# released versions, so every printed command fetches this same version.
K8S_SETUP_REF="${K8S_SETUP_REF:-master}"
K8S_SETUP_URL="${K8S_SETUP_URL:-https://raw.githubusercontent.com/arabasso/k8s-setup/$K8S_SETUP_REF}"

# local: run from a file; remote: piped from curl (BASH_SOURCE is empty) or
# 'bash <(curl ...)' (BASH_SOURCE is a pipe, not a regular file).
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    RUN_MODE=local
    SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
    SETUP_COMMAND="sudo ./$SCRIPT_NAME"
else
    RUN_MODE=remote
    SCRIPT_NAME=k8s-setup.sh
    SETUP_COMMAND="curl -fsSL $K8S_SETUP_URL/k8s-setup.sh | sudo bash -s --"
fi

CONTAINERD_VERSION="${CONTAINERD_VERSION:-}"
K8S_VERSION="${K8S_VERSION:-}"
KUBE_VIP_VERSION="${KUBE_VIP_VERSION:-}"
CALICO_VERSION="${CALICO_VERSION:-}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-}"
METRICS_SERVER="${METRICS_SERVER:-true}"
NODE_TYPE="${NODE_TYPE:-}"
MODE="${MODE:-}"
VIP="${VIP:-}"
VIP_HOSTNAME="${VIP_HOSTNAME:-}"
INTERFACE="${INTERFACE:-}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
WINDOWS_SUPPORT="${WINDOWS_SUPPORT:-true}"
TOKEN="${TOKEN:-}"
CA_CERT_HASH="${CA_CERT_HASH:-}"
CERTIFICATE_KEY="${CERTIFICATE_KEY:-}"
PRINT_JOIN=false

usage() {
    cat <<EOF
Usage: $SETUP_COMMAND [options]

Node:
  -t, --node-type TYPE              control-plane or worker.
  -m, --mode MODE                   init (first control plane, creates the cluster)
                                    or join (joins an existing cluster).
                                    Workers always join.
  -f, --first-control-plane         Same as '-t control-plane -m init'.

Versions:
  -c, --containerd-version VERSION  containerd.io version (e.g. 2.1.4 or 2.1).
                                    Default: latest in the Docker repository.
  -k, --k8s-version VERSION         Kubernetes version (e.g. 1.37 or 1.37.2).
                                    Default: latest stable (dl.k8s.io/release/stable.txt).
                                    Joining nodes must use the cluster's version.
  -K, --kube-vip-version VERSION    kube-vip version (e.g. v1.3.1). Default: latest.
      --calico-version VERSION      Calico version (e.g. v3.32.1). Default: latest.
      --metrics-server-version VER  metrics-server version (e.g. v0.8.0). Default: latest.

Control plane endpoint:
  -a, --vip ADDRESS                 Control plane virtual IP (e.g. 192.168.1.70).
  -n, --vip-hostname NAME           Hostname for the VIP (e.g. k8s-endpoint).
  -i, --interface NAME              Interface kube-vip announces the VIP on
                                    (control planes only).

Cluster (init only):
      --pod-cidr CIDR               Pod network. Default: $POD_CIDR
      --service-cidr CIDR           Service network. Default: $SERVICE_CIDR
      --no-windows                  Skip the Calico/kube-proxy setup for Windows nodes.
      --no-metrics-server           Skip metrics-server (kubectl top, autoscaling).

Join:
      --token TOKEN                 Bootstrap token (abcdef.0123456789abcdef).
      --ca-cert-hash HASH           CA certificate hash (sha256:...).
      --certificate-key KEY         Certificate key (control planes only).
      --print-join                  On an existing control plane: create a new token
                                    and certificate key, print the join commands and
                                    exit without installing anything. VIP, hostname,
                                    interface and Windows support are read from the
                                    cluster unless given (-a, -n, -i, --no-windows).

  -h, --help                        Show this help.

Values the node needs that were not given are asked interactively.
'-m init' prints the commands to join the other nodes when it finishes.
EOF
}

log()  { echo -e "\n\033[1;34m==> $*\033[0m"; }
warn() { echo -e "\033[1;33mWarning: $*\033[0m" >&2; }
die()  { echo -e "\033[1;31mError: $*\033[0m" >&2; exit 1; }

# Everything below runs inside main, called on the last line: when the script is
# piped from curl and the download stops halfway, nothing runs. The body is not
# indented because its heredocs must keep their EOF markers at column 0.
main() {

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--node-type)          NODE_TYPE="${2:-}"; shift 2 ;;
        -m|--mode)               MODE="${2:-}"; shift 2 ;;
        -f|--first-control-plane) NODE_TYPE=control-plane; MODE=init; shift ;;
        -c|--containerd-version) CONTAINERD_VERSION="${2:-}"; shift 2 ;;
        -k|--k8s-version)        K8S_VERSION="${2:-}"; shift 2 ;;
        -K|--kube-vip-version)   KUBE_VIP_VERSION="${2:-}"; shift 2 ;;
        --calico-version)        CALICO_VERSION="${2:-}"; shift 2 ;;
        -a|--vip)                VIP="${2:-}"; shift 2 ;;
        -n|--vip-hostname)       VIP_HOSTNAME="${2:-}"; shift 2 ;;
        -i|--interface)          INTERFACE="${2:-}"; shift 2 ;;
        --pod-cidr)              POD_CIDR="${2:-}"; shift 2 ;;
        --service-cidr)          SERVICE_CIDR="${2:-}"; shift 2 ;;
        --no-windows)            WINDOWS_SUPPORT=false; shift ;;
        --metrics-server-version) METRICS_SERVER_VERSION="${2:-}"; shift 2 ;;
        --no-metrics-server)     METRICS_SERVER=false; shift ;;
        --token)                 TOKEN="${2:-}"; shift 2 ;;
        --ca-cert-hash)          CA_CERT_HASH="${2:-}"; shift 2 ;;
        --certificate-key)       CERTIFICATE_KEY="${2:-}"; shift 2 ;;
        --print-join)            PRINT_JOIN=true; shift ;;
        -h|--help)               usage; exit 0 ;;
        *)                       usage; die "invalid option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must be run as root (sudo)."

# sudo on RHEL-like systems leaves /usr/local/bin (where Helm goes) out of PATH.
export PATH="/usr/local/bin:$PATH"

# debian (Debian/Ubuntu, apt) or rhel (CentOS Stream/RHEL/Rocky/Alma, dnf).
OS_ID="$(. /etc/os-release && echo "$ID")"
OS_LIKE="$(. /etc/os-release && echo "${ID_LIKE:-}")"
OS_VERSION="$(. /etc/os-release && echo "${VERSION_ID:-}")"
case " $OS_ID $OS_LIKE " in
    *" debian "*)                         OS_FAMILY=debian ;;
    *" rhel "*|*" centos "*|*" fedora "*) OS_FAMILY=rhel ;;
    *)                                    die "unsupported distribution: $OS_ID" ;;
esac
case "$OS_ID:${OS_VERSION%%.*}" in
    debian:13|centos:10) ;;
    *) warn "tested on Debian 13 and CentOS Stream 10; this is $OS_ID $OS_VERSION." ;;
esac

is_ipv4() {
    local IFS=. octet
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for octet in $1; do
        (( 10#$octet <= 255 )) || return 1
    done
}

is_cidr() {
    [[ "$1" == */* ]] && is_ipv4 "${1%/*}" && [[ "${1#*/}" =~ ^[0-9]{1,2}$ ]] && (( ${1#*/} <= 32 ))
}

is_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]
}

is_interface() {
    [[ -n "$1" ]] && ip link show dev "$1" >/dev/null 2>&1
}

is_node_type()       { [[ "$1" == control-plane || "$1" == worker ]]; }
is_mode()            { [[ "$1" == init || "$1" == join ]]; }
is_token()           { [[ "$1" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]]; }
is_ca_cert_hash()    { [[ "$1" =~ ^(sha256:)?[a-f0-9]{64}$ ]]; }
is_certificate_key() { [[ "$1" =~ ^[a-f0-9]{64}$ ]]; }

# ask VAR "Prompt" validator [default]
# Asks on the terminal until the validator accepts the answer.
ask() {
    local var="$1" prompt="$2" validator="$3" default="${4:-}" answer
    [[ -r /dev/tty ]] || die "$var not given and no terminal to ask for it."
    while true; do
        read -r -p "$prompt${default:+ [$default]}: " answer < /dev/tty
        answer="${answer:-$default}"
        "$validator" "$answer" && break
        echo "Invalid value: '$answer'" >&2
    done
    printf -v "$var" '%s' "$answer"
}

# require VAR "Prompt" validator [default]
# Validates VAR when given, asks for it otherwise.
require() {
    local var="$1" prompt="$2" validator="$3" default="${4:-}"
    if [[ -n "${!var}" ]]; then
        "$validator" "${!var}" || die "invalid value for $var: ${!var}"
    else
        ask "$var" "$prompt" "$validator" "$default"
    fi
}

# Creates a new token and certificate key and prints the commands that join
# control planes and workers (Linux and Windows) to this cluster. Uses VIP,
# VIP_HOSTNAME, INTERFACE, KUBE_VERSION and WINDOWS_SUPPORT. Linux commands
# follow how this script was run (SETUP_COMMAND); the Windows one always
# downloads k8s-setup.ps1, which must run from a file to resume after a reboot.
print_join_info() {
    local certificate_key join_command token ca_cert_hash containerd_version common_args join_info

    certificate_key="$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n1)"
    join_command="$(kubeadm token create --print-join-command)"
    token="$(awk '{for (i = 1; i < NF; i++) if ($i == "--token") print $(i + 1)}' <<< "$join_command")"
    ca_cert_hash="$(awk '{for (i = 1; i < NF; i++) if ($i == "--discovery-token-ca-cert-hash") print $(i + 1)}' <<< "$join_command")"
    containerd_version="$(containerd --version | awk '{print $3}')"
    common_args="-k ${KUBE_VERSION#v} -a $VIP -n $VIP_HOSTNAME --token $token --ca-cert-hash $ca_cert_hash"

    join_info="$(cat <<EOF
Additional control planes (adjust -i to the node's interface):

  $SETUP_COMMAND -t control-plane -m join -i $INTERFACE $common_args --certificate-key $certificate_key

Linux workers:

  $SETUP_COMMAND -t worker $common_args
EOF
)"

    if [[ "$RUN_MODE" == local ]]; then
        join_info+="$(cat <<EOF


Copy $SCRIPT_NAME to each node first, or replace '$SETUP_COMMAND' with:

  curl -fsSL $K8S_SETUP_URL/k8s-setup.sh | sudo bash -s --
EOF
)"
    fi

    if [[ "$WINDOWS_SUPPORT" == true ]]; then
        join_info+="$(cat <<EOF


Windows workers (PowerShell as Administrator):

  irm $K8S_SETUP_URL/k8s-setup.ps1 -OutFile k8s-setup.ps1; powershell -ExecutionPolicy Bypass -File .\\k8s-setup.ps1 -KubernetesVersion $KUBE_VERSION -ContainerdVersion ${containerd_version#v} -Vip $VIP -VipHostname $VIP_HOSTNAME -Token $token -CaCertHash $ca_cert_hash
EOF
)"
    fi

    join_info+="$(cat <<EOF


The token expires in 24h and the certificate key in 2h. To create new ones,
run on a control plane:

  $SETUP_COMMAND --print-join
EOF
)"

    install -m 0600 /dev/null /root/k8s-join.txt
    echo "$join_info" > /root/k8s-join.txt

    echo "$join_info"
    echo
    echo "Saved to /root/k8s-join.txt"
}

if [[ "$PRINT_JOIN" == true ]]; then
    [[ -f /etc/kubernetes/admin.conf ]] || die "--print-join must run on a control plane of the cluster."
    export KUBECONFIG=/etc/kubernetes/admin.conf

    KUBE_VERSION="$(kubectl version -o json | jq -r .serverVersion.gitVersion)" \
        || die "could not reach the cluster."

    # Defaults come from the cluster and this node's kube-vip manifest.
    if [[ -z "$VIP_HOSTNAME" ]]; then
        VIP_HOSTNAME="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
        VIP_HOSTNAME="${VIP_HOSTNAME#https://}"
        VIP_HOSTNAME="${VIP_HOSTNAME%:*}"
    fi
    kube_vip_manifest=/etc/kubernetes/manifests/kube-vip.yaml
    if [[ -z "$VIP" && -f "$kube_vip_manifest" ]]; then
        VIP="$(awk '/name: (vip_)?address$/ {getline; print $2; exit}' "$kube_vip_manifest")"
    fi
    [[ -n "$VIP" ]] || VIP="$(getent hosts "$VIP_HOSTNAME" | awk '{print $1; exit}')"
    if [[ -z "$INTERFACE" && -f "$kube_vip_manifest" ]]; then
        INTERFACE="$(awk '/name: vip_interface$/ {getline; print $2; exit}' "$kube_vip_manifest")"
    fi
    [[ -n "$INTERFACE" ]] || INTERFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    if [[ "$WINDOWS_SUPPORT" == true ]] && ! kubectl get daemonset -n kube-system kube-proxy-windows >/dev/null 2>&1; then
        WINDOWS_SUPPORT=false
    fi

    is_ipv4 "$VIP" || die "could not find the VIP; pass it with -a."

    print_join_info
    exit 0
fi

# --------------------------------------------------------------------------
log "Node settings"
# --------------------------------------------------------------------------

require NODE_TYPE "Node type (control-plane/worker)" is_node_type

if [[ "$NODE_TYPE" == worker ]]; then
    [[ -z "$MODE" || "$MODE" == join ]] || die "a worker can only join an existing cluster."
    MODE=join
else
    require MODE "Create a new cluster or join an existing one (init/join)" is_mode
fi

require VIP "Control plane VIP" is_ipv4
require VIP_HOSTNAME "VIP hostname" is_hostname "k8s-endpoint"

if [[ "$NODE_TYPE" == control-plane ]]; then
    require INTERFACE "Network interface for the VIP" is_interface \
        "$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
fi

if [[ "$MODE" == init ]]; then
    is_cidr "$POD_CIDR" || die "invalid pod CIDR: $POD_CIDR"
    is_cidr "$SERVICE_CIDR" || die "invalid service CIDR: $SERVICE_CIDR"
else
    require TOKEN "Bootstrap token" is_token
    require CA_CERT_HASH "CA certificate hash" is_ca_cert_hash
    [[ "$CA_CERT_HASH" == sha256:* ]] || CA_CERT_HASH="sha256:$CA_CERT_HASH"
    if [[ "$NODE_TYPE" == control-plane ]]; then
        require CERTIFICATE_KEY "Certificate key" is_certificate_key
    fi
fi

echo "Node type: $NODE_TYPE ($MODE)"
echo "Endpoint:  $VIP_HOSTNAME ($VIP)"
[[ "$NODE_TYPE" == control-plane ]] && echo "Interface: $INTERFACE"
if [[ "$MODE" == init ]]; then
    echo "Pod CIDR:  $POD_CIDR"
    echo "Svc CIDR:  $SERVICE_CIDR"
    echo "Windows:   $WINDOWS_SUPPORT"
    echo "Metrics:   $METRICS_SERVER"
fi

# Prints the available versions of a package, one per line.
#   debian: 2.4.2-3~debian.13~trixie (apt-cache madison)
#   rhel:   2.4.2-3.el10 (dnf list --showduplicates, ignoring repo excludes)
list_pkg_versions() {
    if [[ "$OS_FAMILY" == debian ]]; then
        apt-cache madison "$1" | awk -F'|' '{gsub(/ /, "", $2); print $2}'
    else
        dnf list --showduplicates --quiet --setopt=disable_excludes=all "$1" 2>/dev/null \
            | awk -v pkg="$1" 'index($1, pkg ".") == 1 {v = $2; sub(/^[0-9]+:/, "", v); print v}'
    fi
}

# Prints the newest full package version matching the given prefix.
# E.g.: "2.1" -> "2.1.4-1~debian.13~trixie" or "2.1.4-1.el10".
resolve_pkg_version() {
    local pkg="$1" prefix="$2"
    list_pkg_versions "$pkg" | grep -E "^${prefix//./\\.}([.-]|$)" | sort -V | tail -n1 || true
}

# Installs packages: "name" or "name=version" (version as resolve_pkg_version prints).
pkg_install() {
    local args=() spec
    for spec in "$@"; do
        if [[ "$OS_FAMILY" == debian ]]; then
            args+=("$spec")
        else
            args+=("${spec/=/-}")
        fi
    done
    if [[ "$OS_FAMILY" == debian ]]; then
        apt-get install -y --allow-downgrades --allow-change-held-packages "${args[@]}"
    else
        dnf install -y --setopt=disable_excludes=all --setopt=install_weak_deps=False "${args[@]}"
    fi
}

# Prints the tag of the latest GitHub release of a repository.
latest_github_release() {
    local tag
    tag="$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name)" || return 1
    [[ -n "$tag" && "$tag" != null ]] || return 1
    echo "$tag"
}

# wait_until SECONDS command...
# Retries the command every 5 seconds until it succeeds or the time runs out.
wait_until() {
    local end=$((SECONDS + $1))
    shift
    until "$@" >/dev/null 2>&1; do
        (( SECONDS < end )) || return 1
        sleep 5
    done
}

# Copies admin.conf to ~/.kube/config of root and of the sudo user.
setup_kubeconfig() {
    local user home
    for user in root ${SUDO_USER:-}; do
        home="$(getent passwd "$user" | cut -d: -f6)"
        [[ -n "$home" ]] || continue
        install -D -m 0600 -o "$user" -g "$(id -gn "$user")" \
            /etc/kubernetes/admin.conf "$home/.kube/config"
        echo "kubeconfig: $home/.kube/config"
    done
}

# Spreads the system pods created while the first control plane was the only
# node (CoreDNS, Calico, tigera-operator). Pods never move by themselves:
# restarting their Deployments brings up new pods before removing the old
# ones, and the scheduler places them on the least loaded nodes. Waits for
# this node to be Ready first, so the scheduler counts it. Best effort: only
# warns on failure, never stops the script.
rebalance_system_pods() {
    local kubectl=(kubectl --kubeconfig /etc/kubernetes/admin.conf) node item
    # kubeadm names the node after the hostname, in lowercase.
    node="$(hostname | tr '[:upper:]' '[:lower:]')"

    if ! "${kubectl[@]}" wait --for=condition=Ready "node/$node" --timeout=300s >/dev/null 2>&1; then
        warn "node $node is not Ready; skipping the system pods rebalance."
        return 0
    fi

    for item in kube-system/coredns \
                calico-system/calico-apiserver \
                calico-system/calico-kube-controllers \
                calico-system/goldmane \
                tigera-operator/tigera-operator; do
        "${kubectl[@]}" -n "${item%%/*}" get deployment "${item##*/}" >/dev/null 2>&1 || continue
        "${kubectl[@]}" -n "${item%%/*}" rollout restart deployment "${item##*/}" \
            || warn "could not restart $item."
    done

    "${kubectl[@]}" -n kube-system rollout status deployment coredns --timeout=300s \
        || warn "CoreDNS did not finish restarting; check 'kubectl -n kube-system get pods -o wide'."
}

# Pulls an image into containerd's k8s.io namespace, the one the kubelet uses,
# so kubeadm and the static pods find it already there.
# ctr reads the terminal width from stdin to erase its progress tree before
# each redraw. Piped from curl, stdin is not the terminal and every redraw
# piles up, so give it the terminal, or hide the progress when there is none.
pull_image() {
    if { : </dev/tty; } 2>/dev/null; then
        ctr -n k8s.io image pull "$1" </dev/tty
    else
        echo "Pulling $1..."
        ctr -n k8s.io image pull "$1" >/dev/null
    fi
}

# --------------------------------------------------------------------------
log "Disabling swap"
# --------------------------------------------------------------------------

# Masking swap.target keeps every swap unit from being started at boot,
# whether it comes from fstab or from systemd-gpt-auto-generator.
systemctl mask swap.target
swapoff -a
sed -i '/^[^#].*\sswap\s/s/^/#/' /etc/fstab

if [[ -n "$(swapon --show --noheadings)" ]]; then
    swapon --show
    die "swap is still active."
fi

# --------------------------------------------------------------------------
log "Kernel modules and sysctl"
# --------------------------------------------------------------------------

cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat <<EOF > /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system

# --------------------------------------------------------------------------
log "SELinux, firewalld and NetworkManager"
# --------------------------------------------------------------------------

# kubeadm requires SELinux in permissive mode (RHEL-like systems).
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == Enforcing ]]; then
    setenforce 0
fi
if [[ -f /etc/selinux/config ]]; then
    sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
fi

# Calico asks for firewalld (or any other iptables manager) to be disabled.
if systemctl is-enabled firewalld >/dev/null 2>&1 || systemctl is-active firewalld >/dev/null 2>&1; then
    warn "disabling firewalld, as Calico requires."
    systemctl disable --now firewalld
fi

# Keeps NetworkManager away from the interfaces Calico creates.
if [[ -d /etc/NetworkManager/conf.d ]]; then
    cat <<EOF > /etc/NetworkManager/conf.d/calico.conf
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF
    systemctl reload NetworkManager 2>/dev/null || true
fi

# --------------------------------------------------------------------------
log "Base packages"
# --------------------------------------------------------------------------

if [[ "$OS_FAMILY" == debian ]]; then
    # ca-certificates/curl: HTTPS downloads; gnupg: dearmor repository keys
    # (Kubernetes and Helm); jq: kube-vip/Calico version lookup.
    apt-get update
    apt-get install -y ca-certificates curl gnupg jq
else
    # curl comes as curl-minimal; tar/openssl: Helm install script (extract
    # and checksum).
    dnf install -y ca-certificates jq tar openssl
    command -v curl >/dev/null 2>&1 || dnf install -y curl
fi

# --------------------------------------------------------------------------
log "Resolving the Kubernetes version"
# --------------------------------------------------------------------------

if [[ -z "$K8S_VERSION" ]]; then
    K8S_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" \
        || die "could not fetch the latest Kubernetes version."
    echo "No version given; using the latest stable: $K8S_VERSION"
    [[ "$MODE" == join ]] && warn "joining nodes must match the cluster version; pass it with -k."
fi

K8S_VERSION="${K8S_VERSION#v}"
[[ "$K8S_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "invalid Kubernetes version: $K8S_VERSION"
K8S_MINOR="$(cut -d. -f1,2 <<< "$K8S_VERSION")"

# --------------------------------------------------------------------------
log "Installing containerd"
# --------------------------------------------------------------------------

if [[ "$OS_FAMILY" == debian ]]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

    apt-get update
else
    # Only the stable channel; 'exclude' holds containerd.io when a version is pinned.
    cat <<EOF > /etc/yum.repos.d/docker-ce.repo
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
EOF
fi

if [[ -n "$CONTAINERD_VERSION" ]]; then
    pkg_version="$(resolve_pkg_version containerd.io "$CONTAINERD_VERSION")"
    [[ -n "$pkg_version" ]] || die "containerd.io $CONTAINERD_VERSION not found. Available:
$(list_pkg_versions containerd.io)"
    pkg_install "containerd.io=$pkg_version"
    if [[ "$OS_FAMILY" == debian ]]; then
        apt-mark hold containerd.io
    else
        echo "exclude=containerd.io" >> /etc/yum.repos.d/docker-ce.repo
    fi
else
    pkg_install containerd.io
fi

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl enable --now containerd
systemctl restart containerd

# --------------------------------------------------------------------------
# kubectl is only needed on control planes.
K8S_PACKAGES=(kubelet kubeadm)
[[ "$NODE_TYPE" == control-plane ]] && K8S_PACKAGES+=(kubectl)
log "Installing ${K8S_PACKAGES[*]} (v$K8S_MINOR)"
# --------------------------------------------------------------------------

if [[ "$OS_FAMILY" == debian ]]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
        | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

    apt-get update
else
    # 'exclude' is how the official instructions hold these packages on dnf.
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
fi

pkg_version="$(resolve_pkg_version kubeadm "$K8S_VERSION")"
[[ -n "$pkg_version" ]] || die "Kubernetes $K8S_VERSION not found. Available:
$(list_pkg_versions kubeadm)"

# kubeadm only requires conntrack in PATH for Kubernetes < 1.32.
if [[ "$(cut -d. -f1 <<< "$K8S_MINOR")" -eq 1 && "$(cut -d. -f2 <<< "$K8S_MINOR")" -lt 32 ]]; then
    if [[ "$OS_FAMILY" == debian ]]; then
        apt-get install -y conntrack
    else
        dnf install -y conntrack-tools
    fi
fi

if [[ "$OS_FAMILY" == debian ]]; then
    apt-mark unhold "${K8S_PACKAGES[@]}" >/dev/null 2>&1 || true
fi
pkg_install "${K8S_PACKAGES[@]/%/=$pkg_version}"
if [[ "$OS_FAMILY" == debian ]]; then
    apt-mark hold "${K8S_PACKAGES[@]}"
fi

systemctl enable --now kubelet

# Exact version installed, e.g. v1.37.2.
KUBE_VERSION="$(kubeadm version -o short)"

# --------------------------------------------------------------------------
log "Adding $VIP_HOSTNAME to /etc/hosts"
# --------------------------------------------------------------------------

sed -i "/[[:space:]]${VIP_HOSTNAME//./\\.}\([[:space:]]\|$\)/d" /etc/hosts
echo "$VIP  $VIP_HOSTNAME" >> /etc/hosts

if [[ "$NODE_TYPE" == control-plane ]]; then

    # ----------------------------------------------------------------------
    log "Installing Helm"
    # ----------------------------------------------------------------------

    if [[ "$OS_FAMILY" == debian ]]; then
        curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
            | gpg --dearmor --yes -o /etc/apt/keyrings/helm.gpg

        echo "deb [signed-by=/etc/apt/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" > /etc/apt/sources.list.d/helm-stable-debian.list

        apt-get update
        apt-get install -y helm
    else
        # No official rpm repository for RHEL-like systems: the official
        # install script (Helm 3, as on Debian) puts it in /usr/local/bin.
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
            | HELM_INSTALL_DIR=/usr/local/bin USE_SUDO=false bash
    fi

    # ----------------------------------------------------------------------
    log "Generating the kube-vip manifest"
    # ----------------------------------------------------------------------

    if [[ -z "$KUBE_VIP_VERSION" ]]; then
        KUBE_VIP_VERSION="$(latest_github_release kube-vip/kube-vip)" \
            || die "could not fetch the latest kube-vip version; pass it with -K."
        echo "No version given; using the latest: $KUBE_VIP_VERSION"
    fi
    KUBE_VIP_IMAGE="ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}"

    mkdir -p /etc/kubernetes/manifests
    pull_image "$KUBE_VIP_IMAGE"
    ctr -n k8s.io run --rm --net-host "$KUBE_VIP_IMAGE" vip /kube-vip \
        manifest pod --interface "$INTERFACE" --address "$VIP" --controlplane --arp --leaderElection \
        > /etc/kubernetes/manifests/kube-vip.yaml

    # On the first node admin.conf only gets permissions after 'kubeadm init',
    # so kube-vip starts with super-admin.conf and switches back afterwards.
    if [[ "$MODE" == init ]]; then
        sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/super-admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml
    fi

    # ----------------------------------------------------------------------
    log "Pulling the control plane images ($KUBE_VERSION)"
    # ----------------------------------------------------------------------

    # kubeadm pulls them silently in its preflight; pulling them here shows the
    # progress, and kubeadm then finds them already in place.
    for image in $(kubeadm config images list --kubernetes-version "$KUBE_VERSION"); do
        pull_image "$image"
    done
fi

if [[ "$MODE" == init ]]; then

    # ----------------------------------------------------------------------
    log "Initializing the cluster ($KUBE_VERSION)"
    # ----------------------------------------------------------------------

    kubeadm init \
        --kubernetes-version "$KUBE_VERSION" \
        --control-plane-endpoint "${VIP_HOSTNAME}:6443" \
        --upload-certs \
        --pod-network-cidr "$POD_CIDR" \
        --service-cidr "$SERVICE_CIDR"

    sed -i 's#path: /etc/kubernetes/super-admin.conf#path: /etc/kubernetes/admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml
    systemctl restart kubelet

    setup_kubeconfig
    export KUBECONFIG=/etc/kubernetes/admin.conf

    wait_until 300 kubectl get --raw /readyz \
        || die "the API server did not come back through $VIP_HOSTNAME after restarting kube-vip."

    # ----------------------------------------------------------------------
    log "Installing Calico"
    # ----------------------------------------------------------------------

    if [[ -z "$CALICO_VERSION" ]]; then
        CALICO_VERSION="$(latest_github_release projectcalico/calico)" \
            || die "could not fetch the latest Calico version; pass it with --calico-version."
        echo "No version given; using the latest: $CALICO_VERSION"
    fi

    helm repo add projectcalico https://docs.tigera.io/calico/charts --force-update
    helm repo update projectcalico

    kubectl create namespace tigera-operator

    helm template calico-crds projectcalico/crd.projectcalico.org.v1 --version "$CALICO_VERSION" \
        | kubectl apply --server-side -f -

    # Calico's default (firstFound) may pick any interface on nodes with more
    # than one NIC, sending VXLAN over the wrong network and breaking pod
    # traffic between nodes. Use the address Kubernetes registered instead.
    cat <<EOF > /etc/kubernetes/calico-values.yaml
installation:
  cni:
    type: Calico
  calicoNetwork:
    nodeAddressAutodetectionV4:
      kubernetes: NodeInternalIP
    ipPools:
      - cidr: ${POD_CIDR}
        encapsulation: VXLAN
        natOutgoing: Enabled
EOF

    helm install calico projectcalico/tigera-operator --version "$CALICO_VERSION" \
        --namespace tigera-operator -f /etc/kubernetes/calico-values.yaml

    echo "Waiting for Calico to become available..."
    wait_until 600 kubectl get tigerastatus/calico || die "Calico was not deployed."
    kubectl wait --for=condition=Available tigerastatus/calico --timeout=600s

    if [[ "$WINDOWS_SUPPORT" == true ]]; then

        # ------------------------------------------------------------------
        log "Preparing the cluster for Windows nodes"
        # ------------------------------------------------------------------

        echo "Waiting for the Calico API server..."
        wait_until 600 kubectl get tigerastatus/apiserver || die "the Calico API server was not deployed."
        kubectl wait --for=condition=Available tigerastatus/apiserver --timeout=600s
        wait_until 300 kubectl get ipamconfigurations default \
            || die "the Calico IPAM configuration was not created."

        kubectl patch ipamconfigurations default --type merge --patch='{"spec": {"strictAffinity": true}}'

        kubectl patch installation default --type=merge -p '{"spec": {"calicoNetwork": {"bgp": "Disabled"}}}'

        kubectl apply -f - <<EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: kubernetes-services-endpoint
  namespace: tigera-operator
data:
  KUBERNETES_SERVICE_HOST: "${VIP_HOSTNAME}"
  KUBERNETES_SERVICE_PORT: "6443"
EOF

        kubectl patch installation default --type merge --patch "{\"spec\": {\"serviceCIDRs\": [\"${SERVICE_CIDR}\"], \"calicoNetwork\": {\"windowsDataplane\": \"HNS\"}}}"

        curl -fsSL https://raw.githubusercontent.com/kubernetes-sigs/sig-windows-tools/master/hostprocess/calico/kube-proxy/kube-proxy.yml \
            | sed "s/KUBE_PROXY_VERSION/${KUBE_VERSION}/g" | kubectl apply -f -
    fi

    if [[ "$METRICS_SERVER" == true ]]; then

        # ------------------------------------------------------------------
        log "Installing metrics-server"
        # ------------------------------------------------------------------

        if [[ -z "$METRICS_SERVER_VERSION" ]]; then
            METRICS_SERVER_VERSION="$(latest_github_release kubernetes-sigs/metrics-server)" \
                || die "could not fetch the latest metrics-server version; pass it with --metrics-server-version."
            echo "No version given; using the latest: $METRICS_SERVER_VERSION"
        fi

        kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

        # The kubelet serving certificates are self-signed.
        kubectl -n kube-system patch deployment metrics-server --type=json \
            -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

        # metrics-server does not tolerate the control plane taint, so it only
        # starts once a Linux worker joins; no point waiting for it here.
        echo "metrics-server starts when the first Linux worker joins."
    fi

    kubectl get nodes -o wide

else

    # ----------------------------------------------------------------------
    log "Joining the cluster as $NODE_TYPE"
    # ----------------------------------------------------------------------

    join_args=(--token "$TOKEN" --discovery-token-ca-cert-hash "$CA_CERT_HASH")
    if [[ "$NODE_TYPE" == control-plane ]]; then
        join_args+=(--control-plane --certificate-key "$CERTIFICATE_KEY")
    fi

    kubeadm join "${VIP_HOSTNAME}:6443" "${join_args[@]}"

    if [[ "$NODE_TYPE" == control-plane ]]; then
        setup_kubeconfig

        # ------------------------------------------------------------------
        log "Spreading the system pods across the nodes"
        # ------------------------------------------------------------------

        rebalance_system_pods

        kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
    fi
fi

# --------------------------------------------------------------------------
log "Done"
# --------------------------------------------------------------------------

echo "containerd: $(containerd --version)"
echo "kubernetes: $KUBE_VERSION"
if [[ "$NODE_TYPE" == control-plane ]]; then
    echo "helm:       $(helm version --short)"
    echo "kube-vip:   $KUBE_VIP_VERSION ($VIP on $INTERFACE, $VIP_HOSTNAME)"
fi
[[ "$MODE" == init ]] && echo "calico:     $CALICO_VERSION"
[[ "$MODE" == init && "$METRICS_SERVER" == true ]] && echo "metrics:    $METRICS_SERVER_VERSION"

if [[ "$MODE" == init ]]; then
    echo
    print_join_info
fi

}

main "$@"
