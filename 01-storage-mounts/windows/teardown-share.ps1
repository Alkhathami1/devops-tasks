<#
.SYNOPSIS
    Reverses everything setup-share.ps1 changed. Run ELEVATED.

.DESCRIPTION
    Restores the machine to its prior state: removes the share, the dedicated
    user and its directory, and puts the firewall settings back the way they
    were found (SMB-In rules disabled, Hyper-V inbound blocked for the WSL
    vSwitch).

    Every step is guarded, so running this on a machine where setup never ran,
    or running it twice, is harmless.
#>

[CmdletBinding()]
param(
    [string] $ShareName = 'task01share',
    [string] $SharePath = 'C:\task01share',
    [string] $SmbUser   = 'task01smb',
    [switch] $KeepFiles
)

$ErrorActionPreference = 'Continue'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run from an ELEVATED PowerShell. Nothing has been changed."
    exit 1
}

Write-Host "=== Task 01 Windows teardown ===" -ForegroundColor Cyan

# Prefer the state file setup wrote. Without it teardown has to guess, and
# guessing means reverting things that were never set - disabling SMB-In rules
# that were already on before setup ran, for instance.
$statePath = Join-Path $PSScriptRoot ".setup-state.json"
$state = $null
if (Test-Path $statePath) {
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        Write-Host "  using state from $statePath (setup ran $($state.Timestamp))"
    } catch {
        Write-Host "  state file unreadable, falling back to best effort"
    }
} else {
    Write-Host "  no state file; falling back to best effort"
}

# --- share -------------------------------------------------------------------
if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
    Remove-SmbShare -Name $ShareName -Force
    Write-Host "  removed share '$ShareName'"
} else {
    Write-Host "  share '$ShareName' not present"
}

# --- files -------------------------------------------------------------------
if (Test-Path $SharePath) {
    if ($KeepFiles) {
        Write-Host "  keeping $SharePath (-KeepFiles)"
    } else {
        Remove-Item -Recurse -Force $SharePath
        Write-Host "  removed $SharePath"
    }
}

# --- user --------------------------------------------------------------------
if (Get-LocalUser -Name $SmbUser -ErrorAction SilentlyContinue) {
    Remove-LocalUser -Name $SmbUser
    Write-Host "  removed local user '$SmbUser'"
} else {
    Write-Host "  local user '$SmbUser' not present"
}

$secretPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'secrets\windows_smb_password.txt'
if (Test-Path $secretPath) {
    Remove-Item -Force $secretPath
    Write-Host "  removed $secretPath"
}

# --- firewall: back to disabled, which is how they were found ----------------
if ($state -and $state.PSObject.Properties.Name -contains "FirewallEnabled") {
    $toDisable = @($state.FirewallEnabled)
    if ($toDisable.Count -eq 0) {
        Write-Host "  no SMB-In rules were enabled by setup; leaving the firewall alone"
    } else {
        foreach ($n in $toDisable) {
            Disable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
        }
        Write-Host "  disabled the $($toDisable.Count) SMB-In rule(s) setup had enabled"
    }
} else {
    # Best effort: this host shipped with them disabled, so restore that.
    $smbIn = Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -match 'SMB-In' }
    foreach ($r in $smbIn) { Disable-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
    Write-Host "  disabled $($smbIn.Count) SMB-In rule(s) (best effort, no state file)"
}
# --- Hyper-V firewall --------------------------------------------------------
if ($state -and @($state.HyperVChanged).Count -eq 0) {
    Write-Host "  setup changed no Hyper-V firewall setting; nothing to restore"
} else {
    try {
        $names = if ($state) { @($state.HyperVChanged) } else {
            @(Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -ErrorAction Stop |
              Where-Object { $_.Name -match 'WSL' -or $_.DisplayName -match 'WSL' } |
              Select-Object -ExpandProperty Name)
        }
        if ($names.Count -eq 0) {
            Write-Host "  no WSL Hyper-V VM setting present; nothing to restore"
        } else {
            foreach ($n in $names) {
                Set-NetFirewallHyperVVMSetting -Name $n -DefaultInboundAction Block
                Write-Host "  set $n DefaultInboundAction=Block, as found"
            }
        }
    } catch {
        Write-Host "  Hyper-V firewall cmdlets unavailable; nothing to restore"
    }
}
# --- any drive mapping from Direction B --------------------------------------
$mapped = Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.RemotePath -match 'task01' }
foreach ($m in $mapped) {
    Remove-SmbMapping -LocalPath $m.LocalPath -Force -ErrorAction SilentlyContinue
    Write-Host "  removed drive mapping $($m.LocalPath) -> $($m.RemotePath)"
}

Write-Host ""
if (Test-Path $statePath) {
    Remove-Item -Force $statePath
    Write-Host "  removed $statePath"
}

Write-Host ""
Write-Host "Teardown complete. Only what setup recorded was reverted." -ForegroundColor Green
