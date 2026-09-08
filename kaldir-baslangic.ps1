<#
    Claude Kullanım widget'ını Windows açılışından çıkarır.
#>

$ErrorActionPreference = 'Stop'

$kisayol = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Kullanim.lnk'

if (Test-Path $kisayol) {
    Remove-Item $kisayol -Force
    Write-Host "Baslangictan kaldirildi: $kisayol" -ForegroundColor Green
} else {
    Write-Host 'Baslangicta kayit yok, yapilacak bir sey kalmadi.' -ForegroundColor Yellow
}
