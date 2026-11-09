# k8s-setup

**English** | [Português (Brasil)](README.pt-BR.md)

Scripts that build a highly available, mixed **Linux + Windows** Kubernetes cluster with kubeadm, from bare machines to a working cluster:

| Script | Runs on | Role |
|---|---|---|
| [`k8s-setup.sh`](k8s-setup.sh) | Debian 13 or CentOS Stream 10 | First control plane, additional control planes and Linux workers |
| [`k8s-setup.ps1`](k8s-setup.ps1) | Windows Server 2022 / 2025 | Windows workers |

## What you get

- **Control plane HA**: three (or more) control planes behind a virtual IP managed by [kube-vip](https://kube-vip.io) (ARP, leader election).
- **Networking**: [Calico](https://docs.tigera.io/calico) with VXLAN, BGP disabled, ready for Windows nodes (HNS data plane, Windows kube-proxy as a HostProcess container).
- **Metrics**: [metrics-server](https://github.com/kubernetes-sigs/metrics-server), so `kubectl top` and the HorizontalPodAutoscaler work.
- **Runtime**: containerd from the Docker repository (Linux) and from the official release (Windows).
- **Tools**: kubectl and Helm on every control plane.

```
                    VIP 192.168.1.70 (k8s-endpoint:6443, kube-vip)
                 ┌──────────────┬──────────────┬──────────────┐
                 │  cp-1        │  cp-2        │  cp-3        │   Linux control planes
                 │  (init)      │  (join)      │  (join)      │   etcd + API + kube-vip
                 └──────────────┴──────────────┴──────────────┘
                        │ Calico VXLAN │
          ┌─────────────┴──────────────┴──────────────┐
          │  Linux workers           Windows workers  │
          └───────────────────────────────────────────┘
```

## Requirements

**All nodes**
- Static IP addresses on the same network; a free IP for the VIP.
- Internet access (package repositories, GitHub, registries).
- Run as root/Administrator.

**Linux nodes**: Debian 13 or CentOS Stream 10 (other Debian-like and RHEL-like distributions run with a warning).

**Windows nodes**: Windows Server 2022 or 2025 (only process isolation is supported by Kubernetes).

**Sizing (minimum for production)**

| Role | vCPU | RAM | Disk |
|---|---|---|---|
| Control plane (×3, on different physical hosts) | 4 | 8 GB, **fixed** memory | 50–100 GB SSD |
| Linux worker | 4+ | 8–16 GB | 50–100 GB |
| Windows worker | 4+ | 8–16 GB | 100+ GB |

> kubeadm refuses control planes with less than 1700 MB of total memory. CentOS reserves 192–256 MB for kdump, and Hyper-V dynamic memory may give the VM less than its maximum, so prefer fixed memory on control planes.

## Quick start

The scripts run straight from GitHub, nothing to copy to the servers. The Linux script is piped to `bash` (like `get.docker.com`); the Windows one is downloaded and run in a single line.

### 1. First control plane

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | sudo bash -s -- -f -k 1.37 -a 192.168.1.70 -n k8s-endpoint -i eth0
```

This prepares the node, runs `kubeadm init`, installs Calico (with Windows support) and metrics-server, and prints **ready-to-paste commands** for the other nodes. They are also saved to `/root/k8s-join.txt`.

### 2. Additional control planes

Paste the command printed by step 1 on each node. It looks like:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | sudo bash -s -- \
    -t control-plane -m join -i eth0 -k 1.37.2 -a 192.168.1.70 -n k8s-endpoint \
    --token abcdef.0123456789abcdef --ca-cert-hash sha256:<hash> --certificate-key <key>
```

### 3. Linux workers

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | sudo bash -s -- \
    -t worker -k 1.37.2 -a 192.168.1.70 -n k8s-endpoint \
    --token abcdef.0123456789abcdef --ca-cert-hash sha256:<hash>
```

### 4. Windows workers

In PowerShell **as Administrator**, paste the line printed by step 1:

```powershell
irm https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.ps1 -OutFile k8s-setup.ps1; powershell -ExecutionPolicy Bypass -File .\k8s-setup.ps1 -KubernetesVersion v1.37.2 -ContainerdVersion 2.4.2 -Vip 192.168.1.70 -VipHostname k8s-endpoint -Token abcdef.0123456789abcdef -CaCertHash sha256:<hash>
```

If the Windows features need a reboot, the script restarts the machine and **resumes automatically when the same user logs on again**. That is why it runs from a downloaded file: `irm ... | iex` is refused, as there would be nothing to resume from.

### 5. New join commands later

The token expires in 24 hours and the certificate key in 2 hours. To print fresh commands, on any control plane:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | sudo bash -s -- --print-join
```

### 6. Check

```bash
kubectl get nodes -o wide
kubectl top nodes        # after the first Linux worker joins
```

Any value a node needs and that was not given (node type, mode, VIP, token…) is **asked interactively**, even when the script is piped from `curl`.

## Running from a local copy

Clone the repository (or download the files) to inspect or change the scripts before running them:

```bash
git clone https://github.com/arabasso/k8s-setup.git && cd k8s-setup
sudo ./k8s-setup.sh -f -k 1.37 -a 192.168.1.70 -n k8s-endpoint -i eth0
```

The options are the same. The script detects how it was started and prints the commands for the other nodes the same way: `sudo ./k8s-setup.sh ...` from a file, `curl ... | sudo bash -s -- ...` when piped. The Windows command is always the download line.

## Pinning a version of the scripts

`master` always has the latest scripts. For production, use a tag in the URL, so every node runs the same code:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/v1.0.0/k8s-setup.sh | sudo bash -s -- ...
```

The commands printed for other nodes use the `K8S_SETUP_REF` constant at the top of `k8s-setup.sh` (`master` by default). Set it to the tag in the tagged commit, or override it when running:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/v1.0.0/k8s-setup.sh | sudo K8S_SETUP_REF=v1.0.0 bash -s -- ...
```

`K8S_SETUP_URL` replaces the whole base URL (a fork or an internal mirror).

## What each node does

| Step | First control plane (`init`) | Additional control plane (`join`) | Linux worker |
|---|:---:|:---:|:---:|
| Disable swap (masks `swap.target`) | ✔ | ✔ | ✔ |
| Kernel modules and sysctl | ✔ | ✔ | ✔ |
| SELinux permissive, firewalld off, NetworkManager ignores Calico interfaces | ✔ | ✔ | ✔ |
| containerd | ✔ | ✔ | ✔ |
| kubelet, kubeadm (held at the chosen version) | ✔ | ✔ | ✔ |
| kubectl, Helm, kube-vip | ✔ | ✔ | — |
| VIP hostname in `/etc/hosts` | ✔ | ✔ | ✔ |
| `kubeadm init`, Calico, Windows support, metrics-server | ✔ | — | — |
| `kubeadm join` | — | ✔ | ✔ |
| Restart CoreDNS/Calico Deployments to spread their pods off the first node | — | ✔ | — |

**Windows worker** (`k8s-setup.ps1`):
1. Enables the Containers and Hyper-V features (without the hypervisor), then reboots and resumes through the `k8s-setup-resume` scheduled task.
2. Adds the VIP hostname to the `hosts` file.
3. Runs the official [`Install-Containerd.ps1`](https://github.com/kubernetes-sigs/sig-windows-tools/blob/master/hostprocess/Install-Containerd.ps1) and [`PrepareNode.ps1`](https://github.com/kubernetes-sigs/sig-windows-tools/blob/master/hostprocess/PrepareNode.ps1) from sig-windows-tools.
4. Runs `kubeadm join` with the kubelet's `--node-ip` pinned (`-NodeIp`, or the address of the interface that reaches the VIP), so the node and Calico's VXLAN use the right network on nodes with more than one NIC, and with the `os=windows:NoSchedule` taint, which keeps Linux workloads off the node (Windows workloads need the matching toleration).

Log: `C:\ProgramData\k8s-setup\k8s-setup.log`.

## Options

### `k8s-setup.sh`

| Option | Description | Default |
|---|---|---|
| `-t, --node-type` | `control-plane` or `worker` | asked |
| `-m, --mode` | `init` (creates the cluster) or `join` | asked (workers: `join`) |
| `-f, --first-control-plane` | Same as `-t control-plane -m init` | |
| `-k, --k8s-version` | Kubernetes version (`1.37` or `1.37.2`) | latest stable |
| `-c, --containerd-version` | containerd.io version | latest in the repository |
| `-K, --kube-vip-version` | kube-vip version | latest |
| `--calico-version` | Calico version | latest |
| `--metrics-server-version` | metrics-server version | latest |
| `-a, --vip` | Control plane virtual IP | asked |
| `-n, --vip-hostname` | Hostname for the VIP | asked (`k8s-endpoint`) |
| `-i, --interface` | Interface for the VIP (control planes) | asked (default route) |
| `--pod-cidr` | Pod network (init) | `10.244.0.0/16` |
| `--service-cidr` | Service network (init) | `10.96.0.0/12` |
| `--no-windows` | Skip the Windows setup (init) | |
| `--no-metrics-server` | Skip metrics-server (init) | |
| `--token` | Bootstrap token (join) | asked |
| `--ca-cert-hash` | CA certificate hash (join) | asked |
| `--certificate-key` | Certificate key (control plane join) | asked |
| `--print-join` | Print fresh join commands and exit | |

Every option can also be set as an environment variable (`K8S_VERSION`, `VIP`, `TOKEN`, …). See the full help with:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | bash -s -- --help
```

### `k8s-setup.ps1`

| Parameter | Description | Default |
|---|---|---|
| `-KubernetesVersion` | Same version as the cluster (`v1.37.2`) | asked (latest stable) |
| `-ContainerdVersion` | containerd version | latest release |
| `-CrictlVersion` | crictl version | `<Kubernetes minor>.0` |
| `-Vip` | Control plane virtual IP | asked |
| `-VipHostname` | Hostname for the VIP | asked (`k8s-endpoint`) |
| `-Token` | Bootstrap token | asked |
| `-CaCertHash` | CA certificate hash | asked |
| `-NodeIp` | IP the node registers in the cluster (use on nodes with more than one NIC) | address of the interface that reaches the VIP |
| `-NoRestart` | Do not reboot automatically | |

After downloading the script, see `Get-Help .\k8s-setup.ps1 -Detailed`.

## Recommendations

- **Pin versions** in production (`-k`, `--calico-version`, `-K`, `-c`). Without them each run uses the latest release, and nodes added later may differ.
- **Use the same Kubernetes version on every node.** The commands printed by `--print-join` already include it.
- **Schedule Windows and Linux workloads explicitly** with `nodeSelector: kubernetes.io/os: windows|linux`; consider tainting Windows nodes.
- **Set `requests` and `limits`** on every pod, so the scheduler and the HorizontalPodAutoscaler can work.
- **Back up etcd and `/etc/kubernetes/pki`** regularly (`etcdctl snapshot save`).

## Removing a node

On a control plane:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>
```

On a **Linux** node:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/calico
sudo reboot
```

On a **Windows** node (PowerShell as Administrator):

```powershell
C:\k\kubeadm.exe reset -f
Stop-Service kubelet; nssm remove kubelet confirm
Remove-Item -Recurse -Force C:\etc\kubernetes, C:\var\lib\kubelet, C:\etc\cni, C:\opt\cni, C:\k -ErrorAction SilentlyContinue
Restart-Computer
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `the system RAM (…) is less than the minimum 1700 MB` | Not enough memory on a control plane (kdump reservation, Hyper-V dynamic memory). |
| `http2: client connection lost` while waiting for Calico | Control plane short on memory: etcd/API server restarted or kube-vip lost the VIP. Give it 4 GB+ of fixed memory, then `kubeadm reset -f` and run again. |
| Swap comes back after a reboot | Fixed: the script masks `swap.target` (covers systemd-gpt-auto-generator). |
| Helm install fails on CentOS (`openssl must first be installed`) | Fixed: the script installs `openssl`. |
| Windows node stays `NotReady` | Wait a few minutes for the Calico and kube-proxy images; check `kubectl -n calico-system get pods -o wide`. |
| Join fails with an expired token | Run the script with `--print-join` on a control plane. |
| `Run k8s-setup.ps1 from a file` on Windows | The script was piped to `iex`; use the download line from the quick start. |
