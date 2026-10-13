[CmdletBinding()]
param(
    [string]$StatePath = (Join-Path $env:USERPROFILE '.codex\proxy-skill-state'),
    [string]$RegistryStatePath
)

$ErrorActionPreference = 'Stop'
$internetSettings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$latest = Join-Path $StatePath 'latest.txt'

function Restore-ProxyState($State) {
    if ($RegistryStatePath) {
        $State | ConvertTo-Json | Set-Content -LiteralPath $RegistryStatePath -Encoding utf8
        return
    }
    if ($null -eq $State.ProxyEnable) { Remove-ItemProperty -Path $internetSettings -Name ProxyEnable -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -Path $internetSettings -Name ProxyEnable -Type DWord -Value ([int]$State.ProxyEnable) }
    if ($null -eq $State.ProxyServer) { Remove-ItemProperty -Path $internetSettings -Name ProxyServer -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -Path $internetSettings -Name ProxyServer -Value ([string]$State.ProxyServer) }
    if ($null -eq $State.ProxyOverride) { Remove-ItemProperty -Path $internetSettings -Name ProxyOverride -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -Path $internetSettings -Name ProxyOverride -Value ([string]$State.ProxyOverride) }
}

if (-not (Test-Path -LiteralPath $latest -PathType Leaf)) {
    Write-Error "No rollback pointer found at $latest; no changes were made."
    exit 2
}
$stateFile = (Get-Content -LiteralPath $latest -Raw).Trim()
if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
    Write-Error "Rollback state is missing: $stateFile"
    exit 3
}

try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json }
catch { Write-Error "Rollback state is invalid: $($_.Exception.Message)"; exit 4 }
$stateProperties = @($state.PSObject.Properties.Name)
if (-not ($stateProperties -contains 'ConfigPath') -or -not ($stateProperties -contains 'ConfigBackup') -or -not ($stateProperties -contains 'ProxyState') -or
    $state.ConfigPath -isnot [string] -or $state.ConfigBackup -isnot [string] -or $state.ProxyState -isnot [pscustomobject]) {
    Write-Error 'Rollback state is incomplete; no changes were made.'
    exit 4
}
$proxyProperties = @($state.ProxyState.PSObject.Properties.Name)
if (@('ProxyEnable','ProxyServer','ProxyOverride') | Where-Object { $proxyProperties -notcontains $_ }) {
    Write-Error 'Rollback proxy state is incomplete; no changes were made.'
    exit 4
}
$validEnable = $null -eq $state.ProxyState.ProxyEnable -or $state.ProxyState.ProxyEnable -in @(0,1)
$validServer = $null -eq $state.ProxyState.ProxyServer -or $state.ProxyState.ProxyServer -is [string]
$validOverride = $null -eq $state.ProxyState.ProxyOverride -or $state.ProxyState.ProxyOverride -is [string]
if (-not ($validEnable -and $validServer -and $validOverride)) {
    Write-Error 'Rollback proxy state has invalid value types; no changes were made.'
    exit 4
}
if (-not (Test-Path -LiteralPath $state.ConfigBackup -PathType Leaf)) {
    Write-Error "Config backup is missing: $($state.ConfigBackup)"
    exit 4
}

try {
    Copy-Item -LiteralPath $state.ConfigBackup -Destination $state.ConfigPath -Force
    Restore-ProxyState $state.ProxyState
}
catch {
    Write-Error "Rollback failed: $($_.Exception.Message)"
    exit 5
}

Write-Host 'Restored the previous Codex config and current-user proxy settings.'
Write-Host 'Fully exit and restart Codex before testing.'
exit 0

