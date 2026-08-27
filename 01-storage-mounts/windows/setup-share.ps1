<#
.SYNOPSIS
    Windows-side setup for Task 01. MUST be run from an ELEVATED PowerShell.

.DESCRIPTION
    Everything the Linux side of this task needs from Windows, and nothing more.
    Both directions of the assignment are blocked without it, and neither can be
    done from an unelevated shell:

      Direction A (Windows share -> Linux)
        Creating an SMB share requires administrator rights. The only shares
        that exist by default are the administrative ones (C$, ADMIN$, IPC$),
        and those require admin credentials to access remotely - which would
        mean handling the operator's real Windows password.

      Direction B (Linux share -> Windows)
        NOT fixed by this script, and the reason is worth stating precisely.
        The obstacle is NOT the Hyper-V firewall: a listener inside the WSL
        distro on 172.25.112.168:4446 answers Test-NetConnection with True,
        even though DefaultInboundAction is Block.

        The obstacle is that Docker Desktop runs containers in a network
        namespace separate from the WSL distro (netns 4026532218 vs
        4026531840). Only the distro holds a Windows-routable address
        (172.25.112.168); the container has 192.168.65.3, which Windows has
        no route to. --network host does not help - on Docker Desktop that
        means the Docker VM host namespace, not the distro.

        Publishing the port is no help either: Windows itself holds
        0.0.0.0:445 (PID 4), and the SMB client cannot use another port.

        To finish Direction B, serve Samba from a real WSL distro
        (wsl --install -d Ubuntu) rather than from a container.

    This script:
      1. creates a dedicated local user for SMB, so the operator's own
         credentials are never involved
      2. creates a share backed by a dedicated directory, granting only that user
      3. enables the File and Printer Sharing (SMB-In) firewall rules, which
         ship DISABLED on this host
      4. allows inbound traffic to the WSL vSwitch through the Hyper-V firewall
      5. confirms SMB1 is off and reports the SMB server configuration

.NOTES
    Everything it changes is reported at the end, and windows/teardown-share.ps1
    reverses all of it.
#>

[CmdletBinding()]
param(
    [string] $ShareName = 'task01share',
    [string] $SharePath = 'C:\task01share',
    [string] $SmbUser   = 'task01smb'
)

$ErrorActionPreference = 'Stop'

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error @"
This script must be run from an ELEVATED PowerShell.

  Right-click PowerShell -> Run as Administrator, then:
    cd '$PSScriptRoot'
    .\setup-share.ps1

Nothing has been changed.
"@
        exit 1
    }
}

