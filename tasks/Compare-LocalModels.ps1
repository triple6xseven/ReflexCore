# Fixed synthetic inputs only. Each model runs alone; results are aggregate measurements.
[CmdletBinding()]
param([string[]]$Models=@('qwen3-vl:2b-instruct','qwen3-vl:4b-instruct'),[ValidateRange(1,8)][int]$Runs=2)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$api='http://127.0.0.1:11434/api'
function Image([string]$layout){
    $bmp=New-Object Drawing.Bitmap 480,160
    $g=[Drawing.Graphics]::FromImage($bmp)
    $font=New-Object Drawing.Font 'Segoe UI',23
    $ms=New-Object IO.MemoryStream
    try{
        if($layout -in 'red','blue'){
            $g.Clear([Drawing.Color]::FromName($layout))
            $g.FillRectangle([Drawing.Brushes]::White,208,60,64,40)
        }else{
            $g.Clear([Drawing.Color]::White)
            $g.FillRectangle([Drawing.Brushes]::Navy,15,46,208,76)
            $g.FillRectangle([Drawing.Brushes]::Navy,252,46,208,76)
            $names=if($layout -eq 'left'){@('SAVE','OPEN')}else{@('OPEN','SAVE')}
            $g.DrawString($names[0],$font,[Drawing.Brushes]::White,57,59)
            $g.DrawString($names[1],$font,[Drawing.Brushes]::White,299,59)
        }
        $bmp.Save($ms,[Drawing.Imaging.ImageFormat]::Png)
        return [Convert]::ToBase64String($ms.ToArray())
    }finally{$ms.Dispose();$font.Dispose();$g.Dispose();$bmp.Dispose()}
}
function Generate($payload){
    Invoke-RestMethod -Method Post -Uri ($api+'/generate') -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Compress -Depth 8) -TimeoutSec 240
}
function Pct($values,$q){$s=@($values | Sort-Object); if($s.Count){return $s[[int][Math]::Ceiling($q*$s.Count)-1]}}
$installed=@((Invoke-RestMethod ($api+'/tags')).models | ForEach-Object name)
$cases=@(
    @{want='wait';prompt='No application window is available. Choose wait or edit.';labels=@('wait','edit')},
    @{want='edit';prompt='A verified new scratch editor is ready and writing was requested. Choose wait or edit.';labels=@('wait','edit')}
)
foreach($v in 'red','blue','left','right'){
    $color=$v -in 'red','blue'
    $cases+=@{want=$v;image=(Image $v);prompt=$(if($color){'Choose the dominant background color.'}else{'On which side of the image is the button labeled SAVE?'});labels=$(if($color){@('red','blue')}else{@('left','right')})}
}
foreach($model in $Models){
    if($installed -cnotcontains $model){throw 'Requested model is unavailable'}
    if(@((Invoke-RestMethod ($api+'/ps')).models).Count -gt 0){throw 'Benchmark requires an idle model server to measure a cold load'}
    $times=@();$correct=0;$failed=0;$textOk=0;$imageOk=0;$tokens=0;$evalNs=0.0;$peakVram=0;$peakProcessMiB=0;$peakModelBytes=0;$minAvailable=$null;$coldMs=$null
    try{
        foreach($round in 1..$Runs){
            foreach($case in $cases){
                $schema=@{type='object';properties=@{answer=@{type='string';enum=$case.labels}};required=@('answer');additionalProperties=$false}
                $body=@{model=$model;prompt=$case.prompt;stream=$false;format=$schema;keep_alive='1m';options=@{temperature=0;num_ctx=2048;num_predict=32;seed=1}}
                if($case.image){$body.images=@($case.image)}
                $sw=[Diagnostics.Stopwatch]::StartNew()
                try{
                    $r=Generate $body
                    $ms=$sw.ElapsedMilliseconds
                    if($null -eq $coldMs){$coldMs=$ms}else{$times+=$ms}
                    $tokens+=$r.eval_count;$evalNs+=$r.eval_duration
                    $answer=$r.response | ConvertFrom-Json
                    if($r.done -eq $true -and @($answer.PSObject.Properties).Count -eq 1 -and $answer.answer -ceq $case.want){
                        $correct++
                        if($case.image){$imageOk++}else{$textOk++}
                    }
                    $loaded=(Invoke-RestMethod ($api+'/ps')).models | Where-Object name -ceq $model
                    $peakVram=[Math]::Max($peakVram,[double]$loaded.size_vram)
                    $peakModelBytes=[Math]::Max($peakModelBytes,[double]$loaded.size)
                    $freeMiB=[Math]::Round((Get-CimInstance -ClassName Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory/1024)
                    if($null -eq $minAvailable -or $freeMiB -lt $minAvailable){$minAvailable=$freeMiB}
                    $working=(Get-Process -Name 'ollama','ollama_llama_server' -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum
                    $peakProcessMiB=[Math]::Max($peakProcessMiB,[double]$working/1MB)
                }catch{$failed++}
            }
        }
        [pscustomobject]@{model=$model;cases=$cases.Count*$Runs;correct=$correct;text_correct=$textOk;image_correct=$imageOk;request_failures=$failed;cold_ms=$coldMs;warm_p50_ms=(Pct $times 0.50);warm_p95_ms=(Pct $times 0.95);output_tokens_s=$(if($evalNs -gt 0){[Math]::Round(1e9*$tokens/$evalNs,1)});peak_resident_vram_mib=[Math]::Round($peakVram/1MB);peak_reported_model_mib=[Math]::Round($peakModelBytes/1MB);min_available_system_mib=$minAvailable;named_process_working_set_mib=[Math]::Round($peakProcessMiB)}
    }finally{
        [void](Generate @{model=$model;keep_alive=0;stream=$false})
        $until=[DateTime]::UtcNow.AddSeconds(20)
        do{
            if(@((Invoke-RestMethod ($api+'/ps')).models | Where-Object name -ceq $model).Count -eq 0){break}
            Start-Sleep -Milliseconds 250
        }while([DateTime]::UtcNow -lt $until)
    }
}
