@echo off
echo --- Test 1: irm to var then length ---
powershell -NoProfile -ExecutionPolicy Bypass -Command "$x = irm 'https://raw.githubusercontent.com/mytech-today-now/professional-video-downloader/refs/heads/main/install-bootstrap.ps1'; Write-Host ('len=' + $x.Length); Write-Host ('type=' + $x.GetType().FullName)"
echo.
echo --- Test 2: irm piped to Measure-Object ---
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/mytech-today-now/professional-video-downloader/refs/heads/main/install-bootstrap.ps1' | Measure-Object -Character"
