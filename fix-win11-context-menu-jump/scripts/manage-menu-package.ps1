[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory)][ValidateSet('Disable','Restore')][string]$Action,
    [string]$PackageName,
    [string]$InstallerPath,
    [string]$ExternalLocation,
    [Parameter(Mandatory)][string]$BackupDirectory,
    [switch]$MenuOnlyConfirmed,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MenuPackage.psm1') -Force
$backup = [IO.Path]::GetFullPath($BackupDirectory)
$statePath = Join-Path $backup 'state.json'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

if ($Action -eq 'Disable') {
    if (!$PackageName -or $PackageName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') { throw 'Provide one exact package Name, without wildcards.' }
    if (!$MenuOnlyConfirmed) { throw 'First verify this is an independent menu-only sparse package and review ALL menu entries it will remove; then pass -MenuOnlyConfirmed.' }
    $packages = @(Get-AppxPackage -Name $PackageName -ErrorAction Stop | Where-Object { $_.Name -ceq $PackageName })
    if ($packages.Count -ne 1) { throw 'Expected exactly one current-user package. Do not broaden the query or remove all users.' }
    $p = $packages[0]
    $manifest = Join-Path $p.InstallLocation 'AppxManifest.xml'
    $info = Get-MenuManifestInfo -ManifestPath $manifest
    if (!$info.IsMenuOnlySparseCandidate) { throw 'Not an independent sparse desktop-menu candidate. Use the owning application settings instead.' }
    if (!$InstallerPath -or !$ExternalLocation) { throw 'A matching vendor recovery MSIX and its verified external root are required.' }
    $installer = (Get-Item -LiteralPath $InstallerPath -ErrorAction Stop).FullName
    $external = (Get-Item -LiteralPath $ExternalLocation -ErrorAction Stop).FullName
    if (!(Test-Path -LiteralPath $external -PathType Container)) { throw 'ExternalLocation must be an existing directory.' }
    $restoreInfo = Get-MenuInstallerInfo -InstallerPath $installer
    Assert-MenuIdentityMatch -Installed $info -Installer $restoreInfo
    $externalFiles = @(Get-MenuExternalFiles -ManifestInfo $info -ExternalLocation $external)
    if (Test-Path -LiteralPath $backup) { throw 'BackupDirectory already exists. Choose a new directory; never overwrite the original recovery state.' }
    Write-Output ("Target: {0}; removes menu types: {1}" -f $p.PackageFullName, (($info.Verbs.Type | Sort-Object -Unique) -join ', '))
    if (!$Apply) { Write-Output 'Plan only. Pass -Apply after reviewing evidence, side effects, and vendor installer provenance.'; return }
    if (!$PSCmdlet.ShouldProcess($p.PackageFullName, 'Back up and unregister this current-user menu-only package')) { return }
    New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
    $savedInstaller = Join-Path $backup 'installer.msix'
    Copy-Item -LiteralPath $installer -Destination $savedInstaller -ErrorAction Stop
    # Validate the actual recovery copy, not only the source read before copying.
    Assert-MenuIdentityMatch -Installed $info -Installer (Get-MenuInstallerInfo -InstallerPath $savedInstaller)
    Copy-Item -LiteralPath $manifest -Destination (Join-Path $backup 'AppxManifest.xml') -ErrorAction Stop
    $state = [ordered]@{
        Schema=1;Computer=$env:COMPUTERNAME;UserSid=$sid;Name=$p.Name
        PackageFullName=$p.PackageFullName;ExternalLocation=$external
        InstallerSha256=(Get-FileHash -LiteralPath $savedInstaller -Algorithm SHA256).Hash
        Identity=$info;ExternalFiles=$externalFiles;Stage='Prepared';CreatedUtc=[DateTime]::UtcNow.ToString('o')
    }
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
    Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
    if (@(Get-AppxPackage -Name $PackageName -ErrorAction Stop).Count) { throw 'Package remains registered. Keep the backup; do not claim removal succeeded.' }
    $state.Stage = 'Disabled'
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Output "Unregistered. Recovery state: $statePath"
} else {
    $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($state.Schema -ne 1 -or $state.UserSid -ne $sid -or $state.Computer -ne $env:COMPUTERNAME) { throw 'Recovery state must belong to this computer and interactive user.' }
    if ($state.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') { throw 'Invalid recovery package identity.' }
    $installer = Join-Path $backup 'installer.msix'
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $state.InstallerSha256) { throw 'Recovery installer hash mismatch.' }
    Assert-MenuIdentityMatch -Installed $state.Identity -Installer (Get-MenuInstallerInfo -InstallerPath $installer)
    if (!(Test-Path -LiteralPath $state.ExternalLocation -PathType Container)) { throw 'External program root is missing. Restore the owning application first; do not guess a new path.' }
    $externalFiles = @(Get-MenuExternalFiles -ManifestInfo $state.Identity -ExternalLocation $state.ExternalLocation)
    foreach ($savedFile in $state.ExternalFiles) {
        $current = @($externalFiles | Where-Object { $_.Path -ceq $savedFile.Path -and $_.Sha256 -ceq $savedFile.Sha256 })
        if ($current.Count -ne 1) { throw 'External menu DLL changed or is missing. Repair the owning application rather than restoring an incompatible menu package.' }
    }
    $existing = @(Get-AppxPackage -Name $state.Name -ErrorAction Stop)
    if ($existing.Count) {
        if ($existing.Count -eq 1 -and $existing[0].PackageFullName -ceq $state.PackageFullName) { Write-Output 'Original package is registered and checked DLLs match. Menu functionality still needs a cold-start test.'; return }
        throw 'A different package version is registered. Do not downgrade it automatically.'
    }
    if (!$Apply) { Write-Output ('Plan only: restore ' + $state.PackageFullName); return }
    if (!$PSCmdlet.ShouldProcess($state.PackageFullName, 'Restore current-user menu package from verified backup')) { return }
    Add-AppxPackage -Path $installer -ExternalLocation $state.ExternalLocation -ErrorAction Stop
    $restored = @(Get-AppxPackage -Name $state.Name -ErrorAction Stop)
    if ($restored.Count -ne 1 -or $restored[0].PackageFullName -cne $state.PackageFullName) { throw 'Restore registration did not match the saved package.' }
    $state.Stage = 'Restored'
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Output 'Package registration restored; checked DLLs match. Restart Explorer and cold-test the actual menu before claiming functional recovery.'
}
