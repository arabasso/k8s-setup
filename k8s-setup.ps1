<#
.SYNOPSIS
Prepares a Windows Server node and joins it to the Kubernetes cluster as a worker.

.DESCRIPTION
Phase 1 enables the Windows features containers need (Containers, and
Microsoft-Hyper-V without the hypervisor, as Install-Containerd.ps1 does with
-skipHypervisorSupportCheck). When that requires a reboot, the script registers
a logon task that runs it again with the same parameters and restarts the
machine.

Phase 2 (right away when no reboot is needed, or after the reboot):
- adds the VIP hostname to the hosts file
- runs Install-Containerd.ps1 and PrepareNode.ps1 from sig-windows-tools
- runs 'kubeadm join'

Every value not given as a parameter is asked before anything is installed.
On a Linux control plane, 'k8s-setup.sh --print-join' prints the command for
this node with every parameter filled in.

The script must run from a file (it copies itself to resume after the
reboot), so download it first instead of piping it to Invoke-Expression:

  irm https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.ps1 -OutFile k8s-setup.ps1
  powershell -ExecutionPolicy Bypass -File .\k8s-setup.ps1 [parameters]

.PARAMETER KubernetesVersion
Kubernetes version, the same as the cluster's (e.g. v1.37.2).
Default: latest stable (dl.k8s.io/release/stable.txt).

.PARAMETER ContainerdVersion
containerd version (e.g. 2.1.4). Default: latest release on GitHub.

.PARAMETER CrictlVersion
crictl version (e.g. 1.37.0). Default: <Kubernetes minor>.0.

.PARAMETER Vip
Control plane virtual IP (e.g. 192.168.1.70).

.PARAMETER VipHostname
Hostname for the VIP (e.g. k8s-endpoint).

.PARAMETER Token
Bootstrap token (abcdef.0123456789abcdef).

.PARAMETER CaCertHash
CA certificate hash (sha256:...).

.PARAMETER NodeIp
IP this node registers in the cluster, which Calico also uses for VXLAN.
Default: the address of the interface that reaches the VIP. Set it on nodes
with more than one NIC when that is not the cluster network.

.PARAMETER NoRestart
Do not restart automatically when the features need it; the script still
resumes at the next logon.

.EXAMPLE
PS> irm https://raw.githubusercontent.com/arabasso/k8s-setup/master/k8s-setup.ps1 -OutFile k8s-setup.ps1; powershell -ExecutionPolicy Bypass -File .\k8s-setup.ps1 -KubernetesVersion v1.37.2 -ContainerdVersion 2.4.2 -Vip 192.168.1.70 -VipHostname k8s-endpoint -Token abcdef.0123456789abcdef -CaCertHash sha256:<hash>

.EXAMPLE
PS> .\k8s-setup.ps1
Asks for every value.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string] $KubernetesVersion,
    [string] $ContainerdVersion,
    [string] $CrictlVersion,
    [string] $Vip,
    [string] $VipHostname,
    [string] $Token,
    [string] $CaCertHash,
    [string] $NodeIp,
    [switch] $NoRestart,
    # Set by the logon task that resumes the script after the reboot.
    [switch] $Resume
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Same layout as k8s-setup.sh: use a tag (e.g. v1.0.0) in released versions.
$K8sSetupUrl = "https://raw.githubusercontent.com/arabasso/k8s-setup/master"

# Run through Invoke-Expression or a script block there is no file to resume from.
if (-not $PSCommandPath) {
    throw "Run k8s-setup.ps1 from a file, so it can resume after the reboot:`n" +
        "  irm $K8sSetupUrl/k8s-setup.ps1 -OutFile k8s-setup.ps1; powershell -ExecutionPolicy Bypass -File .\k8s-setup.ps1 [parameters]"
}

$StateDir = "$env:ProgramData\k8s-setup"
$ScriptCopy = "$StateDir\k8s-setup.ps1"
$ResumeTask = "k8s-setup-resume"
$SigWindowsTools = "https://raw.githubusercontent.com/kubernetes-sigs/sig-windows-tools/master/hostprocess"
$CniBinPath = "c:/opt/cni/bin"
$CniConfigPath = "c:/etc/cni/net.d"

function Write-Step($Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }

function Test-Ipv4($Value) {
    $ip = $null
    ($Value -match '^\d{1,3}(\.\d{1,3}){3}$') -and [ipaddress]::TryParse($Value, [ref]$ip)
}
function Test-Hostname($Value)    { $Value -match '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' }
function Test-Version($Value)     { $Value -match '^v?\d+\.\d+\.\d+$' }
function Test-Token($Value)       { $Value -cmatch '^[a-z0-9]{6}\.[a-z0-9]{16}$' }
function Test-CaCertHash($Value)  { $Value -cmatch '^(sha256:)?[a-f0-9]{64}$' }

