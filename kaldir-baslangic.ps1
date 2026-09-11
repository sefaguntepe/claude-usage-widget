<#
    Claude Usage widget'ının kısayollarını kaldırır
    (Başlangıç + Başlat menüsü + varsa masaüstü).

    Eski adla (1.9.3 öncesi) kalmış kısayollar da temizlenir.
    Widget çalışıyorsa dokunulmaz — yalnızca kısayollar silinir.
#>

$ErrorActionPreference = 'Stop'

$adlar = @('Claude Usage.lnk', 'Claude Kullanim.lnk')
$dizinler = @(
    [Environment]::GetFolderPath('Startup'),
    [Environment]::GetFolderPath('Programs'),
    [Environment]::GetFolderPath('Desktop')
)

$silinen = 0
foreach ($d in $dizinler) {
    foreach ($a in $adlar) {
        $y = Join-Path $d $a
        if (Test-Path $y) {
            Remove-Item $y -Force
            Write-Host "Kaldirildi: $y" -ForegroundColor Green
            $silinen++
        }
    }
}

if ($silinen -eq 0) {
    Write-Host 'Kisayol bulunamadi, yapilacak bir sey kalmadi.' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host 'Not: calisan widget kapatilmadi. Kapatmak icin uzerine sag tik -> Kapat.'
}
