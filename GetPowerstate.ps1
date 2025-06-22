Get-AzVM -Status | Where-Object { $_.Zones -contains "3" } | Select-Object Name, ResourceGroupName, Location, Zones, PowerState



