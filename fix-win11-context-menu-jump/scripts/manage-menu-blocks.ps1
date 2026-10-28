[CmdletBinding(SupportsShouldProcess=$true)]
param(
 [Parameter(Mandatory)][ValidateSet('Block','Restore')][string]$Action,
 [string]$PackageName,[string[]]$Clsid,
 [ValidateSet('CurrentUser','LocalMachine')][string]$Scope='CurrentUser',
 [Parameter(Mandatory)][string]$BackupFile,
 [switch]$Apply,[switch]$MachineScopeConfirmed
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'MenuPackage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MenuBlocks.psm1') -Force
$options=@{BackupFile=$BackupFile;Apply=$Apply;WhatIf=[bool]$WhatIfPreference}
if($Action -eq 'Restore'){Restore-MenuBlockChange @options;return}
if(!$PackageName -or $PackageName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$'){throw 'Specify one exact package name; no wildcard targeting.'}
if(!$Clsid -or !$Clsid.Count){throw 'Select exact CLSIDs from this installed package manifest.'}
$packages=@(Get-AppxPackage -Name $PackageName -ErrorAction Stop|Where-Object {$_.Name -ceq $PackageName})
if($packages.Count -ne 1){throw 'Expected one current-user package.'}
$info=Get-MenuManifestInfo -ManifestPath (Join-Path $packages[0].InstallLocation 'AppxManifest.xml')
$plan=New-MenuBlockPlan -ManifestInfo $info -Clsid $Clsid -Scope $Scope
$plan.Verbs|Where-Object {('{'+$_.Clsid.Trim('{}')+'}') -in $plan.Entries.Name}|Format-Table Type,Id,Clsid -AutoSize|Out-Host
Invoke-MenuBlockChange -Plan $plan @options -MachineScopeConfirmed:$MachineScopeConfirmed