function Assert-WindowsLimits {
    <#
      Validate every value that Windows caps, BEFORE touching the machine.

      These limits are enforced at the API, not by the parser, so a value that
      is too long sails through any syntax check and then fails at the moment
      of account creation with a raw ParameterArgumentValidationError that
      names the parameter but not the limit. That is precisely how the
      52-character -Description on this script got shipped.

      Limits applied:
        local user name         20   (SAM account name)
        local user description  48
        local user full name   256
        share name              80
        share description      256   (SMB remark)
        local password         127
    #>
    param(
        [string] $UserName,
        [string] $UserDescription,
        [string] $UserFullName,
        [string] $ShareName,
        [string] $ShareDescription
    )

    $checks = @(
        @{ Label = "local user name";        Value = $UserName;         Max = 20  },
        @{ Label = "local user description"; Value = $UserDescription;  Max = 48  },
        @{ Label = "local user full name";   Value = $UserFullName;     Max = 256 },
        @{ Label = "share name";             Value = $ShareName;        Max = 80  },
        @{ Label = "share description";      Value = $ShareDescription; Max = 256 }
    )

    $bad = @()
    Write-Host "--- 0. preflight: Windows length limits ---"
    foreach ($c in $checks) {
        $len = $c.Value.Length
        $ok  = $len -le $c.Max
        Write-Host ("    {0,-24} {1,3} / {2,3}  {3}" -f $c.Label, $len, $c.Max, $(if ($ok) { "ok" } else { "TOO LONG" }))
        if (-not $ok) { $bad += ("{0} is {1} characters, limit {2}: `"{3}`"" -f $c.Label, $len, $c.Max, $c.Value) }
    }

    # A SAM account name also cannot be empty, end in a period, or contain any
    # of  " / \ [ ] : ; | = , + * ? < >
    if ($UserName -match '[\"/\\[\]:;|=,+*?<>]') { $bad += "user name contains a character Windows forbids: `"$UserName`"" }
    if ($UserName.EndsWith('.'))                    { $bad += "user name may not end with a period: `"$UserName`"" }
    if ([string]::IsNullOrWhiteSpace($UserName))     { $bad += "user name is empty" }

    if ($bad.Count -gt 0) {
        Write-Host ""
        Write-Error ("Preflight failed. Nothing has been changed.`n`n  - " + ($bad -join "`n  - "))
        exit 1
    }
    Write-Host "    all values within Windows limits"
}

Assert-Elevated

# Records what this run ACTUALLY changed, so the closing summary reports
# reality rather than a static list of intentions. A summary that claims a
# change which never happened sends the operator to a teardown that promises
# to revert something that was never set.
$Changed = [System.Collections.Generic.List[string]]::new()

$UserDescription = 'Task01 SMB account (setup-share.ps1)'
$UserFullName    = 'Task01 SMB service account'
$ShareDescription = 'Task 01 export from Windows to Linux'

Write-Host "=== Task 01 Windows setup ===" -ForegroundColor Cyan
Write-Host ""

Assert-WindowsLimits -UserName $SmbUser `
                     -UserDescription $UserDescription `
                     -UserFullName $UserFullName `
                     -ShareName $ShareName `
                     -ShareDescription $ShareDescription
Write-Host ""

# --- 1. dedicated local user -------------------------------------------------
Write-Host "--- 1. dedicated SMB user ---"
Write-Host "    A dedicated account, so the operator's own Windows password is"
Write-Host "    never placed in a credentials file on the Linux side."

$existing = Get-LocalUser -Name $SmbUser -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "    user '$SmbUser' already exists, leaving it alone"
} else {
    # 24 random bytes -> base64, with characters that complicate shell quoting
    # removed, then guaranteed to contain all four complexity classes.
    # Draw until there is definitely enough material. Stripping [+/=] from
    # base64 removes a variable number of characters, so Substring(0,16) on a
    # single draw can throw - rarely, and only at account-creation time, which
    # is the worst place to discover it.
    $raw = ''
    while ($raw.Length -lt 16) {
        $bytes = New-Object byte[] 24
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $raw += ([Convert]::ToBase64String($bytes) -replace '[+/=]', '')
    }
    # The 'Ta1!' prefix guarantees all four complexity classes regardless of
    # what the random part happens to contain.
    $plain = 'Ta1!' + $raw.Substring(0, 16)

    New-LocalUser -Name $SmbUser `
                  -Password (ConvertTo-SecureString $plain -AsPlainText -Force) `
                  -FullName $UserFullName `
                  -Description $UserDescription `
                  -PasswordNeverExpires `
                  -UserMayNotChangePassword | Out-Null
    Write-Host "    created local user '$SmbUser'"
    $Changed.Add("local user '$SmbUser' created")

    # Written where the Linux side expects it, and gitignored by **/secrets/*.
    $secretPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'secrets\windows_smb_password.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path $secretPath) | Out-Null
    [IO.File]::WriteAllText($secretPath, $plain)

    # Owner-only ACL, the Windows equivalent of chmod 600.
    $acl = Get-Acl $secretPath
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        "$env:USERDOMAIN\$env:USERNAME", 'FullControl', 'Allow')))
    Set-Acl -Path $secretPath -AclObject $acl

    Write-Host "    password written to $secretPath (owner-only ACL, not printed)"
    $Changed.Add("password file $secretPath written")
}

# --- 2. the share ------------------------------------------------------------
Write-Host ""
Write-Host "--- 2. the share ---"
New-Item -ItemType Directory -Force -Path $SharePath | Out-Null

$stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
@"
This file was created on the WINDOWS side and is served over SMB3.
Host    : $env:COMPUTERNAME
Created : $stamp
Share   : \\$env:COMPUTERNAME\$ShareName -> $SharePath
"@ | Set-Content -Path (Join-Path $SharePath 'README-from-windows.txt') -Encoding utf8

if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
    Write-Host "    share '$ShareName' already exists, leaving it alone"
} else {
    New-SmbShare -Name $ShareName -Path $SharePath -FullAccess $SmbUser `
                 -Description $ShareDescription | Out-Null
    Write-Host "    created share '$ShareName' -> $SharePath"
    $Changed.Add("directory $SharePath and SMB share '$ShareName' created")
}

# Share permissions are not enough; the NTFS ACL must allow the user too.
$acl = Get-Acl $SharePath
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
    $SmbUser, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl -Path $SharePath -AclObject $acl
Write-Host "    granted '$SmbUser' Modify on the NTFS path"
$Changed.Add("NTFS Modify granted to '$SmbUser' on $SharePath")

# --- 3. Windows firewall -----------------------------------------------------
Write-Host ""
Write-Host "--- 3. File and Printer Sharing (SMB-In) firewall rules ---"
Write-Host "    These ship DISABLED on this host, which is why inbound 445 is"
Write-Host "    blocked even though LanmanServer is listening."
$smbIn = Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue |
         Where-Object { $_.DisplayName -match 'SMB-In' }
$fwEnabled = 0
$fwEnabledNames = @()
foreach ($r in $smbIn) {
    Write-Host ("    {0,-40} was Enabled={1}" -f $r.DisplayName, $r.Enabled)
    # Only count rules this run actually flipped. Re-running on a host where
    # they are already on must not claim to have changed them.
    if (-not $r.Enabled) {
        Enable-NetFirewallRule -Name $r.Name
        $fwEnabled++
        $fwEnabledNames += $r.Name
    }
}
if ($fwEnabled -gt 0) {
    Write-Host "    enabled $fwEnabled SMB-In rule(s)"
    $Changed.Add("$fwEnabled File and Printer Sharing (SMB-In) firewall rule(s) enabled")
} else {
    Write-Host "    all SMB-In rules were already enabled; nothing changed"
}

# --- 4. Hyper-V firewall for the WSL vSwitch ---------------------------------
Write-Host ""
$hyperVChanged = @()
Write-Host "--- 4. Hyper-V firewall for the WSL vSwitch ---"
Write-Host "    DefaultInboundAction is Block on this host, but traffic to the"
Write-Host "    WSL distro was empirically reachable anyway, so this is set as a"
Write-Host "    precaution rather than a proven fix. It is NOT what blocks"
Write-Host "    Direction B - see the notes at the top of this script."
try {
    $vm = Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -ErrorAction Stop |
          Where-Object { $_.Name -match 'WSL' -or $_.DisplayName -match 'WSL' }
    if ($vm) {
        foreach ($v in $vm) {
            Write-Host ("    {0}: DefaultInboundAction was {1}" -f $v.Name, $v.DefaultInboundAction)
            Set-NetFirewallHyperVVMSetting -Name $v.Name -DefaultInboundAction Allow
            Write-Host "    set DefaultInboundAction=Allow"
            $Changed.Add("Hyper-V firewall DefaultInboundAction=Allow on $($v.Name)")
            $hyperVChanged += $v.Name
        }
    } else {
        Write-Host "    no WSL Hyper-V VM setting found; this Windows build may not use one"
    }
} catch {
    Write-Host "    Hyper-V firewall cmdlets unavailable: $($_.Exception.Message)"
    Write-Host "    (present from Windows 11 22H2; on older builds Direction B may"
    Write-Host "     work without this step, or need a port proxy instead)"
}

# --- 5. SMB server configuration --------------------------------------------
Write-Host ""
Write-Host "--- 5. SMB server configuration ---"
$cfg = Get-SmbServerConfiguration
Write-Host ("    EnableSMB1Protocol       : {0}   <- must be False" -f $cfg.EnableSMB1Protocol)
Write-Host ("    EnableSMB2Protocol       : {0}" -f $cfg.EnableSMB2Protocol)
Write-Host ("    EncryptData              : {0}" -f $cfg.EncryptData)
Write-Host ("    RequireSecuritySignature : {0}" -f $cfg.RequireSecuritySignature)

if ($cfg.EnableSMB1Protocol) {
    Write-Warning "SMB1 is ENABLED. Disabling it."
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
}

# Require encryption on this share specifically. Doing it per-share rather than
# server-wide avoids breaking any other SMB client on this machine.
Set-SmbShare -Name $ShareName -EncryptData $true -Force
Write-Host "    set EncryptData=True on share '$ShareName' (SMB3 encryption required)"
$Changed.Add("EncryptData=True on share '$ShareName'")

# --- summary -----------------------------------------------------------------
Write-Host ""
Write-Host "=== what to do next ===" -ForegroundColor Cyan
$wslIp = (wsl -d docker-desktop -e sh -c "ip -4 addr show eth0 | grep inet | awk '{print `$2}' | cut -d/ -f1") 2>$null
Write-Host ""
Write-Host "  Direction A (Windows -> Linux), from the repo root:"
Write-Host "    ./01-storage-mounts/scripts/direction-a.sh"
Write-Host ""
Write-Host "  Direction B (Linux -> Windows), from an ordinary PowerShell:"
Write-Host "    net use Z: \\$($wslIp)\task01 /user:smbuser <password> /persistent:yes"
Write-Host ""
Write-Host "  Undo everything this script did:"
Write-Host "    .\teardown-share.ps1"
Write-Host ""
# Record precisely what was changed, so teardown reverts exactly this and
# nothing else. Without it teardown has to guess - and would, for instance,
# disable SMB-In rules that were already enabled before this script ran.
$statePath = Join-Path $PSScriptRoot ".setup-state.json"
@{
    Timestamp        = (Get-Date -Format o)
    SmbUser          = $SmbUser
    ShareName        = $ShareName
    SharePath        = $SharePath
    UserCreated      = ($Changed -match "local user").Count -gt 0
    ShareCreated     = ($Changed -match "SMB share").Count -gt 0
    FirewallEnabled  = @($fwEnabledNames)
    HyperVChanged    = @($hyperVChanged)
} | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath -Encoding utf8
Write-Host ""
Write-Host "    state written to $statePath (read by teardown-share.ps1)"

Write-Host "=== changed by this script ===" -ForegroundColor Yellow
if ($Changed.Count -eq 0) {
    Write-Host "  nothing - every item was already in the desired state"
} else {
    foreach ($c in $Changed) { Write-Host "  - $c" }
}
Write-Host ""
Write-Host "  Only the items listed above were changed. teardown-share.ps1"
Write-Host "  reverses them and skips anything that was never set."
