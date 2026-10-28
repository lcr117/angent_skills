# Read-only inventory. Emits objects; pipe to ConvertTo-Json to save locally.
[CmdletBinding()]
param([switch]$BackgroundOnly)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MenuPackage.psm1') -Force
try { $packages = @(Get-AppxPackage -ErrorAction Stop) }
catch { throw 'Cannot read Appx inventory. Use Windows PowerShell in the interactive user session; request the needed execution permission, then retry. Do not interpret access denied as no extensions.' }
$inspectionFailures = @()
foreach ($p in $packages) {
    $manifest = Join-Path $p.InstallLocation 'AppxManifest.xml'
    try { $info = Get-MenuManifestInfo -ManifestPath $manifest }
    catch {
        $inspectionFailures += $p.Name
        [pscustomobject]@{Name=$p.Name;PackageFullName=$p.PackageFullName;InspectionError=$_.Exception.Message}
        continue
    }
    if (!$info.Verbs.Count -or ($BackgroundOnly -and !$info.BackgroundVerbs.Count)) { continue }
    $repository = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages\' + $p.PackageFullName
    $root = $null
    try { $root = Get-ItemPropertyValue -LiteralPath $repository -Name PackageRootFolder -ErrorAction Stop } catch { }
    [pscustomobject]@{
        Name=$p.Name;PackageFullName=$p.PackageFullName;Status=[string]$p.Status
        InstallLocation=$p.InstallLocation;ExternalRootHint=$root
        BackgroundVerbs=$info.BackgroundVerbs;AllVerbs=$info.Verbs;BackgroundDllPaths=$info.BackgroundDllPaths
        IsMenuOnlySparseCandidate=$info.IsMenuOnlySparseCandidate
        IsMenuOnlyCandidate=$info.IsMenuOnlyCandidate
        ExtensionCategories=$info.ExtensionCategories
        MenuDllPaths=$info.MenuDllPaths
    }
}
if ($inspectionFailures.Count) { throw ('Inventory incomplete; inspect the emitted InspectionError records. Unreadable packages: ' + ($inspectionFailures -join ', ')) }