# Validates the value when given, asks for it otherwise.
function Resolve-Value($Name, $Value, $Prompt, $Test, $Default) {
    if ($Value) {
        if (-not (& $Test $Value)) { throw "Invalid value for -${Name}: $Value" }
        return $Value
    }
    if ($Resume) { throw "-$Name is missing when resuming." }
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { "" }
        $answer = Read-Host "$Prompt$suffix"
        if (-not $answer) { $answer = $Default }
        if ($answer -and (& $Test $answer)) { return $answer }
        Write-Host "Invalid value: '$answer'" -ForegroundColor Yellow
    }
}

function Get-LatestGitHubRelease($Repository) {
    (Invoke-RestMethod "https://api.github.com/repos/$Repository/releases/latest" -UseBasicParsing).tag_name
}

function Save-File($Url, $Destination) {
    Write-Host "Downloading $Url"
    Invoke-WebRequest $Url -OutFile $Destination -UseBasicParsing
}

New-Item -ItemType Directory -Force $StateDir | Out-Null
Start-Transcript -Append -Path "$StateDir\k8s-setup.log" | Out-Null

try {
    if ($Resume) {
        Write-Step "Resuming after the reboot"
        Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue
    }

    # ----------------------------------------------------------------------
    Write-Step "Node settings"
    # ----------------------------------------------------------------------

    $latestKubernetes = if (-not $KubernetesVersion -and -not $Resume) {
        (Invoke-WebRequest https://dl.k8s.io/release/stable.txt -UseBasicParsing).Content.Trim()
    }
    $KubernetesVersion = Resolve-Value KubernetesVersion $KubernetesVersion "Kubernetes version (same as the cluster)" ${function:Test-Version} $latestKubernetes
    $KubernetesVersion = "v" + $KubernetesVersion.TrimStart("v")

    if (-not $ContainerdVersion) {
        $ContainerdVersion = Get-LatestGitHubRelease containerd/containerd
        Write-Host "No containerd version given; using the latest: $ContainerdVersion"
    }
    $ContainerdVersion = $ContainerdVersion.TrimStart("v")
    if (-not (Test-Version $ContainerdVersion)) { throw "Invalid containerd version: $ContainerdVersion" }

    if (-not $CrictlVersion) {
        $CrictlVersion = ($KubernetesVersion.TrimStart("v").Split(".")[0..1] -join ".") + ".0"
    }
    $CrictlVersion = $CrictlVersion.TrimStart("v")
    if (-not (Test-Version $CrictlVersion)) { throw "Invalid crictl version: $CrictlVersion" }

    $Vip = Resolve-Value Vip $Vip "Control plane VIP" ${function:Test-Ipv4}
    $VipHostname = Resolve-Value VipHostname $VipHostname "VIP hostname" ${function:Test-Hostname} "k8s-endpoint"
    $Token = Resolve-Value Token $Token "Bootstrap token" ${function:Test-Token}
    $CaCertHash = Resolve-Value CaCertHash $CaCertHash "CA certificate hash" ${function:Test-CaCertHash}
    if (-not $CaCertHash.StartsWith("sha256:")) { $CaCertHash = "sha256:$CaCertHash" }

    # On nodes with more than one NIC the kubelet may register the wrong one.
    # Calico follows the node's InternalIP (NodeInternalIP in k8s-setup.sh), so
    # VXLAN would then use an address outside the HNS network and traffic from
    # other nodes would never reach the pods.
    if (-not $NodeIp) {
        $NodeIp = Find-NetRoute -RemoteIPAddress $Vip |
            Where-Object { $_.IPAddress } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if (-not $NodeIp) { throw "Could not find the interface that reaches $Vip; pass -NodeIp." }
    }
    if (-not (Test-Ipv4 $NodeIp)) { throw "Invalid value for -NodeIp: $NodeIp" }
    if (-not (Get-NetIPAddress -IPAddress $NodeIp -ErrorAction SilentlyContinue)) {
        throw "$NodeIp is not an address of this machine."
    }

    Write-Host "Kubernetes: $KubernetesVersion"
    Write-Host "containerd: $ContainerdVersion (crictl $CrictlVersion)"
    Write-Host "Endpoint:   $VipHostname ($Vip)"
    Write-Host "Node IP:    $NodeIp"

    # ----------------------------------------------------------------------
    Write-Step "Windows features"
    # ----------------------------------------------------------------------

    # Same features Install-Containerd.ps1 sets with -skipHypervisorSupportCheck,
    # so it does not stop asking for a reboot.
    $rebootNeeded = $false

    if (-not (Get-WindowsFeature -Name Containers).Installed) {
        Write-Host "Installing the Containers feature..."
        Install-WindowsFeature -Name Containers | Out-Null
        $rebootNeeded = $true
    }

    if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -ne "Enabled") {
        Write-Host "Enabling Microsoft-Hyper-V..."
        dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V /All /NoRestart | Out-Host
        # 3010: success, reboot required.
        if ($LASTEXITCODE -notin 0, 3010) { throw "DISM failed to enable Microsoft-Hyper-V (exit code $LASTEXITCODE)." }
        $rebootNeeded = $true
    }

    if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Online).State -ne "Disabled") {
        Write-Host "Disabling Microsoft-Hyper-V-Online..."
        dism.exe /Online /Disable-Feature /FeatureName:Microsoft-Hyper-V-Online /NoRestart | Out-Host
        if ($LASTEXITCODE -notin 0, 3010) { throw "DISM failed to disable Microsoft-Hyper-V-Online (exit code $LASTEXITCODE)." }
        $rebootNeeded = $true
    }

    if ($rebootNeeded) {
        if ($Resume) { throw "The Windows features still need a reboot after restarting; check them manually." }

        Write-Step "Scheduling the rest of the installation after the reboot"

        if ($PSCommandPath -ne $ScriptCopy) { Copy-Item -Force $PSCommandPath $ScriptCopy }

        $arguments = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$ScriptCopy`"",
            "-KubernetesVersion", $KubernetesVersion,
            "-ContainerdVersion", $ContainerdVersion,
            "-CrictlVersion", $CrictlVersion,
            "-Vip", $Vip,
            "-VipHostname", $VipHostname,
            "-Token", $Token,
            "-CaCertHash", $CaCertHash,
            "-NodeIp", $NodeIp,
            "-Resume"
        ) -join " "

        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $ResumeTask -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

        Write-Host "The installation continues when $user logs on again."
        if ($NoRestart) {
            Write-Host "Restart the machine to continue." -ForegroundColor Yellow
        } else {
            Write-Host "Restarting in 10 seconds (Ctrl+C to cancel)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
            Restart-Computer -Force
        }
        return
    }

    # ----------------------------------------------------------------------
    Write-Step "Adding $VipHostname to the hosts file"
    # ----------------------------------------------------------------------

    $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
    $pattern = "\s$([regex]::Escape($VipHostname))(\s|$)"
    $hosts = @(Get-Content $hostsFile | Where-Object { $_ -notmatch $pattern })
    $hosts += "$Vip  $VipHostname"
    Set-Content -Path $hostsFile -Value $hosts -Encoding Ascii

    Set-Location $StateDir

    # ----------------------------------------------------------------------
    Write-Step "Installing containerd $ContainerdVersion"
    # ----------------------------------------------------------------------

    if (Get-Service containerd -ErrorAction SilentlyContinue) {
        Write-Host "containerd is already installed; skipping."
    } else {
        Save-File "$SigWindowsTools/Install-Containerd.ps1" "$StateDir\Install-Containerd.ps1"
        & "$StateDir\Install-Containerd.ps1" -ContainerDVersion $ContainerdVersion -crictlVersion $CrictlVersion `
            -skipHypervisorSupportCheck -CNIConfigPath $CniConfigPath -CNIBinPath $CniBinPath
        if (-not (Get-Service containerd -ErrorAction SilentlyContinue)) {
            throw "Install-Containerd.ps1 did not install containerd."
        }
    }

    # ----------------------------------------------------------------------
    Write-Step "Installing kubelet and kubeadm $KubernetesVersion"
    # ----------------------------------------------------------------------

    if (Get-Service kubelet -ErrorAction SilentlyContinue) {
        Write-Host "kubelet is already installed; skipping."
    } else {
        Save-File "$SigWindowsTools/PrepareNode.ps1" "$StateDir\PrepareNode.ps1"
        & "$StateDir\PrepareNode.ps1" -KubernetesVersion $KubernetesVersion
        if (-not (Get-Service kubelet -ErrorAction SilentlyContinue)) {
            throw "PrepareNode.ps1 did not register the kubelet service."
        }
    }

    # ----------------------------------------------------------------------
    Write-Step "Joining the cluster"
    # ----------------------------------------------------------------------

    if (Test-Path C:\etc\kubernetes\kubelet.conf) {
        Write-Host "This node has already joined a cluster; skipping."
    } else {
        # kubeadm join has no flag for the node IP and does not accept --token
        # together with --config, so everything goes in the file. The taint keeps
        # Linux workloads off this node; Windows ones need a toleration for it.
        $joinConfig = "$StateDir\kubeadm-join.yaml"
        try {
            Set-Content -Path $joinConfig -Encoding Ascii -Value @"
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${VipHostname}:6443"
    token: "$Token"
    caCertHashes:
      - "$CaCertHash"
nodeRegistration:
  kubeletExtraArgs:
    - name: node-ip
      value: "$NodeIp"
  taints:
    - key: os
      value: windows
      effect: NoSchedule
"@
            & C:\k\kubeadm.exe join --config $joinConfig
            if ($LASTEXITCODE -ne 0) { throw "kubeadm join failed (exit code $LASTEXITCODE)." }
        }
        finally {
            # It holds the bootstrap token.
            Remove-Item -Force $joinConfig -ErrorAction SilentlyContinue
        }
    }

    # ----------------------------------------------------------------------
    Write-Step "Done"
    # ----------------------------------------------------------------------

    Write-Host "containerd: $ContainerdVersion"
    Write-Host "kubernetes: $KubernetesVersion"
    Write-Host "On a control plane, check the node with: kubectl get nodes -o wide"
    Write-Host "Log: $StateDir\k8s-setup.log"
}
finally {
    Stop-Transcript | Out-Null
}
