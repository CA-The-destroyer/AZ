#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shutdown (stop/deallocate) selected Azure VMs by zone, non-zonal, all, specific, or none,
  then emit a restart script for exactly those VMs.

.PARAMETER WhatIf
  Simulate actions without making changes.
#>

[CmdletBinding()]
param(
    [switch]$WhatIf
)

# Ensure Azure CLI is installed and logged in
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI ('az') not found. Install from https://aka.ms/install-azure-cli"
    exit 1
}
try {
    az account show --output none 2>$null
} catch {
    Write-Host "Not logged in. Launching 'az login'..." -ForegroundColor Yellow
    az login | Out-Null
}

# Prepare log
$timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$logFile   = Join-Path $PSScriptRoot "DR-Zone-Shutdown-$timestamp.log"
"Run started at $(Get-Date -Format 'u')" | Out-File $logFile -Encoding UTF8

Write-Host "`nNote: this takes a long time (~5 mins) to collect the initial VM data for the menu" -ForegroundColor Yellow

# Fetch all VMs
try {
    $allVMs = az vm list --show-details `
        --query "[].{Name:name,ResourceGroup:resourceGroup,Zones:zones}" -o json |
        ConvertFrom-Json
} catch {
    Write-Error "Failed to list VMs: $_"
    exit 1
}
if (-not $allVMs.Count) {
    Write-Host "No VMs found." -ForegroundColor Green
    exit 0
}

Write-Host "`nNote: shutting down each VM can take up to 5 minutes — please be patient." -ForegroundColor Yellow

# Group by zone
$zonal    = $allVMs | Where-Object { $_.Zones -and $_.Zones.Count -gt 0 }
$nonZonal = $allVMs | Where-Object { -not $_.Zones -or $_.Zones.Count -eq 0 }
$zones    = $zonal | ForEach-Object { $_.Zones } | ForEach-Object { $_ } | Sort-Object -Unique
$groups   = @{}
foreach ($z in $zones) { $groups[$z] = $zonal | Where-Object { $_.Zones -contains $z } }

# Build menu
$menu = @()
foreach ($z in $zones) {
    $menu += [pscustomobject]@{ Label = "Zone $z"; Targets = $groups[$z] }
}
$menu += [pscustomobject]@{ Label = "Non-Zonal VMs"; Targets = $nonZonal }
$menu += [pscustomobject]@{ Label = "All VMs";       Targets = $allVMs }
$menu += [pscustomobject]@{ Label = "Specific VM";   Targets = @() }
$menu += [pscustomobject]@{ Label = "None";          Targets = @() }

Write-Host "`nChoices:" -ForegroundColor Cyan
for ($i = 0; $i -lt $menu.Count; $i++) {
    Write-Host "  [$($i+1)] $($menu[$i].Label) ($($menu[$i].Targets.Count) VMs)"
}
do {
    $sel = Read-Host "`nEnter choice (1-$($menu.Count))"
} while (-not ($sel -as [int] -and $sel -ge 1 -and $sel -le $menu.Count))

$choice  = $menu[$sel - 1]
$targets = $choice.Targets

# Handle specific VM input
if ($choice.Label -eq 'Specific VM') {
    do {
        $vmName = Read-Host "Enter exact VM name"
        $match  = $allVMs | Where-Object { $_.Name -ieq $vmName }
        if (-not $match) { Write-Host "VM '$vmName' not found." -ForegroundColor Yellow }
    } while (-not $match)
    $targets = @($match)
    "Selection: Specific VM ($vmName)" | Out-File -Append $logFile
} else {
    "Selection: $($choice.Label)" | Out-File -Append $logFile
}

if (-not $targets.Count) {
    Write-Host "No VMs selected, exiting." -ForegroundColor Green
    exit 0
}

# Confirm
Write-Host "`nWill shutdown these VMs:" -ForegroundColor Cyan
$targets | ForEach-Object { Write-Host "  - $($_.Name) (RG: $($_.ResourceGroup))" }

if (-not $WhatIf) {
    $ok = Read-Host "`nProceed? (Y/N)"
    if ($ok -notin 'Y','y') { exit 0 }
}

# Shutdown logic
$stoppedVMs = @()
foreach ($vm in $targets) {
    $rg = $vm.ResourceGroup; $nm = $vm.Name
    $opt = az vm show --resource-group $rg --name $nm `
           --query "storageProfile.osDisk.diffDiskSettings.option" -o tsv 2>$null

    if ($opt -ieq 'Local') {
        $cmd = "az vm stop --resource-group `"$rg`" --name `"$nm`" --no-wait"
        Write-Host "Stopping (ephemeral OS) $nm" -ForegroundColor Yellow
        $stoppedVMs += [pscustomobject]@{ ResourceGroup = $rg; Name = $nm }
    } else {
        $cmd = "az vm deallocate --resource-group `"$rg`" --name `"$nm`" --no-wait"
        Write-Host "Deallocating $nm" -ForegroundColor Yellow
    }

    if ($WhatIf) {
        Write-Host "  WhatIf: $cmd"
        "Would run: $cmd" | Out-File -Append $logFile
    } else {
        try {
            Invoke-Expression $cmd | Out-Null
            "Ran: $cmd" | Out-File -Append $logFile
        } catch {
            Write-Host "Error running: $cmd – $_" -ForegroundColor Red
            "Error: $_" | Out-File -Append $logFile
        }
    }
}
Write-Host "`nShutdown commands submitted." -ForegroundColor Green
"Completed shutdown at $(Get-Date -Format 'u')" | Out-File -Append $logFile

