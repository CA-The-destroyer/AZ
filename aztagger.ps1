<#
.SYNOPSIS
  Interactive script to tag one or more Azure VMs.

.DESCRIPTION
  1. Ensures Az modules are installed & imported.
  2. Prompts to login (if not already) and choose an Azure subscription.
  3. Discovers all VMs in that subscription and lets you pick via Out-GridView.
  4. Prompts (with validation) for a tag key (max 512 chars) and value (max 256 chars).
  5. Merges that tag onto each selected VM, logging success or errors.
#>

# --- 1. Ensure modules & login ---
if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Write-Host "Az.Resources module not found. Installing Az modules…" -ForegroundColor Yellow
    Install-Module -Name Az -Scope CurrentUser -Force
}
Import-Module Az.Accounts
Import-Module Az.Resources

if (-not (Get-AzContext)) {
    Write-Host "Logging in to Azure…" -ForegroundColor Cyan
    Connect-AzAccount -ErrorAction Stop
}

# --- 2. Choose Subscription ---
$subscription = Get-AzSubscription |
    Out-GridView -Title "Select an Azure Subscription" -PassThru
if (-not $subscription) {
    Write-Error "No subscription selected. Exiting."
    exit 1
}
Set-AzContext -SubscriptionId $subscription.Id

# --- 3. Discover & select VMs ---
$vms = Get-AzVM
if (-not $vms) {
    Write-Error "No virtual machines found in this subscription."
    exit 1
}
$selectedVMs = $vms |
    Select-Object Name, ResourceGroupName, Id |
    Out-GridView -Title "Select VM(s) to Tag (Ctrl+Click for multiple)" -PassThru -OutputMode Multiple
if (-not $selectedVMs) {
    Write-Error "No VMs selected. Exiting."
    exit 1
}

# --- 4. Prompt with validation ---
function Read-ValidInput {
    param(
        [string]$Prompt,
        [int]   $MaxLength
    )
    do {
        $val = Read-Host -Prompt $Prompt
        if ([string]::IsNullOrWhiteSpace($val)) {
            Write-Host "  ► Input cannot be empty." -ForegroundColor Red
        }
        elseif ($val.Length -gt $MaxLength) {
            Write-Host "  ► Too long (max $MaxLength chars)." -ForegroundColor Red
        }
        else {
            return $val
        }
    } while ($true)
}

$tagKey   = Read-ValidInput -Prompt "Enter TAG KEY (max 512 chars)" -MaxLength 512
$tagValue = Read-ValidInput -Prompt "Enter TAG VALUE (max 256 chars)" -MaxLength 256

# --- 5. Apply tags ---
foreach ($vm in $selectedVMs) {
    Write-Host "Tagging VM '$($vm.Name)' (RG: $($vm.ResourceGroupName))…" -ForegroundColor Cyan
    try {
        Update-AzTag `
          -ResourceId $vm.Id `
          -Tag @{ $tagKey = $tagValue } `
          -Operation Merge `
          -Force
        Write-Host "  ✔ Success" -ForegroundColor Green
    }
    catch {
        Write-Host "  ✖ Failed: $_" -ForegroundColor Red
    }
}
