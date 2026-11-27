#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../tools/ReflexCore-ManagedEvents.ps1')
$state=[ordered]@{thread='owned';turn=$null;state='unknown';failure=$null}
function Event($thread,$turn,$kind){
    @{method='error';params=@{threadId=$thread;turnId=$turn;willRetry=$false;error=@{codexErrorInfo=$kind;message='Not persisted'}}}
}
if(Update-ReflexManagedTurn $state (Event 'foreign' 'turn-a' 'usageLimitExceeded')){throw 'Foreign turn accepted'}
if(!(Update-ReflexManagedTurn $state (Event 'owned' 'turn-a' 'rateLimitExceeded')) -or $state.failure -ne 'temporary_rate_limit'){throw 'Temporary limit misclassified'}
if(!(Update-ReflexManagedTurn $state (Event 'owned' 'turn-a' 'contextWindowExceeded')) -or $state.failure -ne 'context_exhausted'){throw 'Context exhaustion misclassified'}
if(Update-ReflexManagedTurn $state (Event 'owned' 'turn-b' 'usageLimitExceeded')){throw 'Unrelated turn accepted'}
if(!(Update-ReflexManagedTurn $state (Event 'owned' 'turn-a' 'usageLimitExceeded')) -or $state.failure -ne 'allowance_exhausted'){throw 'Authoritative limit ignored'}
$null=Update-ReflexManagedTurn $state @{method='turn/completed';params=@{threadId='owned';turn=@{id='turn-a';status='failed';error=@{codexErrorInfo='other'}}}}
if($state.state -ne 'failed' -or $state.failure -ne 'allowance_exhausted'){throw 'Terminal event erased exhaustion evidence'}
'PASS: managed event correlation and authoritative exhaustion classification.'
