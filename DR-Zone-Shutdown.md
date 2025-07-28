# DR-Zone-Shutdown

A PowerShell script to gracefully shutdown (stop or deallocate) Azure VMs by availability zone, non-zonal grouping, all, or a single VM. It also generates a restart script for all VMs that were shut down.

## Features

* **Zone Grouping**: Select VMs by their availability zone.
* **Non-Zonal / All / Specific**: Choose non-zonal VMs, all VMs, or target a specific VM by name.
* **Ephemeral OS Disk Handling**: Automatically stops VMs with ephemeral OS disks and deallocates standard VMs.
* **Restart Script Generation**: After shutdown, a PowerShell script is created to restart the exact VMs you shut down.
* **WhatIf Mode**: Simulate all actions without making changes by passing `-WhatIf`.
* **Azure CLI Login**: Prompts for `az login` if not already authenticated.

## Prerequisites

* [Azure CLI](https://aka.ms/install-azure-cli) (logged in)
* PowerShell 5.1 or newer

## Usage

1. **Clone or download** this repository.
2. **Open PowerShell** and navigate to the script folder.
3. **Run** the script:

   ```powershell
   .\DR-Zone-Shutdown.ps1
   ```
4. **Simulate** without making changes:

   ```powershell
   .\DR-Zone-Shutdown.ps1 -WhatIf
   ```
5. **Follow prompts** to select VMs for shutdown. A restart script (`DR-Zone-Restart-<timestamp>.ps1`) will be generated.

## Notes

* **Initial data collection may take up to 5 minutes** to fetch and group all VMs.
* **Shutdown operations can take up to 5 minutes** per VM—please be patient.

## Example

```powershell
PS C:\temp\DR> .\DR-Zone-Shutdown.ps1

Note: this takes a long time (~5 mins) to collect the initial VM data for the menu
Select an operation mode:
  [1] Shutdown existing VMs by zone/non-zonal/all/specific/none
  [2] Exit

Enter choice (1-2): 1
...
```

## License

MIT Open
