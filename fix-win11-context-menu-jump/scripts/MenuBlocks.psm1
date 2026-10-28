Set-StrictMode -Version 2
$script:subkey='SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'

function New-MenuBlockPlan {
 param([Parameter(Mandatory)]$ManifestInfo,[Parameter(Mandatory)][string[]]$Clsid,
       [ValidateSet('CurrentUser','LocalMachine')][string]$Scope='CurrentUser')
 $known=@($ManifestInfo.Verbs | ForEach-Object { ([guid]$_.Clsid).ToString('B').ToUpperInvariant() })
 $entries=@(foreach($value in ($Clsid | Sort-Object -Unique)){
  $id=([guid]$value).ToString('B').ToUpperInvariant()
  if($id -notin $known){throw "CLSID is not declared as a menu verb in this installed manifest: $id"}
  [pscustomobject]@{Name=$id;Applied=[pscustomobject]@{Exists=$true;Kind='String';Data=('Win11 context menu isolation: '+$ManifestInfo.Name)}}
 })
 if(!$entries.Count){throw 'Select at least one exact manifest menu CLSID.'}
 [pscustomobject]@{Scope=$Scope;View=if([Environment]::Is64BitOperatingSystem){'Registry64'}else{'Registry32'};Package=$ManifestInfo.Name;Version=$ManifestInfo.Version;Entries=$entries;Verbs=@($ManifestInfo.Verbs)}
}

function Test-MenuValueEqual {
 param($Left,$Right)
 if([bool]$Left.Exists -ne [bool]$Right.Exists){return $false}
 if(!$Left.Exists){return $true}
 return ($Left.Kind -ceq $Right.Kind -and (ConvertTo-Json -InputObject $Left.Data -Depth 5 -Compress) -ceq (ConvertTo-Json -InputObject $Right.Data -Depth 5 -Compress))
}

function Get-MenuRegState {
 param($Scope,$View,$Name)
 $hive=[Microsoft.Win32.RegistryHive]::$Scope
 $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,[Microsoft.Win32.RegistryView]::$View)
 try{
  $key=$base.OpenSubKey($script:subkey,$false)
  if(!$key){return [pscustomobject]@{Exists=$false;Kind=$null;Data=$null}}
  try{
   if($Name -notin $key.GetValueNames()){return [pscustomobject]@{Exists=$false;Kind=$null;Data=$null}}
   $kind=[string]$key.GetValueKind($Name)
   if($kind -notin @('String','ExpandString','MultiString','DWord','QWord','Binary','None')){throw 'Unsupported original registry data type.'}
   [pscustomobject]@{Exists=$true;Kind=$kind;Data=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
  }finally{$key.Dispose()}
 }finally{$base.Dispose()}
}

function Set-MenuRegState {
 param($Scope,$View,$Name,$State)
 $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$Scope,[Microsoft.Win32.RegistryView]::$View)
 try{
  if(!$State.Exists){
   $key=$base.OpenSubKey($script:subkey,$true)
   if($key){try{$key.DeleteValue($Name,$false)}finally{$key.Dispose()}}
   return
  }
  $key=$base.CreateSubKey($script:subkey)
  try{
   $data=switch($State.Kind){
    'MultiString'{,[string[]]$State.Data}
    'Binary'{,[byte[]]$State.Data}
    'None'{,[byte[]]$State.Data}
    'DWord'{[int]$State.Data}
    'QWord'{[long]$State.Data}
    'String'{[string]$State.Data}
    'ExpandString'{[string]$State.Data}
    default{throw 'Unsupported registry data type.'}
   }
   $key.SetValue($Name,$data,[Microsoft.Win32.RegistryValueKind]::$($State.Kind))
  }finally{$key.Dispose()}
 }finally{$base.Dispose()}
}

