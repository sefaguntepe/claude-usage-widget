<#
    Claude Usage widget'ı için kısayolları kurar.

    İKİ kısayol oluşturulur, ikisi de aynı komutu çağırır:
      1. Başlangıç klasörü  — Windows açılışında kendiliğinden çalışsın diye.
         (Bunu widget'ın sağ tık menüsünden de açıp kapatabilirsiniz.)
      2. Başlat menüsü      — widget'ı KAPATTIKTAN sonra elle açabilmek için.
         Başlangıç klasörü elle açmak için uygun bir yer değil; Başlat'a
         "Claude Usage" yazıp bulmak gerekiyor.

    Sistem ayarına, kayıt defterine dokunulmaz — yalnızca kullanıcı klasörüne
    .lnk dosyaları yazılır.
#>

param([switch]$Masaustune)   # -Masaustune : ayrıca masaüstüne de kısayol koyar

$ErrorActionPreference = 'Stop'

$klasor = Split-Path -Parent $MyInvocation.MyCommand.Path
$betik  = Join-Path $klasor 'kullanim.ps1'
if (-not (Test-Path $betik)) { throw "kullanim.ps1 bulunamadi: $betik" }

$KISAYOL_ADI = 'Claude Usage.lnk'
$ESKI_ADLAR  = @('Claude Kullanim.lnk')   # 1.9.3 öncesi ad — temizlenir
$ikon = Join-Path $klasor 'claude-usage.ico'

# Neden conhost.exe üzerinden?
#
# Doğrudan powershell.exe çağrıldığında, kullanıcının varsayılan terminal
# uygulaması Windows Terminal ise konsol orada açılıyor ve `-WindowStyle
# Hidden` işe yaramıyor: PowerShell'in gizlemeye çalıştığı pencere sözde
# konsol (CASCADIA_HOSTING_WINDOW_CLASS), gerçek pencerenin sahibi Terminal.
# Sonuç: masaüstünde başlıksız boş bir terminal açık kalıyor.
#
# conhost.exe klasik konsol barındırıcısını zorlar; Terminal hiç devreye
# girmez ve pencere gerçekten gizli açılır. (Betiğin kendisi ayrıca
# Hide-Konsol ile konsolu gizleyip bırakıyor — bu iki savunma birlikte.)
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$arg   = "$psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$betik`""

function New-Kisayol {
    param([string]$Dizin, [string]$Aciklama)

    if (-not (Test-Path $Dizin)) { New-Item -ItemType Directory -Path $Dizin -Force | Out-Null }
    # Eski adla kalmış kısayolu bırakma: yoksa Başlat'ta iki kayıt görünür.
    foreach ($eski in $ESKI_ADLAR) {
        $y = Join-Path $Dizin $eski
        if (Test-Path $y) { Remove-Item $y -Force; Write-Host "  (eski kaldirildi) $y" -ForegroundColor DarkGray }
    }

    $yol = Join-Path $Dizin $KISAYOL_ADI
    $sh  = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($yol)
    $lnk.TargetPath       = "$env:WINDIR\System32\conhost.exe"
    $lnk.Arguments        = $arg
    $lnk.WorkingDirectory = $klasor
    $lnk.Description      = $Aciklama
    $lnk.IconLocation     = $(if (Test-Path $ikon) { $ikon } else { "$env:WINDIR\System32\shell32.dll,222" })
    $lnk.WindowStyle      = 7
    $lnk.Save()
    Write-Host "  $yol"
}

Write-Host 'Kisayollar:' -ForegroundColor Green
New-Kisayol -Dizin ([Environment]::GetFolderPath('Startup'))  -Aciklama 'Claude Usage - Windows acilisinda baslar'
New-Kisayol -Dizin ([Environment]::GetFolderPath('Programs')) -Aciklama 'Claude Usage - limit widgeti'
if ($Masaustune) {
    New-Kisayol -Dizin ([Environment]::GetFolderPath('Desktop')) -Aciklama 'Claude Usage - limit widgeti'
}

Write-Host ''
Write-Host 'Widget kapandiginda : Baslat''a "Claude Usage" yazip acabilirsiniz.'
Write-Host 'Acilista baslatmayi : widgete sag tik -> Acilista baslat'
Write-Host 'Masaustune de       : .\kur-baslangic.ps1 -Masaustune'
Write-Host 'Kaldirmak icin      : .\kaldir-baslangic.ps1'
