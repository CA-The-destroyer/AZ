<#
.SYNOPSIS
  CLI-only interactive script to tag one or more Azure VMs and record what changed, plus generate an undo script.

.DESCRIPTION
  1. Ensures Az modules are installed & imported.
  2. Prompts to login (if not already) and choose an Azure subscription by number (with re-login if needed).
  3. Lists all VMs in that subscription and lets you pick one or more by number (comma-separated).
  4. Prompts (with validation) for a tag key (max 512 chars) and value (max 256 chars).
  5. Merges that tag onto each selected VM, logging success or errors.
  6. Exports a CSV artifact (`TaggedVMs_<timestamp>.csv`) listing for each VM:
     – ResourceGroup, VMName, ResourceId  
     – OldTags, NewTags  
  7. Generates an undo-script (`UndoTags_<timestamp>.ps1`) that reverts all those tag changes.
#>

# --- 1. Ensure modules & login ---
if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Write-Host 'Installing Az modules…' -ForegroundColor Yellow
    Install-Module -Name Az -Scope CurrentUser -Force
}
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

if (-not (Get-AzContext)) {
    Write-Host 'Logging in to Azure…' -ForegroundColor Cyan
    Connect-AzAccount -ErrorAction Stop
}

# --- 2. Choose Subscription ---
$subs = Get-AzSubscription -ErrorAction SilentlyContinue
if (-not $subs -or $subs.Count -eq 0) {
    Write-Host 'No subscriptions found. Re-logging in…' -ForegroundColor Yellow
    Connect-AzAccount -ErrorAction Stop
    $subs = Get-AzSubscription -ErrorAction Stop
    if (-not $subs -or $subs.Count -eq 0) {
        Write-Error 'Still no subscriptions returned. Check your Azure login and RBAC permissions.'
        exit 1
    }
}

Write-Host ''
Write-Host 'Available Subscriptions:' -ForegroundColor Cyan
for ($i = 0; $i -lt $subs.Count; $i++) {
    Write-Host "  [$i] $($subs[$i].Name) ($($subs[$i].Id))"
}
do {
    $sel = Read-Host 'Enter the number of the subscription to use'
} while (
    -not ([int]::TryParse($sel, [ref]$null) -and $sel -ge 0 -and $sel -lt $subs.Count)
)

$sub = $subs[$sel]
Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop
Write-Host ''
Write-Host "-> Using subscription: $($sub.Name)" -ForegroundColor Green

# --- 3. Discover & select VMs ---
$vms = Get-AzVM -ErrorAction Stop | Select-Object Name, ResourceGroupName, Id
if ($vms.Count -eq 0) {
    Write-Error "No VMs found in subscription $($sub.Name). Exiting."
    exit 1
}

Write-Host ''
Write-Host 'Available VMs:' -ForegroundColor Cyan
for ($i = 0; $i -lt $vms.Count; $i++) {
    $vm = $vms[$i]
    Write-Host "  [$i] $($vm.ResourceGroupName)/$($vm.Name)"
}
Write-Host 'You may tag multiple VMs—enter their numbers comma-separated (e.g. 0,2,5).'

do {
    $input = Read-Host 'Enter VM numbers to tag'
    $indices = $input -split ',' |
               ForEach-Object { $_.Trim() } |
               Where-Object { $_ -match '^\d+$' } |
               ForEach-Object { [int]$_ }
    $valid = $indices.Count -gt 0 -and
             ($indices | Where-Object { $_ -lt 0 -or $_ -ge $vms.Count }).Count -eq 0
    if (-not $valid) {
        Write-Host '  ► Invalid selection, try again.' -ForegroundColor Red
    }
} while (-not $valid)

$selectedVMs = $indices | ForEach-Object { $vms[$_] }

