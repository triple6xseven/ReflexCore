# ReflexCore Citadel regression runner: always tests with arena as working directory.
# Windows PowerShell 5.1; safe for direct execution from any cwd.
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$arena=Join-Path $root 'Sandbox for intelegent test\citadel-zero'
if(-not (Test-Path -LiteralPath (Join-Path $arena 'game.js') -PathType Leaf)){
    throw 'Citadel game.js not found in expected arena directory.'
}
$tests=@('strategy.test.js','simulation.test.js','deployment.test.js',
    'warfare.test.js','agent-policy.test.js','visibility.test.js','agent-rust.test.js')
$syntax=@('agent-rust.js','agent-ui.js','game.js','agent-policy.js')
Push-Location -LiteralPath $arena
try {
    foreach($name in $tests){
        Write-Host ('[Citadel] Running: '+$name)
        & node $name
        if($LASTEXITCODE -ne 0){throw ('Citadel '+$name+' failed with exit code '+$LASTEXITCODE)}
    }
    foreach($name in $syntax){
        & node --check $name
        if($LASTEXITCODE -ne 0){throw ('Citadel syntax '+$name+' failed with exit code '+$LASTEXITCODE)}
    }
    Write-Host '[Citadel] 7 JS regression suites + 4 syntax checks PASS.'
}
finally { Pop-Location }
