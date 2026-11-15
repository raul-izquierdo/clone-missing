$ErrorActionPreference = 'Continue'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'clone-missing.ps1'
$listPath = Join-Path ([System.IO.Path]::GetTempPath()) ("clone-missing-list-{0}.txt" -f [guid]::NewGuid())
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("clone-missing-validation-{0}" -f [guid]::NewGuid())

try {
    [void] (New-Item -ItemType Directory -Path $testDirectory)
    $defaultList = Join-Path (Split-Path $PSScriptRoot -Parent) 'repositories.txt'
    foreach ($url in Get-Content -LiteralPath $defaultList) {
        $folder = [System.IO.Path]::GetFileNameWithoutExtension($url)
        [void] (New-Item -ItemType Directory -Path (Join-Path $testDirectory $folder))
    }
    Push-Location $testDirectory
    $output = & powershell.exe -NoProfile -File $scriptPath 2>&1
    if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'Validated 31 repositories') {
        throw "The supplied list failed validation: $output"
    }

    [System.IO.File]::WriteAllLines($listPath, @(
        'https://github.com/owner/repo.git',
        'git@github.com:OWNER/REPO',
        'https://example.com/owner/repo.git',
        'https://github.com/another/repo.git',
        'https://github.com/owner/CON.git'
    ))
    $output = & powershell.exe -NoProfile -File $scriptPath -ListPath $listPath 2>&1
    if ($LASTEXITCODE -eq 0) {
        throw 'Invalid list unexpectedly passed validation.'
    }
    $text = $output -join "`n"
    foreach ($expected in @('Line 2: duplicate', 'Line 3: invalid', 'Line 4: target folder conflicts', 'Line 5: invalid')) {
        if ($text -notmatch [regex]::Escape($expected)) {
            throw "Missing validation error '$expected': $text"
        }
    }
    Write-Host 'Validation tests passed.'
} finally {
    Pop-Location
    Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $listPath -Force -ErrorAction SilentlyContinue
}
