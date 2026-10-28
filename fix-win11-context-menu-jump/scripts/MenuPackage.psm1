Set-StrictMode -Version 2

function Read-MenuXml {
    param([Parameter(Mandatory)][string]$Text)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create((New-Object IO.StringReader($Text)), $settings)
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
        return ,$doc
    } finally { $reader.Dispose() }
}

function ConvertTo-MenuManifestInfo {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document)
    $identity = $Document.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
    if (!$identity) { throw 'Missing Appx package identity.' }
    $verbs = @(
        foreach ($item in $Document.SelectNodes('//*[local-name()="FileExplorerContextMenus"]/*[local-name()="ItemType"]')) {
            foreach ($verb in $item.SelectNodes('./*[local-name()="Verb"]')) {
                [pscustomobject]@{Type=$item.GetAttribute('Type');Id=$verb.GetAttribute('Id');Clsid=$verb.GetAttribute('Clsid')}
            }
        }
    )
    $background = @($verbs | Where-Object { $_.Type -in @('Directory\Background', 'DesktopBackground') })
    $backgroundIds = @($background | ForEach-Object { $_.Clsid.Trim('{}').ToLowerInvariant() } | Sort-Object -Unique)
    $classes = @($Document.SelectNodes('//*[local-name()="ComServer"]//*[local-name()="Class"]'))
    $unresolved = @(foreach ($id in $backgroundIds) {
        $matches = @($classes | Where-Object { $_.GetAttribute('Id').Trim('{}').ToLowerInvariant() -eq $id })
        if (!$matches.Count -or @($matches | Where-Object { !$_.GetAttribute('Path') }).Count) { $id }
    })
    $dllPaths = @($classes | Where-Object {
        $_.GetAttribute('Id').Trim('{}').ToLowerInvariant() -in $backgroundIds
    } | ForEach-Object { $_.GetAttribute('Path') } | Where-Object { $_ } | Sort-Object -Unique)
    $categories = @($Document.SelectNodes('//*[local-name()="Extension"]') | ForEach-Object { $_.GetAttribute('Category') } | Sort-Object -Unique)
    $other = @($categories | Where-Object { $_ -notin @('windows.comServer', 'windows.fileExplorerContextMenus') })
    $allowExternal = $Document.SelectSingleNode('//*[local-name()="Properties"]/*[local-name()="AllowExternalContent"]')
    [pscustomobject]@{
        Name=$identity.GetAttribute('Name')
        Version=$identity.GetAttribute('Version')
        Publisher=$identity.GetAttribute('Publisher')
        Architecture=$identity.GetAttribute('ProcessorArchitecture')
        ResourceId=$identity.GetAttribute('ResourceId')
        Verbs=$verbs
        BackgroundVerbs=$background
        BackgroundDllPaths=$dllPaths
        UnresolvedBackgroundClsids=$unresolved
        ExtensionCategories=$categories
        IsMenuOnlySparseCandidate=($null -ne $allowExternal -and $allowExternal.InnerText.Trim() -eq 'true' -and $background.Count -gt 0 -and $other.Count -eq 0)
    }
}

function Get-MenuExternalFiles {
    param([Parameter(Mandatory)]$ManifestInfo, [Parameter(Mandatory)][string]$ExternalLocation)
    $root = [IO.Path]::GetFullPath($ExternalLocation).TrimEnd('\') + '\'
    if ($ManifestInfo.UnresolvedBackgroundClsids.Count) { throw 'Some background COM classes cannot be resolved to external DLLs. Investigate manually instead of unregistering.' }
    if (!$ManifestInfo.BackgroundDllPaths.Count) { throw 'Cannot verify external background COM DLL paths. Investigate manually instead of unregistering.' }
    foreach ($relative in $ManifestInfo.BackgroundDllPaths) {
        $file = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (!$file.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Menu DLL escapes the verified external root.' }
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw "External menu DLL is missing: $file" }
        [pscustomobject]@{Path=$file;Sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash}
    }
}

function Get-MenuManifestInfo {
    param([Parameter(Mandatory)][string]$ManifestPath)
    $doc = Read-MenuXml -Text ([IO.File]::ReadAllText((Get-Item -LiteralPath $ManifestPath -ErrorAction Stop).FullName))
    ConvertTo-MenuManifestInfo -Document $doc
}

function Get-MenuInstallerInfo {
    param([Parameter(Mandatory)][string]$InstallerPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Get-Item -LiteralPath $InstallerPath -ErrorAction Stop).FullName)
    try {
        $entry = $zip.GetEntry('AppxManifest.xml')
        if (!$entry -or !$zip.GetEntry('AppxSignature.p7x')) { throw 'Expected a signed standalone MSIX/Appx with a manifest; bundles are not supported.' }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        ConvertTo-MenuManifestInfo -Document (Read-MenuXml -Text $text)
    } finally { $zip.Dispose() }
}

function Assert-MenuIdentityMatch {
    param([Parameter(Mandatory)]$Installed, [Parameter(Mandatory)]$Installer)
    foreach ($field in @('Name','Version','Publisher','Architecture','ResourceId')) {
        if ($Installed.$field -cne $Installer.$field) { throw "Recovery installer does not match installed $field." }
    }
}

Export-ModuleMember -Function Get-MenuManifestInfo, Get-MenuInstallerInfo, Assert-MenuIdentityMatch, Get-MenuExternalFiles
