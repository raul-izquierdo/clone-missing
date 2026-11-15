[CmdletBinding()]
param(
    [string] $ListPath,
    [ValidateRange(1, 32)]
    [int] $Concurrency = 4
)

Set-StrictMode -Version Latest

if (-not $PSBoundParameters.ContainsKey('ListPath')) {
    $ListPath = Join-Path $PSScriptRoot 'repositories.txt'
}

function Read-RepositoryList {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Repository list not found: $Path"
    }

    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)
    $repositories = New-Object 'System.Collections.Generic.List[object]'
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $identities = @{}
    $folders = @{}
    $lineNumber = 0

    foreach ($line in $lines) {
        $lineNumber++
        $url = $line.Trim()
        if ($url -eq '' -or $url.StartsWith('#')) {
            continue
        }

        $pattern = '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)(?<owner>[A-Za-z0-9-]+)/(?<repo>[A-Za-z0-9._-]+)/?$'
        if ($url -notmatch $pattern) {
            $errors.Add("Line ${lineNumber}: invalid GitHub clone URL.")
            continue
        }

        $owner = $Matches.owner
        $folder = $Matches.repo -replace '(?i)\.git$', ''
        if ($owner.Length -gt 39 -or $owner -notmatch '^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$' -or
            $folder.Length -gt 100 -or $folder -in @('', '.', '..') -or $folder.EndsWith('.') -or
            $folder -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            $errors.Add("Line ${lineNumber}: invalid owner or Windows folder name.")
            continue
        }

        $identity = "$owner/$folder"
        if ($identities.ContainsKey($identity)) {
            $errors.Add("Line ${lineNumber}: duplicate repository (line $($identities[$identity])).")
            continue
        }
        if ($folders.ContainsKey($folder)) {
            $errors.Add("Line ${lineNumber}: target folder conflicts with line $($folders[$folder]).")
            continue
        }

        $identities[$identity] = $lineNumber
        $folders[$folder] = $lineNumber
        $repositories.Add([pscustomobject]@{
            Url = $url
            Folder = $folder
            Line = $lineNumber
        })
    }

    if ($repositories.Count -eq 0 -and $errors.Count -eq 0) {
        $errors.Add('The repository list is empty.')
    }
    if ($errors.Count -gt 0) {
        throw ($errors -join [Environment]::NewLine)
    }

    return $repositories.ToArray()
}

function Remove-FailedClone {
    param([string] $Path)

    if (Test-Path -LiteralPath $Path) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        } catch {
            [Console]::Error.WriteLine("Could not clean up '${Path}': $($_.Exception.Message)")
            return $false
        }
    }
    return $true
}

function Invoke-CloneBatch {
    param(
        [object[]] $Items,
        [string] $GitPath,
        [int] $Limit
    )

    $results = New-Object 'System.Collections.Generic.List[object]'
    if ($Limit -eq 1) {
        foreach ($item in $Items) {
            Write-Host "Cloning $($item.Folder)..."
            & $GitPath clone -- $item.Url $item.Path
            $code = $LASTEXITCODE
            $results.Add([pscustomobject]@{ Item = $item; ExitCode = $code; Output = @() })
        }
        return $results.ToArray()
    }

    $active = New-Object 'System.Collections.Generic.List[object]'
    $next = 0
    try {
        while ($next -lt $Items.Count -or $active.Count -gt 0) {
            while ($next -lt $Items.Count -and $active.Count -lt $Limit) {
                $item = $Items[$next]
                Write-Host "Cloning $($item.Folder)..."
                $job = Start-Job -ArgumentList $GitPath, $item -ScriptBlock {
                    param($GitPath, $Item)
                    $ErrorActionPreference = 'Continue'
                    $env:GIT_TERMINAL_PROMPT = '0'
                    $env:GCM_INTERACTIVE = '0'
                    $output = @(& $GitPath clone -- $Item.Url $Item.Path 2>&1 | ForEach-Object { "$_" })
                    [pscustomobject]@{ Item = $Item; ExitCode = $LASTEXITCODE; Output = $output }
                }
                $active.Add([pscustomobject]@{ Job = $job; Item = $item })
                $next++
            }

            $completed = Wait-Job -Job @($active | ForEach-Object { $_.Job }) -Any
            $entry = @($active | Where-Object { $_.Job.Id -eq $completed.Id })[0]
            $output = @(Receive-Job -Job $completed)
            if ($completed.State -eq 'Completed' -and $output.Count -eq 1) {
                $results.Add($output[0])
            } else {
                $results.Add([pscustomobject]@{
                    Item = $entry.Item
                    ExitCode = -1
                    Output = @("Clone worker ended unexpectedly: $($completed.State).")
                })
            }
            [void] $active.Remove($entry)
            Remove-Job -Job $completed -Force
        }
    } finally {
        foreach ($entry in $active) {
            Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
            Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
        }
    }
    return $results.ToArray()
}

