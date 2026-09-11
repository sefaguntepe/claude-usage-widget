<#
    Claude Kullanım widget'ının kısayollarını kaldırır
    (Başlangıç + Başlat menüsü + varsa masaüstü).

    Widget çalışıyorsa dokunulmaz — yalnızca kısayollar silinir.
#>

$ErrorActionPreference = 'Stop'

$yollar = @(
    (Join-Path ([Environment]::GetFolderPath('Startup'))  'Claude Kullanim.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Kullanim.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop'))  'Claude Kullanim.lnk')
)

$silinen = 0
foreach ($y in $yollar) {
    if (Test-Path $y) {
        Remove-Item $y -Force
        Write-Host "Kaldirildi: $y" -ForegroundColor Green
        $silinen++
    }
}

if ($silinen -eq 0) {
    Write-Host 'Kisayol bulunamadi, yapilacak bir sey kalmadi.' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host 'Not: calisan widget kapatilmadi. Kapatmak icin uzerine sag tik -> Kapat.'
}
