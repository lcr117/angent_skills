[CmdletBinding()]
param(
    [string]$ProxyHost = '127.0.0.1',
    [ValidateRange(1, 65535)]
    [int]$ProxyPort = 7890,
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),
    [string]$StatePath = (Join-Path $env:USERPROFILE '.codex\proxy-skill-state'),
    [string]$RegistryStatePath,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$internetSettings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Test-ProxyPort([string]$HostName, [int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait(1500)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-UpdatedConfig([string]$Content) {
    if ($Content -match '(?m)^\s*(?:features|"features"|''features'')\s*=') {
        throw 'Inline or keyed features definitions are unsupported; refusing an ambiguous edit.'
    }
    $headerCandidates = [regex]::Matches($Content, '(?m)^\s*\[.*$')
    $headers = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $headerCandidates) {
        $line = $candidate.Value.TrimEnd("`r", "`n")
        if ($line -notmatch '^\s*(\[\[[^\r\n]+\]\]|\[[^\r\n]+\])\s*(?:#.*)?$') {
            throw "Malformed TOML table header: $line"
        }
        $token = $Matches[1]
        $isArray = $token.StartsWith('[[')
        $inner = if ($isArray) { $token.Substring(2, $token.Length - 4).Trim() } else { $token.Substring(1, $token.Length - 2).Trim() }
        if ($inner -in @('"features"', "'features'") -or $inner -match '^features\s*\.') {
            throw "Unsupported features table syntax: $token"
        }
        if ($isArray -and $inner -eq 'features') { throw 'Array-of-tables [[features]] is unsupported.' }
        $headers.Add([pscustomobject]@{ Match=$candidate; Token=$token; Inner=$inner; IsArray=$isArray })
    }
    $featureHeaders = @($headers | Where-Object { -not $_.IsArray -and $_.Inner -ceq 'features' })
    if ($featureHeaders.Count -gt 1) { throw 'Multiple [features] tables found; refusing an ambiguous edit.' }

    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($featureHeaders.Count -eq 0) {
        $separator = if ($Content.Length -eq 0 -or $Content.EndsWith($newline)) { '' } else { $newline }
        return $Content + $separator + $newline + '[features]' + $newline + 'respect_system_proxy = true' + $newline
    }

    $target = $featureHeaders[0]
    $sectionStart = $target.Match.Index
    $afterHeader = $target.Match.Index + $target.Match.Length
    $nextHeader = @($headers | Where-Object { $_.Match.Index -gt $target.Match.Index } | Sort-Object { $_.Match.Index } | Select-Object -First 1)
    $sectionEnd = if ($nextHeader.Count) { $nextHeader[0].Match.Index } else { $Content.Length }
    $section = $Content.Substring($sectionStart, $sectionEnd - $sectionStart)
    if ($section -match '(?m)^\s*(?:"respect_system_proxy"|''respect_system_proxy'')\s*=') {
        throw 'Quoted respect_system_proxy keys are unsupported; refusing an ambiguous edit.'
    }
    $settingMatches = [regex]::Matches($section, '(?m)^\s*respect_system_proxy\s*=.*$')
    if ($settingMatches.Count -gt 1) { throw 'Multiple respect_system_proxy settings found; refusing an ambiguous edit.' }

    if ($settingMatches.Count -eq 1) {
        $match = $settingMatches[0]
        return $Content.Substring(0, $sectionStart + $match.Index) + 'respect_system_proxy = true' + $Content.Substring($sectionStart + $match.Index + $match.Length)
    }

    $insertAt = $afterHeader
    return $Content.Substring(0, $insertAt) + $newline + 'respect_system_proxy = true' + $Content.Substring($insertAt)
}

function Get-ProxyState {
    if ($RegistryStatePath) {
        if (Test-Path -LiteralPath $RegistryStatePath) { return Get-Content -LiteralPath $RegistryStatePath -Raw | ConvertFrom-Json }
        return [pscustomobject]@{ ProxyEnable = $null; ProxyServer = $null; ProxyOverride = $null }
    }
    $item = Get-ItemProperty -Path $internetSettings -ErrorAction Stop
    return [pscustomobject]@{
        ProxyEnable = $item.ProxyEnable
        ProxyServer = $item.ProxyServer
        ProxyOverride = $item.ProxyOverride
    }
}

function Set-ProxyState($State) {
    if ($RegistryStatePath) {
        $parent = Split-Path -Parent $RegistryStatePath
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $State | ConvertTo-Json | Set-Content -LiteralPath $RegistryStatePath -Encoding utf8
        return
    }
    Set-ItemProperty -Path $internetSettings -Name ProxyEnable -Type DWord -Value ([int]$State.ProxyEnable)
    Set-ItemProperty -Path $internetSettings -Name ProxyServer -Value ([string]$State.ProxyServer)
    if ($null -eq $State.ProxyOverride) {
        Remove-ItemProperty -Path $internetSettings -Name ProxyOverride -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -Path $internetSettings -Name ProxyOverride -Value ([string]$State.ProxyOverride)
    }
}

function Restore-ProxyState($State, [bool]$FixtureExisted) {
    if ($RegistryStatePath) {
        if ($FixtureExisted) {
            $State | ConvertTo-Json | Set-Content -LiteralPath $RegistryStatePath -Encoding utf8
        } else {
            Remove-Item -LiteralPath $RegistryStatePath -Force -ErrorAction SilentlyContinue
        }
        return
    }
    foreach ($name in @('ProxyEnable','ProxyServer','ProxyOverride')) {
        $value = $State.$name
        if ($null -eq $value) { Remove-ItemProperty -Path $internetSettings -Name $name -ErrorAction SilentlyContinue }
        elseif ($name -eq 'ProxyEnable') { Set-ItemProperty -Path $internetSettings -Name $name -Type DWord -Value ([int]$value) }
        else { Set-ItemProperty -Path $internetSettings -Name $name -Value ([string]$value) }
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Error "Codex config not found: $ConfigPath"
    exit 2
}
if (-not (Test-ProxyPort $ProxyHost $ProxyPort)) {
    Write-Error "Proxy is not reachable at ${ProxyHost}:$ProxyPort; no changes were made."
    exit 3
}

$originalConfig = Get-Content -LiteralPath $ConfigPath -Raw
try { $updatedConfig = Get-UpdatedConfig $originalConfig }
catch { Write-Error $_; exit 4 }
$registryStateFileExisted = [bool]($RegistryStatePath -and (Test-Path -LiteralPath $RegistryStatePath -PathType Leaf))
$originalProxy = Get-ProxyState
$desiredProxy = [pscustomobject]@{
    ProxyEnable = 1
    ProxyServer = "${ProxyHost}:$ProxyPort"
    ProxyOverride = $originalProxy.ProxyOverride
}

Write-Host "Proxy listener: ${ProxyHost}:$ProxyPort"
Write-Host "Codex config: $ConfigPath"
Write-Host 'Codex feature: respect_system_proxy = true'
if (-not $Apply) {
    Write-Host 'Dry run only. Re-run with -Apply after explicit authorization.'
    exit 0
}

$proxyAlreadySet = ([int]$originalProxy.ProxyEnable -eq 1 -and [string]$originalProxy.ProxyServer -ceq "${ProxyHost}:$ProxyPort")
if ($updatedConfig -ceq $originalConfig -and $proxyAlreadySet) {
    Write-Host 'Already configured; existing rollback baseline was preserved.'
    exit 0
}

$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$recordDir = Join-Path $StatePath $stamp
$configBackup = Join-Path $recordDir 'config.toml.before'
$stateFile = Join-Path $recordDir 'state.json'

try {
    New-Item -ItemType Directory -Path $recordDir -Force | Out-Null
    Copy-Item -LiteralPath $ConfigPath -Destination $configBackup
    [pscustomobject]@{
        ConfigPath = $ConfigPath
        ConfigBackup = $configBackup
        RegistryStatePath = $RegistryStatePath
        RegistryStateFileExisted = $registryStateFileExisted
        ProxyState = $originalProxy
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding utf8
    Set-Content -LiteralPath $ConfigPath -Value $updatedConfig -NoNewline -Encoding utf8
    Set-ProxyState $desiredProxy
    Set-Content -LiteralPath (Join-Path $StatePath 'latest.txt') -Value $stateFile -NoNewline -Encoding utf8
}
catch {
    $applyError = $_.Exception.Message
    $restoreErrors = [System.Collections.Generic.List[string]]::new()
    try { if (Test-Path -LiteralPath $configBackup) { Copy-Item -LiteralPath $configBackup -Destination $ConfigPath -Force } } catch { $restoreErrors.Add("config: $($_.Exception.Message)") }
    try { Restore-ProxyState $originalProxy $registryStateFileExisted } catch { $restoreErrors.Add("proxy: $($_.Exception.Message)") }
    if ($restoreErrors.Count -eq 0) {
        Write-Error "Apply failed; prior state was restored. Backup: $configBackup. Cause: $applyError"
    } else {
        Write-Error "Apply failed; restoration incomplete. Backup: $configBackup. Cause: $applyError. Restore errors: $($restoreErrors -join '; ')"
    }
    exit 5
}

Write-Host "Applied system proxy ${ProxyHost}:$ProxyPort without TUN."
Write-Host 'Fully exit and restart Codex before testing a new chat.'
exit 0