function Invoke-MenuBlockChange {
 [CmdletBinding(SupportsShouldProcess=$true)]
 param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$BackupFile,[switch]$Apply,[switch]$MachineScopeConfirmed)
 if($Plan.Scope -notin @('CurrentUser','LocalMachine') -or $Plan.View -notin @('Registry64','Registry32')){throw 'Invalid registry scope or view.'}
 if($Apply -and $Plan.Scope -eq 'LocalMachine' -and !$MachineScopeConfirmed){throw 'HKLM affects every user. Review that scope and pass -MachineScopeConfirmed; administrator rights are also required.'}
 $backup=[IO.Path]::GetFullPath($BackupFile)
 if(Test-Path -LiteralPath $backup){throw 'Backup file already exists. Keep the original baseline and choose a new file.'}
 $rows=@(foreach($entry in $Plan.Entries){
  $id=([guid]$entry.Name).ToString('B').ToUpperInvariant()
  [pscustomobject]@{Name=$id;Before=(Get-MenuRegState $Plan.Scope $Plan.View $id);Applied=$entry.Applied}
 })
 $record=[pscustomobject]@{Schema=1;Computer=$env:COMPUTERNAME;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Scope=$Plan.Scope;View=$Plan.View;Subkey=$script:subkey;Package=$Plan.Package;Version=$Plan.Version;Entries=$rows;CreatedUtc=[DateTime]::UtcNow.ToString('o')}
 Write-Output ("Plan: {0}, {1}, {2} menu class(es)." -f $Plan.Package,$Plan.Scope,$rows.Count)
 if(!$Apply){Write-Output 'Plan only. No registry or backup writes.';return}
 if(!$PSCmdlet.ShouldProcess(($Plan.Scope+'\'+$script:subkey),'Back up and block the selected menu classes')){return}
 $stream=[IO.File]::Open($backup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 $writer=New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($false)))
 try{$writer.Write(($record|ConvertTo-Json -Depth 10))}finally{$writer.Dispose()}
 # Immutable write-ahead record also permits recovery after a partially failed apply.
 foreach($entry in $rows){Set-MenuRegState $Plan.Scope $Plan.View $entry.Name $entry.Applied}
 foreach($entry in $rows){if(!(Test-MenuValueEqual (Get-MenuRegState $Plan.Scope $Plan.View $entry.Name) $entry.Applied)){throw 'Registry write verification failed. Retain the backup for recovery.'}}
 Write-Output "Registry values applied and verified. This does not verify menu behavior. Recovery: $backup"
}

function Restore-MenuBlockChange {
 [CmdletBinding(SupportsShouldProcess=$true)]
 param([Parameter(Mandatory)][string]$BackupFile,[switch]$Apply)
 $saved=Get-Content -LiteralPath $BackupFile -Raw -ErrorAction Stop|ConvertFrom-Json
 if($saved.Schema -ne 1 -or $saved.Computer -ne $env:COMPUTERNAME -or $saved.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Use this backup only on its original computer and user account.'}
 if($saved.Subkey -cne $script:subkey -or $saved.Scope -notin @('CurrentUser','LocalMachine') -or $saved.View -notin @('Registry64','Registry32')){throw 'Invalid saved registry target.'}
 $pending=@(foreach($entry in $saved.Entries){
  $id=([guid]$entry.Name).ToString('B').ToUpperInvariant()
  $current=Get-MenuRegState $saved.Scope $saved.View $id
  if(Test-MenuValueEqual $current $entry.Before){continue}
  if(!(Test-MenuValueEqual $current $entry.Applied)){throw "Registry value changed since apply; restore refuses to overwrite it: $id"}
  $entry
 })
 if(!$Apply){Write-Output ("Plan only: restore {0} value(s) in {1}." -f $pending.Count,$saved.Scope);return}
 if(!$PSCmdlet.ShouldProcess(($saved.Scope+'\'+$script:subkey),'Restore original values without deleting the parent key')){return}
 foreach($entry in $pending){Set-MenuRegState $saved.Scope $saved.View $entry.Name $entry.Before}
 foreach($entry in $saved.Entries){if(!(Test-MenuValueEqual (Get-MenuRegState $saved.Scope $saved.View $entry.Name) $entry.Before)){throw 'Registry restore verification failed.'}}
 Write-Output 'Original registry values restored and verified. Cold-test the actual menus next.'
}

Export-ModuleMember -Function New-MenuBlockPlan,Test-MenuValueEqual,Invoke-MenuBlockChange,Restore-MenuBlockChange