# --- 4. Prompt with validation ---
function Read-ValidInput {
    param(
        [string]$Prompt,
        [int]   $MaxLength
    )
    do {
        $val = Read-Host -Prompt $Prompt
        if ([string]::IsNullOrWhiteSpace($val)) {
            Write-Host '  ► Input cannot be empty.' -ForegroundColor Red
        }
        elseif ($val.Length -gt $MaxLength) {
            Write-Host "  ► Too long (max $MaxLength chars)." -ForegroundColor Red
        }
        else {
            return $val
        }
    } while ($true)
}

$tagKey   = Read-ValidInput 'Enter TAG KEY (max 512 chars)' 512
$tagValue = Read-ValidInput 'Enter TAG VALUE (max 256 chars)' 256

# --- 5. Apply tags & collect change info ---
$changes = @()
foreach ($vmMeta in $selectedVMs) {
    $rg   = $vmMeta.ResourceGroupName
    $name = $vmMeta.Name
    $id   = $vmMeta.Id

    Write-Host ''
    Write-Host "Tagging $rg/$name..." -ForegroundColor Cyan

    # fetch old tags
    $res     = Get-AzResource -ResourceId $id -ExpandProperties -ErrorAction Stop
    $oldTags = if ($res.Tags) { $res.Tags } else { @{} }
    
    try {
        Update-AzTag `
          -ResourceId $id `
          -Tag @{ $tagKey = $tagValue } `
          -Operation Merge -ErrorAction Stop

        Write-Host '  [OK] Tagged successfully.' -ForegroundColor Green

        # fetch new tags
        $resNew  = Get-AzResource -ResourceId $id -ExpandProperties -ErrorAction Stop
        $newTags = if ($resNew.Tags) { $resNew.Tags } else { @{} }

        # record the change
        $changes += [PSCustomObject]@{
            ResourceGroup = $rg
            VMName        = $name
            ResourceId    = $id
            OldTags       = ($oldTags | ConvertTo-Json -Compress)
            NewTags       = ($newTags | ConvertTo-Json -Compress)
        }
    }
    catch {
        Write-Host "  [ERR] Failed to tag $name" -ForegroundColor Red
        Write-Host "         $_" -ForegroundColor Red
    }
}

# --- 6. Export artifact ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outFile   = "TaggedVMs_$timestamp.csv"

if ($changes.Count -gt 0) {
    $changes | Export-Csv -Path $outFile -NoTypeInformation
    Write-Host ''
    Write-Host "✅ Changes exported to $outFile" -ForegroundColor Green
}
else {
    Write-Host ''
    Write-Host 'No successful tag changes to export.' -ForegroundColor Yellow
}

# --- 7. Generate Undo Script ---
$undoFile = "UndoTags_$timestamp.ps1"

# header with interpolation of the CSV filename
$header = @"
<# Undo Tagging Script
   This script reverts VM tags based on the CSV artifact '$outFile'
#>
"@

# body (single-quoted here-string to prevent interpolation)
$body = @'
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

if (-not (Get-AzContext)) {
    Connect-AzAccount -ErrorAction Stop
}

$changes = Import-Csv -Path 'PLACEHOLDER_CSV'

foreach ($c in $changes) {
    $id      = $c.ResourceId
    $oldTags = $c.OldTags | ConvertFrom-Json
    Write-Host "Reverting tags for $($c.VMName) ($id)..." -ForegroundColor Cyan
    try {
        Update-AzTag -ResourceId $id -Tag $oldTags -Operation Replace -ErrorAction Stop
        Write-Host "  [OK] Reverted tags for $($c.VMName)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERR] Failed to revert tags for $($c.VMName): $_" -ForegroundColor Red
    }
}
'@

# replace placeholder with actual CSV name, assemble, and write
$body        = $body -replace 'PLACEHOLDER_CSV', $outFile
$undoContent = $header + "`n" + $body
$undoContent | Out-File -FilePath $undoFile -Encoding UTF8

Write-Host ''
Write-Host "🔄 Undo script generated: $undoFile" -ForegroundColor Green
