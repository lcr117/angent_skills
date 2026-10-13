$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$skillPath = Join-Path $root 'SKILL.md'
$yamlPath = Join-Path $root 'agents\openai.yaml'
$errors = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) { $errors.Add('SKILL.md is missing') }
if (-not (Test-Path -LiteralPath $yamlPath -PathType Leaf)) { $errors.Add('agents/openai.yaml is missing') }
if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
    $skill = Get-Content -LiteralPath $skillPath -Raw
    if ($skill -notmatch '(?s)^---\s*\r?\nname:\s*configure-codex-clash-proxy\s*\r?\ndescription:\s*Use when ') { $errors.Add('frontmatter name/description is invalid') }
    if ($skill -match 'TODO|PLACEHOLDER') { $errors.Add('SKILL.md contains scaffold placeholders') }
    $body = ($skill -split '---', 3)[-1]
    $wordCount = ([regex]::Matches($body, '\S+')).Count
    if ($wordCount -gt 500) { $errors.Add("SKILL.md body exceeds 500 words: $wordCount") }
}
if (Test-Path -LiteralPath $yamlPath -PathType Leaf) {
    $yaml = Get-Content -LiteralPath $yamlPath -Raw
    if ($yaml -notmatch 'default_prompt:\s*"[^"]*\$configure-codex-clash-proxy') { $errors.Add('default_prompt must mention $configure-codex-clash-proxy') }
    if ($yaml -notmatch 'allow_implicit_invocation:\s*true') { $errors.Add('implicit invocation must remain enabled') }
}
foreach ($required in @('scripts\configure.ps1','scripts\rollback.ps1','tests\run-tests.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { $errors.Add("missing $required") }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "FAIL $_" }
    exit 1
}
Write-Host 'PASS skill structure and metadata'
exit 0

