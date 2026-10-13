$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$configureScript = Join-Path $skillRoot 'scripts\configure.ps1'
$rollbackScript = Join-Path $skillRoot 'scripts\rollback.ps1'
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$pwsh = (Get-Process -Id $PID).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passes = 0

function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:passes++; Write-Host "PASS $Name" }
    else { $script:failures.Add($Name); Write-Host "FAIL $Name" }
}

function Invoke-Script([string]$Path, [string[]]$Arguments) {
    $output = & $pwsh -NoProfile -File $Path @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-proxy-skill-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$openPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port

try {
    Assert-True (Test-Path -LiteralPath $configureScript) 'configure script exists'
    Assert-True (Test-Path -LiteralPath $rollbackScript) 'rollback script exists'
    if (-not (Test-Path -LiteralPath $configureScript) -or -not (Test-Path -LiteralPath $rollbackScript)) {
        throw 'Implementation scripts are missing as expected during RED.'
    }

    $config = Join-Path $tempRoot 'dry-run.toml'
    $registry = Join-Path $tempRoot 'registry.json'
    $state = Join-Path $tempRoot 'state'
    Copy-Item (Join-Path $fixtureRoot 'config-with-features.toml') $config
    '{"ProxyEnable":0,"ProxyServer":"old.proxy:8080","ProxyOverride":"<local>"}' | Set-Content $registry
    $beforeConfig = Get-Content $config -Raw
    $beforeRegistry = Get-Content $registry -Raw
    $result = Invoke-Script $configureScript @('-ConfigPath',$config,'-StatePath',$state,'-RegistryStatePath',$registry,'-ProxyPort',"$openPort")
    Assert-True ($result.ExitCode -eq 0) 'dry run exits successfully'
    Assert-True ((Get-Content $config -Raw) -ceq $beforeConfig) 'dry run preserves config'
    Assert-True ((Get-Content $registry -Raw) -ceq $beforeRegistry) 'dry run preserves registry state'

    $result = Invoke-Script $configureScript @('-ConfigPath',$config,'-StatePath',$state,'-RegistryStatePath',$registry,'-ProxyPort',"$openPort",'-Apply')
    Assert-True ($result.ExitCode -eq 0) 'apply exits successfully'
    $updated = Get-Content $config -Raw
    Assert-True ($updated -match '(?m)^respect_system_proxy\s*=\s*true\s*$') 'existing features table gains setting'
    Assert-True ($updated -match '(?m)^js_repl\s*=\s*false\s*$') 'existing feature key is preserved'
    Assert-True ($updated -match '(?m)^theme\s*=\s*"system"\s*$') 'unrelated TOML is preserved'
    $reg = Get-Content $registry -Raw | ConvertFrom-Json
    Assert-True ($reg.ProxyEnable -eq 1 -and $reg.ProxyServer -eq "127.0.0.1:$openPort") 'proxy state is applied'
    Assert-True (Test-Path (Join-Path $state 'latest.txt')) 'apply records rollback pointer'
    $firstPointer = Get-Content (Join-Path $state 'latest.txt') -Raw
    $result = Invoke-Script $configureScript @('-ConfigPath',$config,'-StatePath',$state,'-RegistryStatePath',$registry,'-ProxyPort',"$openPort",'-Apply')
    $secondPointer = Get-Content (Join-Path $state 'latest.txt') -Raw
    Assert-True ($result.ExitCode -eq 0 -and $secondPointer -ceq $firstPointer) 'repeated apply preserves original rollback baseline'

    $missing = Join-Path $tempRoot 'missing.toml'
    $missingRegistry = Join-Path $tempRoot 'missing-registry.json'
    $missingState = Join-Path $tempRoot 'missing-state'
    Copy-Item (Join-Path $fixtureRoot 'config-without-features.toml') $missing
    '{"ProxyEnable":0,"ProxyServer":null,"ProxyOverride":null}' | Set-Content $missingRegistry
    $result = Invoke-Script $configureScript @('-ConfigPath',$missing,'-StatePath',$missingState,'-RegistryStatePath',$missingRegistry,'-ProxyPort',"$openPort",'-Apply')
    Assert-True ($result.ExitCode -eq 0) 'missing features table is supported'
    Assert-True ((Get-Content $missing -Raw) -match '(?ms)\[features\].*?respect_system_proxy\s*=\s*true') 'missing features table is added'

    $existing = Join-Path $tempRoot 'existing-setting.toml'
    $existingRegistry = Join-Path $tempRoot 'existing-setting-registry.json'
    Set-Content -LiteralPath $existing -Value "[features]`nrespect_system_proxy = false`njs_repl = false`n" -NoNewline
    '{"ProxyEnable":0,"ProxyServer":null,"ProxyOverride":null}' | Set-Content $existingRegistry
    $result = Invoke-Script $configureScript @('-ConfigPath',$existing,'-StatePath',(Join-Path $tempRoot 'existing-setting-state'),'-RegistryStatePath',$existingRegistry,'-ProxyPort',"$openPort",'-Apply')
    $existingText = Get-Content $existing -Raw
    Assert-True ($result.ExitCode -eq 0 -and ([regex]::Matches($existingText, '(?m)^respect_system_proxy\s*=')).Count -eq 1 -and $existingText -match '(?m)^respect_system_proxy\s*=\s*true$') 'existing setting is updated once'

    $spaced = Join-Path $tempRoot 'spaced-features.toml'
    $spacedRegistry = Join-Path $tempRoot 'spaced-registry.json'
    Set-Content -LiteralPath $spaced -Value "[ features ]`njs_repl = false`n" -NoNewline
    '{"ProxyEnable":0,"ProxyServer":null,"ProxyOverride":null}' | Set-Content $spacedRegistry
    $result = Invoke-Script $configureScript @('-ConfigPath',$spaced,'-StatePath',(Join-Path $tempRoot 'spaced-state'),'-RegistryStatePath',$spacedRegistry,'-ProxyPort',"$openPort",'-Apply')
    $spacedText = Get-Content $spaced -Raw
    Assert-True ($result.ExitCode -eq 0 -and ([regex]::Matches($spacedText, '(?m)^\s*\[\s*features\s*\]')).Count -eq 1) 'spaced features header is handled without duplication'

    foreach ($unsafeCase in @(
        @{ Name='malformed features header'; Text="[features`njs_repl = false`n" },
        @{ Name='quoted target key'; Text="[features]`n`"respect_system_proxy`" = false`n" },
        @{ Name='inline features table'; Text="features = { respect_system_proxy = false }`n" }
    )) {
        $unsafe = Join-Path $tempRoot (($unsafeCase.Name -replace ' ','-') + '.toml')
        $unsafeRegistry = "$unsafe.registry.json"
        Set-Content -LiteralPath $unsafe -Value $unsafeCase.Text -NoNewline
        '{"ProxyEnable":0,"ProxyServer":"old.proxy:8080","ProxyOverride":"<local>"}' | Set-Content $unsafeRegistry
        $unsafeBefore = Get-Content $unsafe -Raw
        $result = Invoke-Script $configureScript @('-ConfigPath',$unsafe,'-StatePath',("$unsafe.state"),'-RegistryStatePath',$unsafeRegistry,'-ProxyPort',"$openPort",'-Apply')
        Assert-True ($result.ExitCode -ne 0 -and (Get-Content $unsafe -Raw) -ceq $unsafeBefore) "$($unsafeCase.Name) is refused without mutation"
    }

    $arrayBoundary = Join-Path $tempRoot 'array-boundary.toml'
    $arrayRegistry = Join-Path $tempRoot 'array-registry.json'
    Set-Content -LiteralPath $arrayBoundary -Value "[features]`njs_repl = false`n[[items]]`nrespect_system_proxy = false`n" -NoNewline
    '{"ProxyEnable":0,"ProxyServer":null,"ProxyOverride":null}' | Set-Content $arrayRegistry
    $result = Invoke-Script $configureScript @('-ConfigPath',$arrayBoundary,'-StatePath',(Join-Path $tempRoot 'array-state'),'-RegistryStatePath',$arrayRegistry,'-ProxyPort',"$openPort",'-Apply')
    $arrayText = Get-Content $arrayBoundary -Raw
    Assert-True ($result.ExitCode -eq 0 -and $arrayText -match '(?ms)\[features\].*?respect_system_proxy\s*=\s*true.*?\[\[items\]\]\s*\r?\nrespect_system_proxy\s*=\s*false') 'array table starts a new section boundary'

    $ambiguous = Join-Path $tempRoot 'ambiguous.toml'
    $ambiguousRegistry = Join-Path $tempRoot 'ambiguous-registry.json'
    Copy-Item (Join-Path $fixtureRoot 'config-ambiguous.toml') $ambiguous
    '{"ProxyEnable":0,"ProxyServer":"old.proxy:8080","ProxyOverride":"<local>"}' | Set-Content $ambiguousRegistry
    $ambiguousBefore = Get-Content $ambiguous -Raw
    $result = Invoke-Script $configureScript @('-ConfigPath',$ambiguous,'-StatePath',(Join-Path $tempRoot 'ambiguous-state'),'-RegistryStatePath',$ambiguousRegistry,'-ProxyPort',"$openPort",'-Apply')
    Assert-True ($result.ExitCode -ne 0) 'duplicate features tables are refused'
    Assert-True ((Get-Content $ambiguous -Raw) -ceq $ambiguousBefore) 'ambiguous config is not changed'

    $closedProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $closedProbe.Start(); $closedPort = ([Net.IPEndPoint]$closedProbe.LocalEndpoint).Port; $closedProbe.Stop()
    $unreachable = Join-Path $tempRoot 'unreachable.toml'
    Copy-Item (Join-Path $fixtureRoot 'config-with-features.toml') $unreachable
    $unreachableBefore = Get-Content $unreachable -Raw
    $result = Invoke-Script $configureScript @('-ConfigPath',$unreachable,'-StatePath',(Join-Path $tempRoot 'unreachable-state'),'-RegistryStatePath',(Join-Path $tempRoot 'unreachable-registry.json'),'-ProxyPort',"$closedPort",'-Apply')
    Assert-True ($result.ExitCode -ne 0) 'unreachable proxy is refused'
    Assert-True ((Get-Content $unreachable -Raw) -ceq $unreachableBefore) 'unreachable proxy causes no config mutation'

    $result = Invoke-Script $rollbackScript @('-StatePath',$state,'-RegistryStatePath',$registry)
    Assert-True ($result.ExitCode -eq 0) 'rollback exits successfully'
    Assert-True ((Get-Content $config -Raw) -ceq $beforeConfig) 'rollback restores exact config'
    $reg = Get-Content $registry -Raw | ConvertFrom-Json
    Assert-True ($reg.ProxyEnable -eq 0 -and $reg.ProxyServer -eq 'old.proxy:8080') 'rollback restores proxy state'
    $result = Invoke-Script $rollbackScript @('-StatePath',$state,'-RegistryStatePath',$registry)
    Assert-True ($result.ExitCode -eq 0) 'rollback is idempotent'

    $badStateDir = Join-Path $tempRoot 'bad-state'
    New-Item -ItemType Directory -Path $badStateDir | Out-Null
    $badConfig = Join-Path $tempRoot 'bad-state-config.toml'
    $badBackup = Join-Path $badStateDir 'backup.toml'
    $badRegistry = Join-Path $tempRoot 'bad-state-registry.json'
    Set-Content $badConfig 'current'; Set-Content $badBackup 'backup'
    '{"ProxyEnable":1,"ProxyServer":"127.0.0.1:7890","ProxyOverride":"<local>"}' | Set-Content $badRegistry
    $badJson = Join-Path $badStateDir 'bad.json'
    [pscustomobject]@{ ConfigPath=$badConfig; ConfigBackup=$badBackup; ProxyState='invalid' } | ConvertTo-Json | Set-Content $badJson
    Set-Content (Join-Path $badStateDir 'latest.txt') $badJson -NoNewline
    $badConfigBefore = Get-Content $badConfig -Raw; $badRegistryBefore = Get-Content $badRegistry -Raw
    $result = Invoke-Script $rollbackScript @('-StatePath',$badStateDir,'-RegistryStatePath',$badRegistry)
    Assert-True ($result.ExitCode -ne 0) 'malformed rollback metadata is refused'
    Assert-True ((Get-Content $badConfig -Raw) -ceq $badConfigBefore -and (Get-Content $badRegistry -Raw) -ceq $badRegistryBefore) 'malformed rollback metadata causes no mutation'

    $failedApplyConfig = Join-Path $tempRoot 'failed-apply.toml'
    Copy-Item (Join-Path $fixtureRoot 'config-with-features.toml') $failedApplyConfig
    $failedBefore = Get-Content $failedApplyConfig -Raw
    $result = Invoke-Script $configureScript @('-ConfigPath',$failedApplyConfig,'-StatePath',(Join-Path $tempRoot 'failed-apply-state'),'-RegistryStatePath','Z:\missing\registry.json','-ProxyPort',"$openPort",'-Apply')
    Assert-True ($result.ExitCode -ne 0 -and (Get-Content $failedApplyConfig -Raw) -ceq $failedBefore) 'failed apply restores exact config'
    Assert-True ($result.Output -match 'Backup:' -and $result.Output -match 'Cause:') 'failed apply reports recovery evidence and backup location'
}
catch {
    $failures.Add($_.Exception.Message)
    Write-Host "FAIL $($_.Exception.Message)"
}
finally {
    $listener.Stop()
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "RESULT $passes passed, $($failures.Count) failed"
if ($failures.Count -gt 0) { exit 1 }
exit 0

