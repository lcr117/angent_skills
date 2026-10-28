$ErrorActionPreference='Stop'
$module=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\MenuBlocks.psm1'
if(!(Test-Path -LiteralPath $module)){throw 'RED: registry menu-block implementation missing'}
Import-Module $module -Force
$script:count=0
function Check($ok,$message){if(!$ok){throw "FAIL: $message"};$script:count++;Write-Host "PASS: $message"}
function Reject([scriptblock]$work,$message){$failed=$false;try{& $work|Out-Null}catch{$failed=$true};Check $failed $message}
$id='{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
$info=[pscustomobject]@{Name='Fabrikam.Cloud';Version='2.0.0.0';Verbs=@([pscustomobject]@{Type='*';Id='Menu';Clsid=$id});ExtensionCategories=@('windows.cloudFiles','windows.fileExplorerContextMenus','windows.comServer')}
$plan=New-MenuBlockPlan -ManifestInfo $info -Clsid @($id) -Scope CurrentUser
Check ($plan.Entries.Count -eq 1) 'blocks a specific manifest menu class without unregistering a cloud package'
Reject {New-MenuBlockPlan -ManifestInfo $info -Clsid @('{11111111-2222-3333-4444-555555555555}') -Scope CurrentUser} 'rejects CLSIDs absent from menu verbs'
Reject {New-MenuBlockPlan -ManifestInfo $info -Clsid @('*') -Scope CurrentUser} 'rejects wildcard CLSIDs'
$duplicate=New-MenuBlockPlan -ManifestInfo $info -Clsid @($id,$id.ToLowerInvariant()) -Scope CurrentUser
Check ($duplicate.Entries.Count -eq 1) 'deduplicates equivalent CLSIDs'
$before=[pscustomobject]@{Exists=$true;Kind='ExpandString';Data='%SystemRoot%\old'}
$same=[pscustomobject]@{Exists=$true;Kind='ExpandString';Data='%SystemRoot%\old'}
Check (Test-MenuValueEqual $before $same) 'preserves exact unexpanded type and data'
$same.Kind='String'
Check (!(Test-MenuValueEqual $before $same)) 'detects type-only intervening changes'
$multi1=[pscustomobject]@{Exists=$true;Kind='MultiString';Data=@('a','b')}
$multi2=[pscustomobject]@{Exists=$true;Kind='MultiString';Data=@('b','a')}
Check (!(Test-MenuValueEqual $multi1 $multi2)) 'preserves multi-string order'

# Replace only module-local OS accessors; tests never touch the registry.
$m=Get-Module MenuBlocks
& $m {
 $script:fakeState=[pscustomobject]@{Exists=$false;Kind=$null;Data=$null}
 $script:writes=0
 function script:Get-MenuRegState {param($Scope,$View,$Name) $script:fakeState}
 function script:Set-MenuRegState {param($Scope,$View,$Name,$State) $script:writes++;$script:fakeState=$State}
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('menu-block-tests-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $temp|Out-Null
$backup=Join-Path $temp 'state.json'
try{
 Invoke-MenuBlockChange -Plan $plan -BackupFile $backup
 Check (!(Test-Path -LiteralPath $backup)) 'default plan does not write backup or registry'
 Invoke-MenuBlockChange -Plan $plan -BackupFile $backup -Apply -WhatIf
 Check ((& $m {$script:writes}) -eq 0) 'WhatIf performs no registry mutation'
 $machine=New-MenuBlockPlan -ManifestInfo $info -Clsid @($id) -Scope LocalMachine
 Reject {Invoke-MenuBlockChange -Plan $machine -BackupFile $backup -Apply -Confirm:$false} 'machine scope needs explicit confirmation of affected users'
 Invoke-MenuBlockChange -Plan $plan -BackupFile $backup -Apply -Confirm:$false
 Check ((& $m {$script:writes}) -eq 1) 'applies selected class only'
 Check (Test-Path -LiteralPath $backup) 'saves recovery before registry writes'
 Reject {Invoke-MenuBlockChange -Plan $plan -BackupFile $backup -Apply -Confirm:$false} 'never overwrites original backup'
 & $m {$script:fakeState=[pscustomobject]@{Exists=$true;Kind='String';Data='another tool changed this'}}
 Reject {Restore-MenuBlockChange -BackupFile $backup -Apply -Confirm:$false} 'restore refuses intervening registry edits'
 Check ((& $m {$script:writes}) -eq 1) 'conflicted restore makes no writes'
 $saved=Get-Content -LiteralPath $backup -Raw|ConvertFrom-Json
 & $m {param($state) $script:fakeState=$state} $saved.Entries[0].Applied
 Restore-MenuBlockChange -BackupFile $backup -Apply -Confirm:$false
 Check (!(& $m {$script:fakeState.Exists})) 'restores original absence rather than deleting parent key'
 Restore-MenuBlockChange -BackupFile $backup -Apply -Confirm:$false
 Check ((& $m {$script:writes}) -eq 2) 'repeated restore is idempotent'
 # Existing typed data must survive a full apply / restore cycle.
 & $m {param($state) $script:fakeState=$state} $before
 $typed=Join-Path $temp 'typed.json'
 Invoke-MenuBlockChange -Plan $plan -BackupFile $typed -Apply -Confirm:$false
 Restore-MenuBlockChange -BackupFile $typed -Apply -Confirm:$false
 Check (Test-MenuValueEqual $before (& $m {$script:fakeState})) 'restores original registry type and value'
 $invalid=Get-Content -LiteralPath $typed -Raw|ConvertFrom-Json
 $invalid.UserSid='S-1-0-0'
 $wrongUser=Join-Path $temp 'wrong-user.json'
 $invalid|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $wrongUser
 Reject {Restore-MenuBlockChange -BackupFile $wrongUser -Apply -Confirm:$false} 'refuses another user recovery state'
 & $m {
  $script:states=@{};$script:writes=0
  function script:Get-MenuRegState {param($Scope,$View,$Name) if($script:states.ContainsKey($Name)){$script:states[$Name]}else{[pscustomobject]@{Exists=$false;Kind=$null;Data=$null}}}
  function script:Set-MenuRegState {param($Scope,$View,$Name,$State) $script:writes++;if($script:writes -eq 2){throw 'Simulated second-value failure'};$script:states[$Name]=$State}
 }
 $id2='{11111111-2222-3333-4444-555555555555}'
 $info.Verbs+=@([pscustomobject]@{Type='*';Id='Menu2';Clsid=$id2})
 $two=New-MenuBlockPlan -ManifestInfo $info -Clsid @($id,$id2) -Scope CurrentUser
 $partial=Join-Path $temp 'partial.json'
 Reject {Invoke-MenuBlockChange -Plan $two -BackupFile $partial -Apply -Confirm:$false} 'reports partial apply failure rather than success'
 Check (Test-Path -LiteralPath $partial) 'partial apply retains write-ahead recovery record'
 $hash=(Get-FileHash -LiteralPath $partial).Hash
 Restore-MenuBlockChange -BackupFile $partial -Apply -Confirm:$false
 $remaining=& $m {@($script:states.Values|Where-Object {$_.Exists}).Count}
 Check ($remaining -eq 0) 'partial apply recovery restores only successfully changed values'
 Check ((Get-FileHash -LiteralPath $partial).Hash -eq $hash) 'recovery never overwrites the original backup'
 Write-Host "$script:count menu-block checks passed. No live registry changed."
}finally{
 $full=[IO.Path]::GetFullPath($temp)
 $base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(!$full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected test path'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
