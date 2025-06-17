<#
.SYNOPSIS
  CLI‐only interactive script to tag Azure VMs (grouped by Resource Group), record changes, and generate an undo script.

.DESCRIPTION
  1. Ensures Az modules are installed & imported.
  2. Prompts to login and choose an Azure subscription by number.
  3. Lists VMs grouped by Resource Group and lets you select one or more by index.
  4. Prompts (with validation) for a tag key (max 512 chars) and value (max 256 chars).
  5. Skips any VM that already has that tag, merges the tag on the rest.
  6. Exports `TaggedVMs_<timestamp>.csv` with ResourceGroup, VMName, ResourceId.
  7. Generates `UndoTags_<timestamp>.ps1` which reverts those tag changes.
#>

# --- 1. Ensure modules & login ---
if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Write-Host 'Installing Az modules…' -ForegroundColor Yellow
    Install-Module Az -Scope CurrentUser -Force
}
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

if (-not (Get-AzContext)) {
    Write-Host 'Logging in to Azure…' -ForegroundColor Cyan
    Connect-AzAccount -ErrorAction Stop
}

# --- 2. Choose Subscription ---
$subs = Get-AzSubscription -ErrorAction SilentlyContinue
if (-not $subs) {
    Write-Host 'No subscriptions found. Re-logging in…' -ForegroundColor Yellow
    Connect-AzAccount -ErrorAction Stop
    $subs = Get-AzSubscription -ErrorAction Stop
}
Write-Host ''
Write-Host 'Available Subscriptions:' -ForegroundColor Cyan
for ($i = 0; $i -lt $subs.Count; $i++) {
    Write-Host "  [$i] $($subs[$i].Name) ($($subs[$i].Id))"
}
do {
    $sel = Read-Host 'Enter the number of the subscription to use'
} while (-not ([int]::TryParse($sel, [ref]0) -and $sel -ge 0 -and $sel -lt $subs.Count))
Set-AzContext -SubscriptionId $subs[$sel].Id -ErrorAction Stop
Write-Host "`n-> Using subscription: $($subs[$sel].Name)" -ForegroundColor Green

# --- 3. List & group VMs ---
$vms = Get-AzVM -ErrorAction Stop | Select-Object Name, ResourceGroupName, Id
if ($vms.Count -eq 0) {
    Write-Error "No VMs found in subscription." -ForegroundColor Red; exit 1
}

# Create indexed list
$indexedVMs = $vms | ForEach-Object -Begin { $i = 0 } -Process {
    [PSCustomObject]@{
        Index         = $i
        ResourceGroup = $_.ResourceGroupName
        Name          = $_.Name
        Id            = $_.Id
    }
    $i++
}

# Group by ResourceGroup and display
Write-Host "`nAvailable VMs grouped by Resource Group:" -ForegroundColor Cyan
$indexedVMs |
    Group-Object ResourceGroup |
    Sort-Object Name |
    ForEach-Object {
        Write-Host "`n=== $($_.Name) ==="
        $_.Group | Sort-Object Name | ForEach-Object {
            Write-Host "  [$($_.Index)] $($_.Name)"
        }
    }

# Prompt for selection
Write-Host '`nYou may tag multiple VMs—enter comma-separated indexes (e.g. 0,2,5).'
do {
    $input = Read-Host 'Enter VM numbers to tag'
    $indices = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $valid   = $indices.Count -gt 0 -and ($indices | Where-Object { $_ -lt 0 -or $_ -ge $indexedVMs.Count }).Count -eq 0
    if (-not $valid) { Write-Host '  ► Invalid selection, try again.' -ForegroundColor Red }
} while (-not $valid)
$selected = $indices | ForEach-Object { $indexedVMs[$_] }

# --- 4. Prompt for tag key/value ---
function Read-ValidInput {
    param($Prompt, $MaxLength)
    do {
        $val = Read-Host -Prompt $Prompt
        if ([string]::IsNullOrWhiteSpace($val)) {
            Write-Host '  ► Input cannot be empty.' -ForegroundColor Red
        } elseif ($val.Length -gt $MaxLength) {
            Write-Host "  ► Too long (max $MaxLength chars)." -ForegroundColor Red
        } else {
            return $val
        }
    } while ($true)
}
$tagKey   = Read-ValidInput 'Enter TAG KEY (max 512 chars)' 512
$tagValue = Read-ValidInput 'Enter TAG VALUE (max 256 chars)' 256

# --- 5. Apply tags & collect changes ---
$changes = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($vm in $selected) {
    Write-Host "`nProcessing $($vm.ResourceGroup)/$($vm.Name)..." -ForegroundColor Cyan
    $res     = Get-AzResource -ResourceId $vm.Id -ExpandProperties -ErrorAction Stop
    $oldTags = if ($res.Tags) { $res.Tags } else { @{} }

    if ($oldTags.ContainsKey($tagKey)) {
        Write-Host "  [SKIP] '$tagKey' already exists." -ForegroundColor Yellow
        continue
    }

    try {
        Update-AzTag -ResourceId $vm.Id -Tag @{ $tagKey = $tagValue } -Operation Merge -ErrorAction Stop
        Write-Host '  [OK] Tagged successfully.' -ForegroundColor Green

        $resNew  = Get-AzResource -ResourceId $vm.Id -ExpandProperties -ErrorAction Stop
        $newTags = if ($resNew.Tags) { $resNew.Tags } else { @{} }

        $changes.Add([PSCustomObject]@{
            ResourceGroup = $vm.ResourceGroup
            VMName        = $vm.Name
            ResourceId    = $vm.Id
            OldTags       = ($oldTags | ConvertTo-Json -Compress)
            NewTags       = ($newTags | ConvertTo-Json -Compress)
        })
    }
    catch {
        Write-Host "  [ERR] Failed to tag: $_" -ForegroundColor Red
    }
}

# --- 6. Export CSV artifact ---
$ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
$outCsv  = "TaggedVMs_$ts.csv"
if ($changes.Count -gt 0) {
    $changes | Export-Csv -Path $outCsv -NoTypeInformation
    Write-Host "`n✅ Exported change log to $outCsv" -ForegroundColor Green
} else {
    Write-Host "`n⚠️  No VMs were tagged." -ForegroundColor Yellow
}

# --- 7. Generate Undo Script ---
$undoPs = "UndoTags_$ts.ps1"
$header = @"
<#
   Revert tags for VMs based on '$outCsv'
#>
"@

$body = @'
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop
if (-not (Get-AzContext)) { Connect-AzAccount -ErrorAction Stop }

$changes = Import-Csv -Path PLACEHOLDER
foreach ($c in $changes) {
    Write-Host "Reverting $($c.VMName)..." -ForegroundColor Cyan
    $old = $c.OldTags | ConvertFrom-Json
    Update-AzTag -ResourceId $c.ResourceId -Tag $old -Operation Replace -ErrorAction Stop
    Write-Host "  [OK] Reverted." -ForegroundColor Green
}
'@

$body = $body -replace 'PLACEHOLDER', $outCsv
$script = $header + "`n" + $body
$script | Out-File -FilePath $undoPs -Encoding UTF8

Write-Host "`n🔄 Undo script generated: $undoPs" -ForegroundColor Green
