<#
    Claude Kullanım widget'ı için kısayolları kurar.

    İKİ kısayol oluşturulur, ikisi de aynı komutu çağırır:
      1. Başlangıç klasörü  — Windows açılışında kendiliğinden çalışsın diye.
      2. Başlat menüsü      — widget'ı KAPATTIKTAN sonra elle açabilmek için.
         Başlangıç klasörü elle açmak için uygun bir yer değil; Başlat'a
         "Claude" yazıp bulmak gerekiyor.

    Sistem ayarına, kayıt defterine dokunulmaz — yalnızca kullanıcı klasörüne
    iki .lnk dosyası yazılır.
#>

param([switch]$Masaustune)   # -Masaustune : ayrıca masaüstüne de kısayol koyar

$ErrorActionPreference = 'Stop'

$klasor = Split-Path -Parent $MyInvocation.MyCommand.Path
$betik  = Join-Path $klasor 'kullanim.ps1'
if (-not (Test-Path $betik)) { throw "kullanim.ps1 bulunamadi: $betik" }

# Neden conhost.exe üzerinden?
#
# Doğrudan powershell.exe çağrıldığında, kullanıcının varsayılan terminal
# uygulaması Windows Terminal ise konsol orada açılıyor ve `-WindowStyle
# Hidden` işe yaramıyor: PowerShell'in gizlemeye çalıştığı pencere sözde
# konsol (CASCADIA_HOSTING_WINDOW_CLASS), gerçek pencerenin sahibi Terminal.
# Sonuç: masaüstünde "Claude Kullanim" başlıklı boş bir terminal açık kalıyor.
#
# conhost.exe klasik konsol barındırıcısını zorlar; Terminal hiç devreye
# girmez ve pencere gerçekten gizli açılır. (Betiğin kendisi ayrıca
# Hide-Konsol ile konsolu gizleyip bırakıyor — bu iki savunma birlikte.)
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$arg   = "$psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$betik`""

function New-Kisayol {
    param([string]$Yol, [string]$Aciklama)
    $dizin = Split-Path -Parent $Yol
    if (-not (Test-Path $dizin)) { New-Item -ItemType Directory -Path $dizin -Force | Out-Null }

    $sh  = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($Yol)
    $lnk.TargetPath       = "$env:WINDIR\System32\conhost.exe"
    $lnk.Arguments        = $arg
    $lnk.WorkingDirectory = $klasor
    $lnk.Description      = $Aciklama
    $lnk.IconLocation     = "$env:WINDIR\System32\shell32.dll,222"
    $lnk.WindowStyle      = 7
    $lnk.Save()
    Write-Host "  $Yol"
}

$baslangic = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Kullanim.lnk'
$baslat    = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Kullanim.lnk'

Write-Host 'Kisayollar olusturuldu:' -ForegroundColor Green
New-Kisayol -Yol $baslangic -Aciklama 'Claude Kullanim - Windows acilisinda baslar'
New-Kisayol -Yol $baslat    -Aciklama 'Claude Kullanim - limit widgeti'

if ($Masaustune) {
    New-Kisayol -Yol (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Kullanim.lnk') `
                -Aciklama 'Claude Kullanim - limit widgeti'
}

Write-Host ''
Write-Host 'Widget kapandiginda: Baslat''a "Claude Kullanim" yazip acabilirsiniz.'
Write-Host 'Masaustune de istersen: .\kur-baslangic.ps1 -Masaustune'
Write-Host 'Kaldirmak icin       : .\kaldir-baslangic.ps1'
