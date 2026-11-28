#Requires -Version 5.1
function Update-ReflexManagedTurn($State,$Message) {
    $data=$Message.params
    if($data.threadId -cne $State.thread){return $false}
    $id=if($data.turn){$data.turn.id}else{$data.turnId}
    if($id -cnotmatch '^[a-zA-Z0-9-]{1,64}$'){return $false}
    if($State.turn -and $State.turn -cne $id){return $false}
    switch -CaseSensitive ($Message.method){
        'turn/started' { $State.state='running' }
        'turn/plan/updated' {
            $steps=@($data.plan | Select-Object -First 32)
            $State.plan_steps=$steps.Count
            $State.plan_completed=@($steps | Where-Object {$_.status -ceq 'completed'}).Count
        }
        'thread/tokenUsage/updated' {
            $tokens=$data.tokenUsage.total.totalTokens
            if($tokens -is [ValueType] -and $tokens -ge 0){$State.total_tokens=[long]$tokens}
            foreach($name in 'last','total'){
                $fields=[ordered]@{}
                foreach($key in 'inputTokens','cachedInputTokens','outputTokens','reasoningOutputTokens','totalTokens'){
                    $value=$data.tokenUsage.$name.$key
                    if($value -is [ValueType] -and $value -ge 0){$fields[$key]=[long]$value}
                }
                if($fields.Count){$State["tokens_$name"]=$fields}
            }
        }
        'error' {
            if($State.failure -ne 'allowance_exhausted'){$State.failure=Get-ReflexManagedFailure $data.error.codexErrorInfo}
            $State.retry_reported=$data.willRetry -eq $true
        }
        'turn/completed' {
            $State.state=switch -CaseSensitive ($data.turn.status){
                'completed' {'completed'}
                'failed' {'failed'}
                'interrupted' {'interrupted'}
                default {'unknown'}
            }
            if($State.state -eq 'failed' -and $data.turn.error -and $State.failure -ne 'allowance_exhausted'){$State.failure=Get-ReflexManagedFailure $data.turn.error.codexErrorInfo}
        }
        default { return $false }
    }
    $State.turn=$id
    return $true
}
function Get-ReflexManagedFailure($Kind) {
    switch -CaseSensitive ($Kind) {
        'usageLimitExceeded' {'allowance_exhausted'}
        'rateLimitExceeded' {'temporary_rate_limit'}
        'contextWindowExceeded' {'context_exhausted'}
        default {'unknown'}
    }
}

function Get-ReflexManagedKey([string]$ThreadId){
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ThreadId)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
