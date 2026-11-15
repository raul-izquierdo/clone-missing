@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-git.ps1" %*
@exit /b %errorlevel%
