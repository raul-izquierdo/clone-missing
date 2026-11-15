$ErrorActionPreference = 'Continue'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'clone-missing.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("clone-missing-workflow-{0}" -f [guid]::NewGuid())
$originalPath = $env:PATH
$originalRoot = $env:CLONE_TEST_ROOT
$originalFailure = $env:CLONE_TEST_ACCESS_FAIL

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

try {
    [void] (New-Item -ItemType Directory -Path $root)
    $env:PATH = (Join-Path $PSScriptRoot 'fake-bin') + ';' + $originalPath
    $env:CLONE_TEST_ROOT = $root
    $env:CLONE_TEST_ACCESS_FAIL = '0'
    Push-Location $root

    $list = Join-Path $root 'list.txt'
    [System.IO.File]::WriteAllLines($list, @('https://github.com/owner/one.git', 'git@github.com:OWNER/one'))
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ListPath $list 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'A duplicate list returned success.'
    Assert-True (@(Get-ChildItem -LiteralPath $root -Filter 'event-*').Count -eq 0) 'An invalid list invoked Git.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'one'))) 'An invalid list created a clone folder.'

    [void] (New-Item -ItemType Directory -Path 'existing')
    [System.IO.File]::WriteAllText((Join-Path $root 'existing\untouched'), 'original')
    [System.IO.File]::WriteAllLines($list, @(
        'https://github.com/owner/existing.git',
        'https://github.com/owner/recover.git',
        'https://github.com/owner/one.git',
        'https://github.com/owner/two.git',
        'https://github.com/owner/three.git',
        'https://github.com/owner/four.git'
    ))
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ListPath $list 2>&1
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -eq 0) "Recovery run failed: $output"
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'access-check')) 'No foreground access check occurred.'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'recover\created-by-clone')) 'Failed clone was not retried.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $root 'existing\untouched')) -eq 'original') 'Existing folder was modified.'
    $events = @(Get-ChildItem -LiteralPath $root -Filter 'event-*' | ForEach-Object {
        $parts = [System.IO.File]::ReadAllText($_.FullName).Split('|')
        [pscustomobject]@{ Start = [long]$parts[0]; End = [long]$parts[1]; Url = $parts[2]; Terminal = $parts[3]; Gcm = $parts[4] }
    })
    Assert-True ($events.Count -eq 6) "Expected five initial clones and one retry, got $($events.Count)."
    Assert-True (@($events | Where-Object { $_.Terminal -ne '0' -or $_.Gcm -ne '0' }).Count -eq 0) 'Parallel authentication prompts were not suppressed.'
    $maximum = 0
    foreach ($event in $events) {
        $overlap = @($events | Where-Object { $_.Start -le $event.Start -and $_.End -gt $event.Start }).Count
        if ($overlap -gt $maximum) { $maximum = $overlap }
    }
    Assert-True ($maximum -ge 2 -and $maximum -le 4) "Unexpected concurrency: $maximum."

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ListPath $list 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "Second run failed: $output"
    Assert-True (@(Get-ChildItem -LiteralPath $root -Filter 'event-*').Count -eq 6) 'Existing folders were cloned again.'

    $env:CLONE_TEST_ACCESS_FAIL = '1'
    [System.IO.File]::WriteAllLines($list, @('https://github.com/owner/always-fail.git'))
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ListPath $list 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'A failed clone returned success.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'always-fail'))) 'A failed clone left its newly created folder.'
    Assert-True (($output -join "`n") -match 'Simulated clone failure') 'The clone error was not reported.'

    $strictCommand = "& { `$ErrorActionPreference = 'Stop'; & '$scriptPath' -ListPath '$list' -Concurrency 1; exit `$LASTEXITCODE }"
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $strictCommand 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'A sequential failed clone returned success.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'always-fail'))) 'A sequential failed clone was not cleaned up with Stop error preference.'

    [System.IO.File]::WriteAllLines($list, @('https://github.com/owner/sequential.git'))
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ListPath $list -Concurrency 1 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "Sequential clone failed: $output"
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'sequential\created-by-clone')) 'Sequential clone was not created.'
    $sequentialEvent = @(Get-ChildItem -LiteralPath $root -Filter 'event-*' | Where-Object {
        [System.IO.File]::ReadAllText($_.FullName) -match '/sequential\.git'
    })
    $sequentialFields = [System.IO.File]::ReadAllText($sequentialEvent[0].FullName).Split('|')
    Assert-True ($sequentialFields[3] -eq [string]$env:GIT_TERMINAL_PROMPT -and $sequentialFields[4] -eq [string]$env:GCM_INTERACTIVE) 'Sequential mode changed authentication environment variables.'

    [System.IO.File]::WriteAllText((Join-Path $root 'conflict'), 'keep')
    [System.IO.File]::WriteAllLines($list, @('https://github.com/owner/conflict.git'))
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ListPath $list 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'A file conflict returned success.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $root 'conflict')) -eq 'keep') 'Existing file was modified.'
    Write-Host 'Workflow tests passed.'
} finally {
    Pop-Location
    $env:PATH = $originalPath
    $env:CLONE_TEST_ROOT = $originalRoot
    $env:CLONE_TEST_ACCESS_FAIL = $originalFailure
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
