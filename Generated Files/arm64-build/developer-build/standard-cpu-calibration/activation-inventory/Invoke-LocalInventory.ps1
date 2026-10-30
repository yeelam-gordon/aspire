[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
. (Join-Path $PSScriptRoot 'Inventory.ps1')
# Separate read-only local adapter, not an override of the hosted guard.
Invoke-ActivationInventory ([IO.Path]::GetFullPath($Output))
