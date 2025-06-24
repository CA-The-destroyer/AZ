<#
.SYNOPSIS
  CLI‐only interactive script to tag Azure VMs (grouped by Resource Group), with range‐style index selection, record changes, and generate an undo script.

.DESCRIPTION
  1. Ensures Az modules are installed & imported.
  2. Prompts to login and choose an Azure subscription by number.
  3. Lists VMs grouped by Resource Group and lets you select one or more by index or ranges (e.g. 1-5,7,10).
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
    Write-Error 'No VMs found in subscription.' -ForegroundColor Red
    exit 1
}

# Index VMs
$indexedVMs = $vms | ForEach-Object -Begin { $idx = 0 } -Process {
    [PSCustomObject]@{
        Index         = $idx
        ResourceGroup = $_.ResourceGroupName
        Name          = $_.Name
        Id            = $_.Id
    }
    $idx++
}

# Display grouped
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

# --- 4. Prompt for selection with ranges ---
Write-Host "`nYou may tag multiple VMs—enter comma-separated indexes or ranges (e.g. 1-5,7,10)."
do {
    $input  = Read-Host 'Enter VM number(s) to tag'
    $tokens = $input -split ',' | ForEach-Object { $_.Trim() }
    $indices = @()
    foreach ($t in $tokens) {
        if ($t -match '^\d+$') {
            $indices += [int]$t
        }
        elseif ($t -match '^(?<start>\d+)-(?<end>\d+)$') {
            $s = [int]$Matches['start']; $e = [int]$Matches['end']
            if ($s -le $e) { $indices += $s..$e }
            else         { $indices += $e..$s }
        }
    }
    $indices = $indices | Sort-Object -Unique
    $valid   = $indices.Count -gt 0 -and ($indices | Where-Object { $_ -lt 0 -or $_ -ge $indexedVMs.Count }).Count -eq 0
    if (-not $valid) {
        Write-Host '  ► Invalid selection or out-of-range index, try again.' -ForegroundColor Red
    }
} while (-not $valid)
$selected = $indices | ForEach-Object { $indexedVMs[$_] }

# --- 5. Prompt for tag key/value ---
function Read-ValidInput { param($Prompt,$Max) 
    do {
        $v = Read-Host -Prompt $Prompt
        if ([string]::IsNullOrWhiteSpace($v))         { Write-Host '  ► Cannot be empty.' -ForegroundColor Red }
        elseif ($v.Length -gt $Max)                   { Write-Host "  ► Too long (max $Max)." -ForegroundColor Red }
        else { return $v }
    } while ($true)
}
$tagKey   = Read-ValidInput 'Enter TAG KEY (max 512 chars)' 512
$tagValue = Read-ValidInput 'Enter TAG VALUE (max 256 chars)' 256

# --- 6. Apply tags & collect changes ---
$changes = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($vm in $selected) {
    Write-Host "`nProcessing $($vm.ResourceGroup)/$($vm.Name)..." -ForegroundColor Cyan
    $res     = Get-AzResource -ResourceId $vm.Id -ExpandProperties -ErrorAction Stop
    $oldTags = if ($res.Tags) { $res.Tags } else { @{} }

    if ($oldTags.ContainsKey($tagKey)) {
        Write-Host "  [SKIP] '$tagKey' exists, skipping." -ForegroundColor Yellow
        continue
    }

    try {
        Update-AzTag -ResourceId $vm.Id -Tag @{ $tagKey = $tagValue } -Operation Merge -ErrorAction Stop
        Write-Host '  [OK] Tagged.' -ForegroundColor Green

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
        Write-Host "  [ERR] $_" -ForegroundColor Red
    }
}

# --- 7. Export CSV artifact ---
$ts     = Get-Date -Format 'yyyyMMdd_HHmmss'
$outCsv = "TaggedVMs_$ts.csv"
if ($changes.Count -gt 0) {
    $changes | Export-Csv $outCsv -NoTypeInformation
    Write-Host "`n✅ Change log: $outCsv" -ForegroundColor Green
} else {
    Write-Host "`n⚠️  No VMs were tagged." -ForegroundColor Yellow
}

# --- 8. Generate Undo Script ---
$undo = "UndoTags_$ts.ps1"
$hdr  = "<# Revert tags based on '$outCsv' #>`n"
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
($hdr + $body) | Out-File $undo -Encoding UTF8
Write-Host "`n🔄 Undo script: $undo" -ForegroundColor Green
