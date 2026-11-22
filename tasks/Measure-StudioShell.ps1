param([string]$Project,[string]$PreviewFile='')
$ErrorActionPreference='Stop'
$root=(Resolve-Path $Project).Path
$parent=Split-Path $root -Parent
$text=[IO.File]::ReadAllText((Join-Path $root 'tools\ReflexCore-ControlCenter.ps1'))
$start=$text.IndexOf('    # Combine existing')
$end=$text.IndexOf('    if($UiSmoke)', $start)
if($end -lt 0){$end=$text.IndexOf('    if($SelfTest)', $start)}
& ([scriptblock]::Create($text.Substring($start,$end-$start)))
$t=[ReflexCore.Control.Center].Assembly.GetType('ReflexCore.Control.Dashboard')
[Windows.Forms.Application]::EnableVisualStyles()
$form=[Activator]::CreateInstance($t,@($root,'Agent'))
$flags=[Reflection.BindingFlags]'NonPublic,Instance'
$studioField=$t.GetField('studio',$flags)
$proc=[Diagnostics.Process]::GetCurrentProcess()
$timer=[Windows.Forms.Timer]::new()
$timer.Interval=250
$sw=[Diagnostics.Stopwatch]::StartNew()
$script:peak=0
$script:startCpu=$null
$script:problem=$null
$script:peakGpu=$null
# Skip initialization, then observe a stationary Agent page for eight seconds.
$timer.add_Tick({
 try {
    $proc.Refresh()
    if($sw.ElapsedMilliseconds -lt 1800){return}
    if($null -eq $script:startCpu){$script:startCpu=$proc.TotalProcessorTime.TotalMilliseconds;$script:sampleAt=$sw.ElapsedMilliseconds}
    $script:peak=[Math]::Max($script:peak,[double]$proc.WorkingSet64)
    if($sw.ElapsedMilliseconds-$script:sampleAt -lt 8000){return}
    $timer.Stop()
    $cpuMs=$proc.TotalProcessorTime.TotalMilliseconds-$script:startCpu
    [Console]::WriteLine(('sample_ms={0} cpu_ms={1:N0} peak_mib={2:N1}' -f ($sw.ElapsedMilliseconds-$script:sampleAt),$cpuMs,($script:peak/1MB)))
    if($studioField){
        $window=$studioField.GetValue($form)
        if($PreviewFile){
            $window.SelectPage(6);$window.UpdateLayout()
            $visual=$window.Content
            $bmp=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$visual.ActualWidth,[int]$visual.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($visual)
            $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $out=[IO.File]::Create($PreviewFile);try{$encoder.Save($out)}finally{$out.Dispose()}
        }
        $window.Close()
    }else{$form.Close()}
 }catch {
    $script:problem=$_.Exception.Message;$timer.Stop()
    if($studioField -and $studioField.GetValue($form)){$studioField.GetValue($form).Close()}else{$form.Close()}
 }
})
$timer.Start()
try{
    if($studioField){$t.GetMethod('ShowStudio',$flags).Invoke($form,@($false))}
    else{[Windows.Forms.Application]::Run($form)}
}finally{$timer.Dispose();$form.Dispose();$proc.Dispose()}
if($script:problem){throw $script:problem}

