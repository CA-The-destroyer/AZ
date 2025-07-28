```powershell
<#
.SYNOPSIS
  Shutdown (stop/deallocate) selected Azure VMs by zone, non-zonal, all, specific, or none,
  then emit a restart script for exactly those VMs.

.PARAMETER WhatIf
  Simulate actions without making changes.
#>

param(
    [switch]$WhatIf
)

#———————————————————————————————————————————————
# PRELIM: Ensure Azure CLI is installed and logged in
#———————————————————————————————————————————————
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

#———————————————————————————————————————————————
# 1) Prepare log
#———————————————————————————————————————————————
$timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$logFile   = Join-Path $PSScriptRoot "DR-Zone-Shutdown-$timestamp.log"
"Run started at $(Get-Date -Format 'u')" | Out-File $logFile -Encoding UTF8

#———————————————————————————————————————————————
# NOTE: This takes a long time (~5 mins) to collect initial VM data for the menu
#———————————————————————————————————————————————
Write-Host "`nNote: this takes a long time (~5 mins) to collect the initial VM data for the menu" -ForegroundColor Yellow

#———————————————————————————————————————————————
# 2) Fetch all VMs
#———————————————————————————————————————————————
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

#———————————————————————————————————————————————
# NOTE: Shutting down each VM can take up to 5 minutes—please be patient.
#———————————————————————————————————————————————
Write-Host "`nNote: shutting down each VM can take up to 5 minutes — please be patient." -ForegroundColor Yellow

#———————————————————————————————————————————————
# 3) Group VMs by availability zone
#———————————————————————————————————————————————
$zonal    = $allVMs | Where-Object { $_.Zones -and $_.Zones.Count -gt 0 }
$nonZonal = $allVMs | Where-Object { -not $_.Zones -or $_.Zones.Count -eq 0 }
$zones    = $zonal | ForEach-Object { $_.Zones } | ForEach-Object { $_ } | Sort-Object -Unique
$groups   = @{}
foreach ($z in $zones) { $groups[$z] = $zonal | Where-Object { $_.Zones -contains $z } }

#———————————————————————————————————————————————
# 4) Build the selection menu
#———————————————————————————————————————————————
$menu = @()
foreach ($z in $zones) {
    $menu += [pscustomobject]@{ Label = "Zone $z";    Targets = $groups[$z] }
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

#———————————————————————————————————————————————
# Handle 'Specific VM' selection
#———————————————————————————————————————————————
if ($choice.Label -eq 'Specific VM') {
    do {
        $vmName = Read-Host "Enter exact VM name"
        $match  = $allVMs | Where-Object { $_.Name -ieq $vmName }
        if (-not $match) { Write-Host "VM '$vmName' not found." -ForegroundColor Yellow }
    } while (-not $match)
    $targets = @($match)
    "Selection: Specific VM ($vmName)" | Out-File -Append $logFile
}
else {
    "Selection: $($choice.Label)" | Out-File -Append $logFile
}

if (-not $targets.Count) {
    Write-Host "No VMs selected, exiting." -ForegroundColor Green
    exit 0
}

#———————————————————————————————————————————————
# 5) Confirm selection
#———————————————————————————————————————————————
Write-Host "`nWill shutdown these VMs:" -ForegroundColor Cyan
$targets | ForEach-Object { Write-Host "  - $($_.Name) (RG: $($_.ResourceGroup))" }
if (-not $WhatIf) {
    $ok = Read-Host "`nProceed? (Y/N)"
    if ($ok -notin 'Y','y') { exit 0 }
}

#———————————————————————————————————————————————
# 6) Shutdown loop: stop ephemeral‐OS vs deallocate
#———————————————————————————————————————————————
$stoppedVMs = @()
foreach ($vm in $targets) {
    $rg = $vm.ResourceGroup; $nm = $vm.Name

    # Detect ephemeral OS disk
    $opt = az vm show --resource-group $rg --name $nm `
           --query "storageProfile.osDisk.diffDiskSettings.option" -o tsv 2>$null

    if ($opt -ieq 'Local') {
        # Ephemeral OS ⇒ stop first
        $cmd = "az vm stop --resource-group `"$rg`" --name `"$nm`" --no-wait"
        Write-Host "Stopping (ephemeral OS) $nm" -ForegroundColor Yellow
        $stoppedVMs += [pscustomobject]@{ ResourceGroup = $rg; Name = $nm }
    }
    else {
        # Standard ⇒ deallocate
        $cmd = "az vm deallocate --resource-group `"$rg`" --name `"$nm`" --no-wait"
        Write-Host "Deallocating $nm" -ForegroundColor Yellow
    }

    if ($WhatIf) {
        Write-Host "  WhatIf: $cmd"
        "Would run: $cmd" | Out-File -Append $logFile
    }
    else {
        try {
            Invoke-Expression $cmd | Out-Null
            "Ran: $cmd" | Out-File -Append $logFile
        }
        catch {
            Write-Host "Error running: $cmd – $_" -ForegroundColor Red
            "Error: $_" | Out-File -Append $logFile
        }
    }
}
Write-Host "`nShutdown commands submitted." -ForegroundColor Green
"Completed shutdown at $(Get-Date -Format 'u')" | Out-File -Append $logFile

#———————————————————————————————————————————————
# 7) Prompt to deallocate ephemeral‑OS VMs
#———————————————————————————————————————————————
if ($stoppedVMs.Count -gt 0) {
    Write-Host "`nThe following ephemeral‑OS VMs were stopped (not deallocated):`n" -ForegroundColor Cyan
    $stoppedVMs | ForEach-Object { Write-Host "  - $($_.Name) (RG: $($_.ResourceGroup))" }

    if (-not $WhatIf) {
        $ans = Read-Host "`nDeallocate these VMs now? (Y/N)"
    }
    else {
        $ans = 'Y'
    }

    if ($ans -in 'Y','y') {
        foreach ($vm in $stoppedVMs) {
            $dCmd = "az vm deallocate --resource-group `"$($vm.ResourceGroup)`" --name `"$($vm.Name)`" --no-wait"
            Write-Host "Deallocating $($vm.Name)" -ForegroundColor Yellow
            if ($WhatIf) {
                Write-Host "  WhatIf: $dCmd"
                "Would run: $dCmd" | Out-File -Append $logFile
            }
            else {
                try {
                    Invoke-Expression $dCmd | Out-Null
                    "Ran: $dCmd" | Out-File -Append $logFile
                }
                catch {
                    Write-Host "Error running: $dCmd – $_" -ForegroundColor Red
                    "Error: $_" | Out-File -Append $logFile
                }
            }
        }
        Write-Host "`nEphemeral‑OS VMs deallocated." -ForegroundColor Green
        "Ephemeral‑OS VMs deallocated at $(Get-Date -Format 'u')" | Out-File -Append $logFile
    }
}

#———————————————————————————————————————————————
# 8) Generate restart script
#———————————————————————————————————————————————
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
```