try {
    $repositories = @(Read-RepositoryList -Path $ListPath)
    Write-Host "Validated $($repositories.Count) repositories."

    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        throw 'The current location must be a filesystem directory.'
    }

    $pending = New-Object 'System.Collections.Generic.List[object]'
    $skipped = 0
    $conflicts = 0
    $cloned = 0
    $failed = New-Object 'System.Collections.Generic.List[object]'
    $cleanupFailed = $false

    foreach ($repository in $repositories) {
        $path = Join-Path $location.ProviderPath $repository.Folder
        if (Test-Path -LiteralPath $path -PathType Container) {
            Write-Host "Skipped $($repository.Folder): folder already exists."
            $skipped++
        } elseif (Test-Path -LiteralPath $path) {
            [Console]::Error.WriteLine("Conflict: '$path' already exists and is not a folder.")
            $conflicts++
        } else {
            $pending.Add([pscustomobject]@{ Url = $repository.Url; Folder = $repository.Folder; Path = $path })
        }
    }

    $results = @(Invoke-CloneBatch -Items $pending.ToArray() -GitPath $git -Limit $Concurrency)
    foreach ($result in $results) {
        if ($result.ExitCode -eq 0) {
            Write-Host "Cloned $($result.Item.Folder)."
            $cloned++
        } else {
            [Console]::Error.WriteLine("Clone failed: $($result.Item.Folder)")
            foreach ($line in $result.Output) { [Console]::Error.WriteLine($line) }
            if (-not (Remove-FailedClone -Path $result.Item.Path)) { $cleanupFailed = $true }
            $failed.Add($result.Item)
        }
    }

    if ($Concurrency -gt 1 -and $failed.Count -gt 0) {
        Write-Host 'Checking access to a failed repository; Git may ask you to sign in...'
        & $git ls-remote -- $failed[0].Url HEAD
        if ($LASTEXITCODE -eq 0) {
            $retry = @($failed | Where-Object { -not (Test-Path -LiteralPath $_.Path) })
            $retryResults = @(Invoke-CloneBatch -Items $retry -GitPath $git -Limit $Concurrency)
            foreach ($result in $retryResults) {
                if ($result.ExitCode -eq 0) {
                    Write-Host "Cloned $($result.Item.Folder) on retry."
                    $cloned++
                    $original = @($failed | Where-Object { $_.Path -eq $result.Item.Path })[0]
                    [void] $failed.Remove($original)
                } else {
                    [Console]::Error.WriteLine("Retry failed: $($result.Item.Folder)")
                    foreach ($line in $result.Output) { [Console]::Error.WriteLine($line) }
                    if (-not (Remove-FailedClone -Path $result.Item.Path)) { $cleanupFailed = $true }
                }
            }
        }
    }

    Write-Host "Results: $cloned cloned, $skipped skipped, $conflicts conflicts, $($failed.Count) failed."
    if ($conflicts -gt 0 -or $failed.Count -gt 0 -or $cleanupFailed) { exit 1 }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
