$vms = Get-AzVM -Status | Where-Object { $_.Zones -contains "3" }

# Display all VMs with their status
$vms | Select-Object Name, ResourceGroupName, Location, Zones, PowerState

# Count powered-on and powered-off VMs
$poweredOnCount = ($vms | Where-Object { $_.PowerState -eq 'VM running' }).Count
$poweredOffCount = ($vms | Where-Object { $_.PowerState -eq 'VM deallocated' -or $_.PowerState -eq 'VM stopped' }).Count

# Output counts with color
Write-Host "`nTotal VMs powered on in Zone 3: $poweredOnCount" -ForegroundColor Green
Write-Host "Total VMs powered off in Zone 3: $poweredOffCount" -ForegroundColor Red
