<#
.SYNOPSIS
  Shutdown (stop/deallocate) selected VMs by zone/non-zonal/all/specific/none,
  then emit a restart script for exactly those VMs.

.PARAMETER WhatIf
  Simulate actions without making changes.

  CA-7-2025
#>

param(
    [switch]$WhatIf
)

#———————————————————————————————————————————————
# PRELIM: Ensure az CLI is installed & logged in
#———————————————————————————————————————————————
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI ('az') not found. Install from https://aka.ms/install-azure-cli"
    exit 1
}

# Try to see if we're already logged in; if not, prompt
try {
    az account show --output none 2>$null
}
catch {
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
# 2) Fetch all VMs
#———————————————————————————————————————————————
try {
    $allVMs = az vm list --show-details `
        --query "[].{Name:name,ResourceGroup:resourceGroup,Zones:zones}" -o json |
        ConvertFrom-Json
}
catch {
    Write-Error "Failed to list VMs: $_"
    exit 1
}

if (-not $allVMs.Count) {
    Write-Host "No VMs found." -ForegroundColor Green
    exit 0
}

#———————————————————————————————————————————————
# 3) Group VMs by zone
#———————————————————————————————————————————————
$zonal     = $allVMs | Where-Object { $_.Zones -and $_.Zones.Count -gt 0 }
$nonZonal  = $allVMs | Where-Object { -not $_.Zones -or $_.Zones.Count -eq 0 }
$zones     = $zonal | ForEach-Object { $_.Zones } | ForEach-Object { $_ } | Sort-Object -Unique
$groups    = @{}
foreach ($z in $zones) { $groups[$z] = $zonal | Where-Object { $_.Zones -contains $z } }

#———————————————————————————————————————————————
# 4) Build menu
#———————————————————————————————————————————————
$menu = @()
foreach ($z in $zones) {
    $menu += [pscustomobject]@{ Label = "Zone $z"; Targets = $groups[$z] }
}
$menu += [pscustomobject]@{ Label = "Non-Zonal VMs"; Targets = $nonZonal }
$menu += [pscustomobject]@{ Label = "All VMs";        Targets = $allVMs }
$menu += [pscustomobject]@{ Label = "Specific VM";    Targets = @() }
$menu += [pscustomobject]@{ Label = "None";           Targets = @() }

Write-Host "`nChoices:" -ForegroundColor Cyan
for ($i=0; $i -lt $menu.Count; $i++) {
    Write-Host "  [$($i+1)] $($menu[$i].Label) ($($menu[$i].Targets.Count) VMs)"
}

do {
    $sel = Read-Host "`nEnter choice (1-$($menu.Count))"
} while (-not ($sel -as [int] -and $sel -ge 1 -and $sel -le $menu.Count))

$choice  = $menu[$sel-1]
$targets = $choice.Targets

# If Specific VM, prompt for the name
if ($choice.Label -eq 'Specific VM') {
    do {
        $vmName  = Read-Host "Enter exact VM name"
        $match = $allVMs | Where-Object { $_.Name -ieq $vmName }
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
$targets | ForEach-Object {
    Write-Host "  - $($_.Name) (RG: $($_.ResourceGroup))"
}
if (-not $WhatIf) {
    $ok = Read-Host "`nProceed? (Y/N)"
    if ($ok -notin 'Y','y') { exit 0 }
}

#———————————————————————————————————————————————
# 6) Shutdown loop: stop ephemeral‐OS vs deallocate
#———————————————————————————————————————————————
$ops = @()
foreach ($vm in $targets) {
    $rg = $vm.ResourceGroup
    $nm = $vm.Name

    # Detect ephemeral OS disk
    $opt = az vm show --resource-group $rg --name $nm `
           --query "storageProfile.osDisk.diffDiskSettings.option" -o tsv 2>$null

    if ($opt -eq 'Local') {
        # Ephemeral OS ⇒ stop
        $cmd = "az vm stop --resource-group `"$rg`" --name `"$nm`" --no-wait"
        Write-Host "Stopping (ephemeral OS) $nm" -ForegroundColor Yellow
    }
    else {
        # Standard ⇒ deallocate
        $cmd = "az vm deallocate --resource-group `"$rg`" --name `"$nm`" --no-wait"
        Write-Host "Deallocating $nm" -ForegroundColor Yellow
    }

    $ops += [pscustomobject]@{ RG = $rg; Name = $nm; Cmd = $cmd }

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
# 7) Generate restart script
#———————————————————————————————————————————————
$restart = Join-Path $PSScriptRoot "DR-Zone-Restart-$timestamp.ps1"
@(
    "# Restart Script generated $(Get-Date -Format 'u')",
    "# Starts the VMs that were shut down"
) | Out-File $restart

foreach ($e in $ops) {
    "az vm start --resource-group `"$($e.RG)`" --name `"$($e.Name)`"" |
        Out-File -Append $restart
}

Write-Host "`nRestart script saved at:`n  $restart" -ForegroundColor Cyan
Write-Host "`nLog file saved at:`n  $logFile" -ForegroundColor Cyan
