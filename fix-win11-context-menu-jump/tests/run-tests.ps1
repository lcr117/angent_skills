$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$module = Join-Path $root 'scripts\MenuPackage.psm1'
if (!(Test-Path -LiteralPath $module)) { throw 'RED: menu package implementation is missing.' }
Import-Module $module -Force
$temp = Join-Path ([IO.Path]::GetTempPath()) ('menu-skill-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
$script:passes = 0
function Check($condition, $message) {
    if (!$condition) { throw "FAIL: $message" }
    $script:passes++; Write-Host "PASS: $message"
}
function Must-Throw([scriptblock]$action, [string]$message) {
    $threw = $false
    try { & $action | Out-Null } catch { $threw = $true }
    Check $threw $message
}
try {
    $xml = @'
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:d="http://schemas.microsoft.com/appx/manifest/desktop/windows10/5" xmlns:u="http://schemas.microsoft.com/appx/manifest/uap/windows10/10">
 <Identity Name="Fabrikam.DesktopHints" Version="1.0.0.0" Publisher="CN=Fixture" ProcessorArchitecture="neutral"/>
 <Properties><u:AllowExternalContent>true</u:AllowExternalContent></Properties>
 <Applications><Application Id="Menu" Executable="menu.exe"><Extensions>
  <d:Extension Category="windows.fileExplorerContextMenus"><d:FileExplorerContextMenus>
   <d:ItemType Type="Directory\Background"><d:Verb Id="Menu" Clsid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"/></d:ItemType>
   <d:ItemType Type="*"><d:Verb Id="File" Clsid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"/></d:ItemType>
  </d:FileExplorerContextMenus></d:Extension>
  <d:Extension Category="windows.comServer"><d:ComServer><d:Class Id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" Path="menu.dll"/></d:ComServer></d:Extension>
 </Extensions></Application></Applications>
</Package>
'@
    $manifest = Join-Path $temp 'AppxManifest.xml'
    [IO.File]::WriteAllText($manifest, $xml)
    [IO.File]::WriteAllText((Join-Path $temp 'menu.dll'), 'fixture binary')
    $info = Get-MenuManifestInfo -ManifestPath $manifest
    Check ($info.Name -eq 'Fabrikam.DesktopHints') 'reads identity independently of namespace prefixes'
    Check ($info.BackgroundVerbs.Count -eq 1) 'only explicit desktop-background types are candidates'
    Check ($info.Verbs.Count -eq 2) 'records file-menu side effects too'
    Check ($info.IsMenuOnlySparseCandidate) 'recognizes independent sparse menu candidate'
    $files = @(Get-MenuExternalFiles -ManifestInfo $info -ExternalLocation $temp)
    Check ($files.Count -eq 1 -and $files[0].Sha256) 'checks external menu DLL and records its hash'
    $info.BackgroundDllPaths = @('..\escape.dll')
    Must-Throw { Get-MenuExternalFiles -ManifestInfo $info -ExternalLocation $temp } 'rejects external DLL paths escaping the verified root'
    $info.BackgroundDllPaths = @('missing.dll')
    Must-Throw { Get-MenuExternalFiles -ManifestInfo $info -ExternalLocation $temp } 'rejects absent external DLL before unregister'
    $mixed = $xml.Replace('<d:Verb Id="Menu"', '<d:Verb Id="Unresolved" Clsid="11111111-2222-3333-4444-555555555555"/><d:Verb Id="Menu"')
    [IO.File]::WriteAllText($manifest, $mixed)
    $mixedInfo = Get-MenuManifestInfo -ManifestPath $manifest
    Must-Throw { Get-MenuExternalFiles -ManifestInfo $mixedInfo -ExternalLocation $temp } 'rejects partially resolved background COM declarations'
    [IO.File]::WriteAllText($manifest, $xml)
    $info = Get-MenuManifestInfo -ManifestPath $manifest
    [IO.File]::WriteAllText($manifest, $xml.Replace('Directory\Background', 'Directory'))
    $fileOnly = Get-MenuManifestInfo -ManifestPath $manifest
    Check ($fileOnly.BackgroundVerbs.Count -eq 0) 'file wildcard and Directory do not imply desktop-background registration'
    Check $fileOnly.IsMenuOnlyCandidate 'file-only sparse menu component remains eligible for explicit All surface'
    Check (@(Get-MenuExternalFiles -ManifestInfo $fileOnly -ExternalLocation $temp -Surface All).Count -eq 1) 'verifies DLL paths for file-only components'
    [IO.File]::WriteAllText($manifest, $xml.Replace('</Extensions>', '<d:Extension Category="windows.cloudFiles"/></Extensions>'))
    Check (!(Get-MenuManifestInfo -ManifestPath $manifest).IsMenuOnlyCandidate) 'cloud-files integration prevents whole-package removal for all surfaces'
    [IO.File]::WriteAllText($manifest, $xml.Replace('</Extensions>', '<d:Extension Category="windows.startupTask"/></Extensions>'))
    Check (!(Get-MenuManifestInfo -ManifestPath $manifest).IsMenuOnlySparseCandidate) 'rejects packages with non-menu integration'
    [IO.File]::WriteAllText($manifest, $xml.Replace('<u:AllowExternalContent>true</u:AllowExternalContent>', ''))
    Check (!(Get-MenuManifestInfo -ManifestPath $manifest).IsMenuOnlySparseCandidate) 'rejects full app packages'
    [IO.File]::WriteAllText($manifest, '<!DOCTYPE x [<!ENTITY a SYSTEM "file:///C:/Windows/win.ini">]><Package>&a;</Package>')
    Must-Throw { Get-MenuManifestInfo -ManifestPath $manifest } 'refuses XML external entities'
    [IO.File]::WriteAllText($manifest, $xml)
    $zipPath = Join-Path $temp 'fixture.msix'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        $entry = $zip.CreateEntry('AppxManifest.xml')
        $writer = New-Object IO.StreamWriter($entry.Open())
        try { $writer.Write($xml) } finally { $writer.Dispose() }
        $null = $zip.CreateEntry('AppxSignature.p7x')
    } finally { $zip.Dispose() }
    $archive = Get-MenuInstallerInfo -InstallerPath $zipPath
    Check ($archive.Name -eq $info.Name) 'reads MSIX identity without extracting or running it'
    Assert-MenuIdentityMatch -Installed $info -Installer $archive
    Check $true 'accepts matching identity'
    $archive.Version = '2.0.0.0'
    Must-Throw { Assert-MenuIdentityMatch -Installed $info -Installer $archive } 'rejects version-mismatched recovery installers'

    # Mock OS package cmdlets: exercise lifecycle control without changing this PC.
    $script:removed = 0; $script:added = 0
    $script:installed = $true
    $script:fakePackage = [pscustomobject]@{Name=$info.Name;PackageFullName='Fabrikam.DesktopHints_1.0.0.0_neutral__fixture';InstallLocation=$temp}
    $global:MenuSkillTestRuntime = @{Installed=$true;Removed=0;Added=0;Package=$script:fakePackage}
    function global:Get-AppxPackage { param($Name) if ($global:MenuSkillTestRuntime.Installed -and $Name -eq $global:MenuSkillTestRuntime.Package.Name) { $global:MenuSkillTestRuntime.Package } }
    function global:Remove-AppxPackage { param($Package) $global:MenuSkillTestRuntime.Removed++; $global:MenuSkillTestRuntime.Installed = $false }
    function global:Add-AppxPackage { param($Path,$ExternalLocation) $global:MenuSkillTestRuntime.Added++; $global:MenuSkillTestRuntime.Installed = $true }
    $state = Join-Path $temp 'backup'
    $lifecycle = Join-Path $root 'scripts\manage-menu-package.ps1'
    & $lifecycle -Action Disable -PackageName $info.Name -InstallerPath $zipPath -ExternalLocation $temp -BackupDirectory $state -MenuOnlyConfirmed -Apply -WhatIf
    Check ($global:MenuSkillTestRuntime.Removed -eq 0 -and !(Test-Path -LiteralPath $state)) 'WhatIf performs no removal or backup writes'
    & $lifecycle -Action Disable -PackageName $info.Name -InstallerPath $zipPath -ExternalLocation $temp -BackupDirectory $state -MenuOnlyConfirmed
    Check ($global:MenuSkillTestRuntime.Removed -eq 0 -and !(Test-Path -LiteralPath $state)) 'default plan performs no removal or backup writes'
    Must-Throw { & $lifecycle -Action Disable -PackageName $info.Name -InstallerPath $zipPath -ExternalLocation $temp -BackupDirectory $state -Confirm:$false } 'requires explicit menu-only classification'
    Must-Throw { & $lifecycle -Action Disable -PackageName 'Fabrikam.*' -InstallerPath $zipPath -ExternalLocation $temp -BackupDirectory $state -MenuOnlyConfirmed -Confirm:$false } 'rejects wildcard targeting'
    & $lifecycle -Action Disable -PackageName $info.Name -InstallerPath $zipPath -ExternalLocation $temp -BackupDirectory $state -MenuOnlyConfirmed -Apply -Confirm:$false
    Check ($global:MenuSkillTestRuntime.Removed -eq 1 -and (Test-Path -LiteralPath (Join-Path $state 'state.json'))) 'backs up before exact per-user unregister'
    [IO.File]::WriteAllText((Join-Path $temp 'menu.dll'), 'updated binary')
    Must-Throw { & $lifecycle -Action Restore -BackupDirectory $state -Apply -Confirm:$false } 'refuses restoration against changed external DLLs'
    [IO.File]::WriteAllText((Join-Path $temp 'menu.dll'), 'fixture binary')
    & $lifecycle -Action Restore -BackupDirectory $state -Apply -Confirm:$false
    Check ($global:MenuSkillTestRuntime.Added -eq 1 -and $global:MenuSkillTestRuntime.Installed) 'restores using backed-up installer and external root'
    $global:MenuSkillTestRuntime.Installed = $false
    Add-Content -LiteralPath (Join-Path $state 'installer.msix') -Value 'tampered'
    Must-Throw { & $lifecycle -Action Restore -BackupDirectory $state -Apply -Confirm:$false } 'rejects modified recovery installer'
    Check ($global:MenuSkillTestRuntime.Added -eq 1) 'failed restore validation never installs'
    Write-Host "$script:passes checks passed. No live packages changed."
} finally {
    foreach ($name in @('Get-AppxPackage','Remove-AppxPackage','Add-AppxPackage')) { Remove-Item -LiteralPath "Function:\global:$name" -ErrorAction SilentlyContinue }
    $fullTemp = [IO.Path]::GetFullPath($temp)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$fullTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test directory.' }
    Remove-Item -LiteralPath $fullTemp -Recurse -Force
}
