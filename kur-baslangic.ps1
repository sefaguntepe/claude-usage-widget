<#
    Claude Kullanım widget'ını Windows açılışına ekler.
    Kullanıcı Başlangıç klasörüne kısayol koyar — sistem ayarına dokunmaz.
#>

$ErrorActionPreference = 'Stop'

$klasor    = Split-Path -Parent $MyInvocation.MyCommand.Path
$betik     = Join-Path $klasor 'kullanim.ps1'
$baslangic = [Environment]::GetFolderPath('Startup')
$kisayol   = Join-Path $baslangic 'Claude Kullanim.lnk'

if (-not (Test-Path $betik)) { throw "kullanim.ps1 bulunamadi: $betik" }

$sh  = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut($kisayol)
$lnk.TargetPath       = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments        = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$betik`""
$lnk.WorkingDirectory = $klasor
$lnk.Description      = 'Claude Kullanim - limit widget'
$lnk.IconLocation     = "$env:WINDIR\System32\shell32.dll,222"
$lnk.WindowStyle      = 7
$lnk.Save()

Write-Host 'Baslangica eklendi:' -ForegroundColor Green
Write-Host "  $kisayol"
Write-Host 'Kaldirmak icin: kaldir-baslangic.ps1'
