# k8s-setup

[English](README.md) | **Português (Brasil)**

Scripts que montam um cluster Kubernetes **misto Linux + Windows** em alta disponibilidade com kubeadm, das máquinas zeradas até o cluster funcionando:

| Script | Roda em | Papel |
|---|---|---|
| [`k8s-setup.sh`](k8s-setup.sh) | Debian 13 ou CentOS Stream 10 | Primeiro control plane, control planes adicionais e workers Linux |
| [`k8s-setup.ps1`](k8s-setup.ps1) | Windows Server 2022 / 2025 | Workers Windows |

## O que você ganha

- **Control plane em alta disponibilidade**: três (ou mais) control planes atrás de um IP virtual gerenciado pelo [kube-vip](https://kube-vip.io) (ARP, eleição de líder).
- **Rede**: [Calico](https://docs.tigera.io/calico) com VXLAN, BGP desligado, pronto para nós Windows (dataplane HNS, kube-proxy do Windows como contêiner HostProcess).
- **Métricas**: [metrics-server](https://github.com/kubernetes-sigs/metrics-server), para o `kubectl top` e o HorizontalPodAutoscaler funcionarem.
- **Runtime**: containerd do repositório da Docker (Linux) e da versão oficial (Windows).
- **Ferramentas**: kubectl e Helm em todos os control planes.

```
                    VIP 192.168.1.70 (k8s-endpoint:6443, kube-vip)
                 ┌──────────────┬──────────────┬──────────────┐
                 │  cp-1        │  cp-2        │  cp-3        │   Control planes Linux
                 │  (init)      │  (join)      │  (join)      │   etcd + API + kube-vip
                 └──────────────┴──────────────┴──────────────┘
                        │ Calico VXLAN │
          ┌─────────────┴──────────────┴──────────────┐
          │  Workers Linux           Workers Windows  │
          └───────────────────────────────────────────┘
```

## Requisitos

**Todos os nós**
- IPs fixos na mesma rede e um IP livre para o VIP.
- Acesso à internet (repositórios de pacotes, GitHub, registries).
- Execução como root/Administrador.

**Nós Linux**: Debian 13 ou CentOS Stream 10 (outras distribuições derivadas do Debian ou do RHEL rodam com aviso).

**Nós Windows**: Windows Server 2022 ou 2025 (o Kubernetes só suporta isolamento de processo).

**Dimensionamento (mínimo para produção)**

| Papel | vCPU | RAM | Disco |
|---|---|---|---|
| Control plane (×3, em hosts físicos diferentes) | 4 | 8 GB, memória **fixa** | 50–100 GB SSD |
| Worker Linux | 4+ | 8–16 GB | 50–100 GB |
| Worker Windows | 4+ | 8–16 GB | 100+ GB |

> O kubeadm recusa control planes com menos de 1700 MB de memória total. O CentOS reserva de 192 a 256 MB para o kdump, e a memória dinâmica do Hyper-V pode entregar menos que o máximo à VM. Prefira memória fixa nos control planes.

## Início rápido

Os scripts rodam direto do GitHub, sem copiar nada para os servidores. O script Linux é passado para o `bash` por pipe (como o `get.docker.com`); o do Windows é baixado e executado numa linha só.

### 1. Primeiro control plane

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | sudo bash -s -- -f -k 1.37 -a 192.168.1.70 -n k8s-endpoint -i eth0
```

Prepara o nó, roda o `kubeadm init`, instala o Calico (com suporte a Windows) e o metrics-server e mostra **comandos prontos para colar** nos outros nós. Eles também ficam salvos em `/root/k8s-join.txt`.

### 2. Control planes adicionais

Cole em cada nó o comando mostrado no passo 1. Ele tem esta forma:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | sudo bash -s -- \
    -t control-plane -m join -i eth0 -k 1.37.2 -a 192.168.1.70 -n k8s-endpoint \
    --token abcdef.0123456789abcdef --ca-cert-hash sha256:<hash> --certificate-key <chave>
```

### 3. Workers Linux

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | sudo bash -s -- \
    -t worker -k 1.37.2 -a 192.168.1.70 -n k8s-endpoint \
    --token abcdef.0123456789abcdef --ca-cert-hash sha256:<hash>
```

### 4. Workers Windows

No PowerShell **como Administrador**, cole a linha mostrada no passo 1:

```powershell
irm https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.ps1 -OutFile k8s-setup.ps1; powershell -ExecutionPolicy Bypass -File .\k8s-setup.ps1 -KubernetesVersion v1.37.2 -ContainerdVersion 2.4.2 -Vip 192.168.1.70 -VipHostname k8s-endpoint -Token abcdef.0123456789abcdef -CaCertHash sha256:<hash>
```

Se os recursos do Windows exigirem reinicialização, o script reinicia a máquina e **continua sozinho quando o mesmo usuário fizer logon de novo**. Por isso ele roda a partir de um arquivo baixado: `irm ... | iex` é recusado, porque não haveria o que retomar.

### 5. Novos comandos de join depois

O token expira em 24 horas e a chave de certificado em 2 horas. Para gerar comandos novos, em qualquer control plane:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | sudo bash -s -- --print-join
```

### 6. Verificação

```bash
kubectl get nodes -o wide
kubectl top nodes        # depois que o primeiro worker Linux entrar
```

Qualquer valor que o nó precise e que não tenha sido informado (tipo de nó, modo, VIP, token…) é **perguntado interativamente**, mesmo com o script vindo do `curl` por pipe.

## Executando a partir de uma cópia local

Clone o repositório (ou baixe os arquivos) para conferir ou alterar os scripts antes de rodar:

```bash
git clone https://github.com/arabasso/k8s-setup.git && cd k8s-setup
sudo ./k8s-setup.sh -f -k 1.37 -a 192.168.1.70 -n k8s-endpoint -i eth0
```

As opções são as mesmas. O script detecta como foi iniciado e mostra os comandos para os outros nós da mesma forma: `sudo ./k8s-setup.sh ...` a partir de um arquivo, `curl ... | sudo bash -s -- ...` quando veio por pipe. O comando do Windows é sempre a linha de download.

## Fixando uma versão dos scripts

A `master` sempre tem os scripts mais recentes. Em produção, use uma tag na URL, para que todos os nós rodem o mesmo código:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/v1.0.0/k8s-setup.sh | sudo bash -s -- ...
```

Os comandos gerados para os outros nós usam a constante `K8S_SETUP_REF` no início do `k8s-setup.sh` (`master` por padrão). Defina-a com a tag no commit da tag, ou informe-a na execução:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/v1.0.0/k8s-setup.sh | sudo K8S_SETUP_REF=v1.0.0 bash -s -- ...
```

`K8S_SETUP_URL` substitui a URL base inteira (um fork ou um espelho interno).

## O que cada nó faz

| Etapa | Primeiro control plane (`init`) | Control plane adicional (`join`) | Worker Linux |
|---|:---:|:---:|:---:|
| Desliga o swap (mascara o `swap.target`) | ✔ | ✔ | ✔ |
| Módulos do kernel e sysctl | ✔ | ✔ | ✔ |
| SELinux permissive, firewalld desligado, NetworkManager ignorando as interfaces do Calico | ✔ | ✔ | ✔ |
| containerd | ✔ | ✔ | ✔ |
| kubelet, kubeadm (travados na versão escolhida) | ✔ | ✔ | ✔ |
| kubectl, Helm, kube-vip | ✔ | ✔ | — |
| Hostname do VIP no `/etc/hosts` | ✔ | ✔ | ✔ |
| `kubeadm init`, Calico, suporte a Windows, metrics-server | ✔ | — | — |
| `kubeadm join` | — | ✔ | ✔ |
| Reinicia os Deployments do CoreDNS/Calico para tirar os pods do primeiro nó | — | ✔ | — |

**Worker Windows** (`k8s-setup.ps1`):
1. Ativa os recursos Containers e Hyper-V (sem o hypervisor), reinicia e continua pela tarefa agendada `k8s-setup-resume`.
2. Adiciona o hostname do VIP ao arquivo `hosts`.
3. Roda os scripts oficiais [`Install-Containerd.ps1`](https://github.com/kubernetes-sigs/sig-windows-tools/blob/master/hostprocess/Install-Containerd.ps1) e [`PrepareNode.ps1`](https://github.com/kubernetes-sigs/sig-windows-tools/blob/master/hostprocess/PrepareNode.ps1) do sig-windows-tools.
4. Roda o `kubeadm join`.

Log: `C:\ProgramData\k8s-setup\k8s-setup.log`.

## Opções

### `k8s-setup.sh`

| Opção | Descrição | Padrão |
|---|---|---|
| `-t, --node-type` | `control-plane` ou `worker` | pergunta |
| `-m, --mode` | `init` (cria o cluster) ou `join` | pergunta (workers: `join`) |
| `-f, --first-control-plane` | O mesmo que `-t control-plane -m init` | |
| `-k, --k8s-version` | Versão do Kubernetes (`1.37` ou `1.37.2`) | última estável |
| `-c, --containerd-version` | Versão do containerd.io | última do repositório |
| `-K, --kube-vip-version` | Versão do kube-vip | última |
| `--calico-version` | Versão do Calico | última |
| `--metrics-server-version` | Versão do metrics-server | última |
| `-a, --vip` | IP virtual do control plane | pergunta |
| `-n, --vip-hostname` | Hostname do VIP | pergunta (`k8s-endpoint`) |
| `-i, --interface` | Interface do VIP (control planes) | pergunta (rota padrão) |
| `--pod-cidr` | Rede dos pods (init) | `10.244.0.0/16` |
| `--service-cidr` | Rede dos serviços (init) | `10.96.0.0/12` |
| `--no-windows` | Pula a configuração para Windows (init) | |
| `--no-metrics-server` | Pula o metrics-server (init) | |
| `--token` | Token de bootstrap (join) | pergunta |
| `--ca-cert-hash` | Hash do certificado da CA (join) | pergunta |
| `--certificate-key` | Chave de certificado (join de control plane) | pergunta |
| `--print-join` | Mostra comandos de join novos e sai | |

Todas as opções também podem ser definidas como variável de ambiente (`K8S_VERSION`, `VIP`, `TOKEN`, …). Veja a ajuda completa com:

```bash
curl -fsSL https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.sh | bash -s -- --help
```

### `k8s-setup.ps1`

| Parâmetro | Descrição | Padrão |
|---|---|---|
| `-KubernetesVersion` | A mesma versão do cluster (`v1.37.2`) | pergunta (última estável) |
| `-ContainerdVersion` | Versão do containerd | última versão |
| `-CrictlVersion` | Versão do crictl | `<versão do Kubernetes>.0` |
| `-Vip` | IP virtual do control plane | pergunta |
| `-VipHostname` | Hostname do VIP | pergunta (`k8s-endpoint`) |
| `-Token` | Token de bootstrap | pergunta |
| `-CaCertHash` | Hash do certificado da CA | pergunta |
| `-NoRestart` | Não reinicia automaticamente | |

Depois de baixar o script, veja `Get-Help .\k8s-setup.ps1 -Detailed`.

## Recomendações

- **Fixe as versões** em produção (`-k`, `--calico-version`, `-K`, `-c`). Sem elas, cada execução usa a versão mais recente, e nós adicionados depois podem ficar diferentes.
- **Use a mesma versão do Kubernetes em todos os nós.** Os comandos gerados pelo `--print-join` já incluem a versão.
- **Direcione explicitamente as cargas Windows e Linux** com `nodeSelector: kubernetes.io/os: windows|linux`; considere aplicar um taint nos nós Windows.
- **Defina `requests` e `limits`** em todos os pods, para o agendador e o HorizontalPodAutoscaler funcionarem.
- **Faça backup do etcd e do `/etc/kubernetes/pki`** regularmente (`etcdctl snapshot save`).

## Removendo um nó

Num control plane:

```bash
kubectl drain <nó> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <nó>
```

Num nó **Linux**:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/calico
sudo reboot
```

Num nó **Windows** (PowerShell como Administrador):

```powershell
C:\k\kubeadm.exe reset -f
Stop-Service kubelet; nssm remove kubelet confirm
Remove-Item -Recurse -Force C:\etc\kubernetes, C:\var\lib\kubelet, C:\etc\cni, C:\opt\cni, C:\k -ErrorAction SilentlyContinue
Restart-Computer
```

## Solução de problemas

| Sintoma | Causa provável |
|---|---|
| `the system RAM (…) is less than the minimum 1700 MB` | Pouca memória no control plane (reserva do kdump, memória dinâmica do Hyper-V). |
| `http2: client connection lost` esperando o Calico | Control plane com pouca memória: o etcd ou o servidor de API reiniciou, ou o kube-vip perdeu o VIP. Dê 4 GB ou mais de memória fixa, depois `kubeadm reset -f` e rode de novo. |
| O swap volta depois de reiniciar | Corrigido: o script mascara o `swap.target` (cobre o systemd-gpt-auto-generator). |
| A instalação do Helm falha no CentOS (`openssl must first be installed`) | Corrigido: o script instala o `openssl`. |
| Nó Windows fica `NotReady` | Espere alguns minutos pelas imagens do Calico e do kube-proxy; confira `kubectl -n calico-system get pods -o wide`. |
| O join falha com token expirado | Rode o script com `--print-join` num control plane. |
| `Run k8s-setup.ps1 from a file` no Windows | O script foi passado para o `iex`; use a linha de download do início rápido. |
