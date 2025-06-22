$vms = Get-AzVM -Status | Where-Object { $_.Zones -contains "3" }
$vms | Select-Object Name, ResourceGroupName, Location, Zones, PowerState
Write-Host "`nTotal VMs powered on in Zone 3: " ($vms | Where-Object { $_.PowerState -eq 'VM running' }).Count -ForegroundColor Green