# Wait for ephemeral-OS VMs to reach 'stopped' state
if ($stoppedVMs.Count -gt 0) {
    Write-Host "`nWaiting for ephemeral-OS VMs to fully stop..." -ForegroundColor Yellow
    $spinner = @('|','/','-','\')
    foreach ($vm in $stoppedVMs) {
        $name = $vm.Name; $rg = $vm.ResourceGroup
        Write-Host "Waiting for VM '$name' to reach 'PowerState/stopped'..." -NoNewline

        $timeout = [datetime]::Now.AddMinutes(5)
        $i = 0
        do {
            $state = az vm get-instance-view --resource-group $rg --name $name `
                --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code" -o tsv 2>$null
            $spinnerChar = $spinner[$i % $spinner.Length]
            Write-Host -NoNewline "`b$spinnerChar"
            Start-Sleep -Seconds 2
            $i++
        } while ($state -ne 'PowerState/stopped' -and [datetime]::Now -lt $timeout)

        if ($state -eq 'PowerState/stopped') {
            Write-Host "`b✔️" -ForegroundColor Green
        } else {
            Write-Host "`b❌ Timed out waiting for VM '$name'" -ForegroundColor Red
            "Timeout: $name did not reach stopped state in 5 minutes" | Out-File -Append $logFile
        }
    }
    Write-Host "`nEphemeral-OS VMs check complete." -ForegroundColor Green
}

# Optional deallocation
if ($stoppedVMs.Count -gt 0) {
    Write-Host "`nThe following ephemeral‑OS VMs were stopped (not deallocated):`n" -ForegroundColor Cyan
    $stoppedVMs | ForEach-Object { Write-Host "  - $($_.Name) (RG: $($_.ResourceGroup))" }

    if (-not $WhatIf) {
        $ans = Read-Host "`nDeallocate these VMs now? (Y/N)"
    } else {
        $ans = 'Y'
    }

    if ($ans -in 'Y','y') {
        foreach ($vm in $stoppedVMs) {
            $dCmd = "az vm deallocate --resource-group `"$($vm.ResourceGroup)`" --name `"$($vm.Name)`" --no-wait"
            Write-Host "Deallocating $($vm.Name)" -ForegroundColor Yellow
            if ($WhatIf) {
                Write-Host "  WhatIf: $dCmd"
                "Would run: $dCmd" | Out-File -Append $logFile
            } else {
                try {
                    Invoke-Expression $dCmd | Out-Null
                    "Ran: $dCmd" | Out-File -Append $logFile
                } catch {
                    Write-Host "Error running: $dCmd – $_" -ForegroundColor Red
                    "Error: $_" | Out-File -Append $logFile
                }
            }
        }
        Write-Host "`nEphemeral‑OS VMs deallocated." -ForegroundColor Green
        "Ephemeral‑OS VMs deallocated at $(Get-Date -Format 'u')" | Out-File -Append $logFile
    }
}

# Generate restart script
$restart = Join-Path $PSScriptRoot "DR-Zone-Restart-$timestamp.ps1"
@(
    "# Restart Script generated $(Get-Date -Format 'u')",
    "# Starts the VMs that were shut down"
) | Out-File $restart -Encoding UTF8

foreach ($vm in $targets) {
    "az vm start --resource-group `"$($vm.ResourceGroup)`" --name `"$($vm.Name)`"" |
        Out-File -Append $restart -Encoding UTF8
}

Write-Host "`nRestart script saved at:`n  $restart" -ForegroundColor Cyan
Write-Host "`nLog file saved at:`n  $logFile" -ForegroundColor Cyan
