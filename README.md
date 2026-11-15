# Clone missing repositories

This Windows PowerShell 5.1 script reads a list of GitHub repository URLs and clones any repositories that are missing from the current directory. If a repository's folder already exists, the script skips it.

## Use

### Create a list of repositories

First, create a list of repositories in `repositories.txt`. Each repository URL should be the same one you would use with `git clone`.

Example `repositories.txt` contents:

```
https://github.com/raul-izquierdo/classroom-50-tools.git
https://github.com/raul-izquierdo/mlang_code.git
https://github.com/raul-izquierdo/MAPL.git
```

Blank lines and lines beginning with `#` are ignored.

### Run the script

Open PowerShell in the directory where you want the repositories, then run:

```powershell
.\clone-missing.ps1
```

When the script finishes, there will be a folder for each repository in the list that was not already present.

## Options

The script accepts the following parameters:
- `-ListPath`: Path to the list of repositories. Default is `repositories.txt`.
- `-Concurrency`: Number of concurrent clones. Default is 4.

For example, to use a custom list and run two clones concurrently:
```powershell
clone-missing.ps1 -ListPath 'my_repos.txt' -Concurrency 2
```

## Tests

From this directory, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\validation.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\workflow.tests.ps1
```

The workflow tests use a fake Git executable and temporary directories; they do not contact GitHub or access your repositories.
