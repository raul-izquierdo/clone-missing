$operation = $args[0]
$url = $args[2]
$root = $env:CLONE_TEST_ROOT

if ($operation -eq 'ls-remote') {
    [System.IO.File]::WriteAllText((Join-Path $root 'access-check'), $url)
    if ($env:CLONE_TEST_ACCESS_FAIL -eq '1') {
        [Console]::Error.WriteLine('Access denied')
        exit 1
    }
    [System.IO.File]::WriteAllText((Join-Path $root 'authenticated'), 'yes')
    exit 0
}

if ($operation -ne 'clone') { exit 2 }
$target = $args[3]
$started = [DateTime]::UtcNow.Ticks
[System.Threading.Thread]::Sleep(700)
[void] (New-Item -ItemType Directory -Path $target -Force)
[System.IO.File]::WriteAllText((Join-Path $target 'created-by-clone'), $url)
$exitCode = 0
if ($url -match '/always-fail(?:\.git)?$' -or
    ($url -match '/recover(?:\.git)?$' -and -not (Test-Path -LiteralPath (Join-Path $root 'authenticated')))) {
    [Console]::Error.WriteLine('Simulated clone failure')
    $exitCode = 1
}
$event = '{0}|{1}|{2}|{3}|{4}' -f $started, [DateTime]::UtcNow.Ticks, $url, $env:GIT_TERMINAL_PROMPT, $env:GCM_INTERACTIVE
[System.IO.File]::WriteAllText((Join-Path $root ("event-{0}" -f [guid]::NewGuid())), $event)
exit $exitCode
