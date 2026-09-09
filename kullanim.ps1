#requires -Version 5.1
<#
    Claude Kullanım  —  masaüstü limit widget'ı
    Sefa Güntepe

    Veriyi %APPDATA%\ClaudeKullanim\durum.json'dan okur; o dosyayı Claude Code'un
    statusLine betiği (durum-yaz.js) yazar. Kendisi ağa çıkmaz, token okumaz.

    Pencere yaklaşımı masaüstü saat widget'ı ile aynı: normal üst düzey pencere
    ama WS_EX_NOACTIVATE + WS_EX_TOOLWINDOW + düzenli HWND_BOTTOM.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Add-Type -Namespace Widget -Name Win32K -MemberDefinition @'
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    // Sag tik menusunu kapatma nobetcisi icin. GetKeyState degil
    // GetAsyncKeyState: ilki mesaj kuyrugu baglamina muhtac, pencere odak
    // almadigi icin bizde guvenilir calismaz.
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT p);

    [DllImport("user32.dll")]
    public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
'@

# Pencereyi z-sırasının dibinde tutmanın DOĞRU yolu.
#
# Önceki sürüm bunu 2 saniyede bir SetWindowPos çağırarak yapıyordu ve
# masaüstünü kullanılamaz hâle getiriyordu: sağ tık menüsü açılıyor, ilk
# yoklamada kapanıyordu; simge seçmek için sürüklenen çerçeve de bozuluyordu.
#
# Doğrusu yoklama değil, olay yakalamak: Windows pencerenin konumunu/z-sırasını
# değiştirmek üzereyken WM_WINDOWPOSCHANGING gönderir. O mesajdaki
# hwndInsertAfter alanını HWND_BOTTOM yapıp SWP_NOZORDER bayrağını temizlemek
# yeterli. Böylece pencere kendiliğinden dipte kalır ve masaüstüne hiç
# dokunulmaz.
Add-Type -ReferencedAssemblies WindowsBase, PresentationCore -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

public static class ZDuzeni
{
    const int WM_WINDOWPOSCHANGING = 0x0046;
    const int SWP_NOZORDER = 0x0004;

    // Kart temasi masaustu seviyesinde durur (dipte = true). Serit temasi ise
    // gorev cubugunun UZERINE binen bir katman; orada tam tersi gerekiyor:
    // z-duzeni her degistiginde tepeye geri yazilmali, yoksa gorev cubuguna
    // tiklandiginda explorer kendini one alip seridi ortuyor.
    //
    // Iki yon de AYNI kanca ile hallediliyor; yoklama (polling) yok. Onceki
    // surumdeki 2 saniyelik SetWindowPos dongusu masaustu sag tik menusunu ve
    // simge secimini bozuyordu - o hataya geri donmeyelim.
    public static bool Dipte = true;

    static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_WINDOWPOSCHANGING)
        {
            // WINDOWPOS: hwnd, hwndInsertAfter, x, y, cx, cy, flags
            IntPtr hedef = Dipte ? (IntPtr)1 : (IntPtr)(-1);   // HWND_BOTTOM / HWND_TOPMOST
            Marshal.WriteIntPtr(lParam, IntPtr.Size, hedef);
            int bayrakOfset = IntPtr.Size * 2 + 16;
            int bayraklar = Marshal.ReadInt32(lParam, bayrakOfset);
            Marshal.WriteInt32(lParam, bayrakOfset, bayraklar & ~SWP_NOZORDER);
        }
        return IntPtr.Zero;
    }

    public static void Bagla(IntPtr hwnd)
    {
        HwndSource src = HwndSource.FromHwnd(hwnd);
        if (src != null) src.AddHook(new HwndSourceHook(Hook));
    }
}
'@

$GWL_EXSTYLE       = -20
$WS_EX_TOOLWINDOW  = 0x00000080
$WS_EX_NOACTIVATE  = 0x08000000
$HWND_BOTTOM       = [IntPtr]1     # 8 degil
$SW_SHOWNOACTIVATE = 4
$SWP_NOSIZE        = 0x0001
$SWP_NOMOVE        = 0x0002
$SWP_NOACTIVATE    = 0x0010

# ─────────────────────────────────────────────────────────────────────────────
# Dosyalar
# ─────────────────────────────────────────────────────────────────────────────
$VeriKlasor  = Join-Path $env:APPDATA 'ClaudeKullanim'
$DurumDosya  = Join-Path $VeriKlasor 'durum.json'      # statusLine yazar
$OlayDosya   = Join-Path $VeriKlasor 'olay.json'       # hook'lar yazar
$AyarDosya   = Join-Path $VeriKlasor 'pencere.json'    # widget yazar

# İkinci kaynak: Claude MASAÜSTÜ uygulamasının kendi kullanım geçmişi. Uygulama
# açıkken 15 dakikada bir claude.ai'den yüzdeleri çekip buraya ekliyor
# (tepsi/plan kullanımı özelliği için). Biz yalnızca OKURUZ: kimlik bilgisi
# yok, ağ isteği yok, dosyaya yazma yok. Terminal oturumu olmadan da güncel
# kalmanın tek güvenli yolu bu. Biçim belgelenmemiş (sürüm 2, alanlar
# t/org/u.fh/u.sd) — uymayan dosya sessizce yok sayılır, statusLine'a düşülür.
$MasaustuDosya = Join-Path $env:APPDATA 'Claude\plan-usage-history.json'

$OLAY_OMUR_SN  = 900    # olay satırı 15 dk sonra kaybolur
$YANIP_SONME_SN = 12    # ilk 12 saniye dikkat çeksin diye yanıp söner
$COK_BAYAT_SN  = 43200  # 12 saatten eskiyse sebebini de yaz

# Bar rayının genişliği. XAML'deki iki Border Width'i ve Kok.Width ile AYNI
# olmalı. 232 + 2×18 kapsül dolgusu = 268 → masaüstü saat widget'ı ile aynı en.
$IZ_GENISLIK = 232.0
$BAYAT_SN    = 300      # 5 dk'dan eski veri "bayat" sayılır
$MASAUSTU_BAYAT_SN = 1200   # masaüstü 15 dk'da bir örnekler (+5 dk pay); ötesi bayat
$MASAUSTU_HIZ_DK   = 60     # tüketim hızı için geriye bakış (15 dk'lık örneklerle 45 dk çok dar)

$ArkaPlanlar = @{ yok = '#00000000'; hafif = '#59000000'; koyu = '#A6000000' }

function Get-Ayarlar {
    # esik5 / esikH : uyarı eşiği yüzdesi, 0 = kapalı
    # atesli5 / atesliH : uyarının verildiği pencerenin resets_at değeri.
    #   Pencere kimliği olarak resets_at kullanılıyor — yeni pencere başlayınca
    #   değer değişir ve uyarı hakkı kendiliğinden tazelenir. Zaman damgası
    #   tutup "24 saat geçti mi" diye bakmaktan daha doğru: kullanıcı için
    #   anlamlı sınır takvim değil, kotanın sıfırlanma anıdır.
    $v = [ordered]@{ sol = $null; ust = $null; arkaPlan = 'hafif'
                     esik5 = 0; esikH = 0; atesli5 = $null; atesliH = $null
                     tema = 'kart'; seritSol = $null; seritUst = $null }
    if (Test-Path $AyarDosya) {
        try {
            $j = Get-Content $AyarDosya -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @('sol', 'ust', 'arkaPlan', 'esik5', 'esikH', 'atesli5', 'atesliH',
                             'tema', 'seritSol', 'seritUst')) {
                if ($j.PSObject.Properties.Name -contains $k -and $null -ne $j.$k) { $v[$k] = $j.$k }
            }
        } catch { }
    }
    [pscustomobject]$v
}

function Save-Ayarlar {
    param($Ayar)
    try {
        if (-not (Test-Path $VeriKlasor)) { New-Item -ItemType Directory -Path $VeriKlasor -Force | Out-Null }
        $Ayar | ConvertTo-Json | Set-Content -Path $AyarDosya -Encoding UTF8
    } catch { }
}

# ─────────────────────────────────────────────────────────────────────────────
# Biçimlendirme
# ─────────────────────────────────────────────────────────────────────────────
function Format-Kalan {
    param([Nullable[datetime]]$Sifirlanma)
    if ($null -eq $Sifirlanma) { return '' }
    $fark = $Sifirlanma - [DateTime]::Now
    if ($fark.TotalSeconds -le 0) { return (T 'SIFIRLANDI') }
    if ($fark.TotalMinutes -lt 1) { return (T 'BIRAZDAN') }
    if ($fark.TotalHours -lt 1)   { return ((T 'KALAN_DK') -f [int]$fark.TotalMinutes) }
    return ((T 'KALAN_SADK') -f [int]$fark.TotalHours, ($fark.Minutes))
}

function Format-Yas {
    param([datetime]$Zaman)
    $fark = [DateTime]::Now - $Zaman
    if ($fark.TotalSeconds -lt 90)  { return (T 'YAS_SIMDI') }
    if ($fark.TotalMinutes -lt 60)  { return ((T 'YAS_DK') -f [int]$fark.TotalMinutes) }
    if ($fark.TotalHours -lt 24)    { return ((T 'YAS_SA') -f [int]$fark.TotalHours) }
    return ((T 'YAS_GUN') -f [int]$fark.TotalDays)
}

# Bar rengi. Sadece doluluğa değil TÜKETİM HIZINA da bakar: pencere
# sıfırlanmadan önce bitecek gibiyse doluluk düşük olsa bile kırmızı yanar.
# ("%60 dolu ama son 20 dakikada %30 yendi" durumu asıl tehlikeli olandır.)
function Get-BarRengi {
    param([double]$Yuzde, [Nullable[datetime]]$Sifirlanma, $BitisDk)

    if ($null -ne $BitisDk -and $null -ne $Sifirlanma) {
        $kalanDk = ($Sifirlanma - [DateTime]::Now).TotalMinutes
        if ($kalanDk -gt 0 -and [double]$BitisDk -lt $kalanDk) { return '#E5484D' }
    }
    if ($Yuzde -ge 90) { return '#E5484D' }   # kırmızı
    if ($Yuzde -ge 75) { return '#E8A33D' }   # amber
    return '#4C8DF6'                          # mavi
}

function Format-Sure {
    param([int]$Dakika)
    if ($Dakika -lt 60) { return ((T 'SURE_DK') -f $Dakika) }
    return ((T 'SURE_SADK') -f [int]($Dakika / 60), ($Dakika % 60))
}

# Gün kısaltmaları dile göre. Fonksiyon olarak duruyor çünkü $DIL bu satırdan
# sonra tanımlanıyor; çağrı anında okumak sıralamaya bağımlılığı kaldırıyor.
function Get-GunKisa {
    param([string]$Gun)
    $tablo = @{
        tr = @{ Monday='Pt'; Tuesday='Sa'; Wednesday='Ça'; Thursday='Pe'; Friday='Cu'; Saturday='Ct'; Sunday='Pa' }
        en = @{ Monday='Mo'; Tuesday='Tu'; Wednesday='We'; Thursday='Th'; Friday='Fr'; Saturday='Sa'; Sunday='Su' }
    }
    return $tablo[$DIL][$Gun]
}

# ─────────────────────────────────────────────────────────────────────────────
# Dil — Windows görüntü diline göre otomatik (yalnızca tr / en)
# ─────────────────────────────────────────────────────────────────────────────
$DIL = if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'tr') { 'tr' } else { 'en' }
$Kultur = [System.Globalization.CultureInfo]::GetCultureInfo($(if ($DIL -eq 'tr') { 'tr-TR' } else { 'en-US' }))

$METINLER = @{
    tr = @{
        MENU_ARKAPLAN='Arka plan'; MENU_YOK='Yok (tam şeffaf)'; MENU_HAFIF='Hafif'; MENU_KOYU='Koyu'
        MENU_ESIK='Uyarı eşiği'; MENU_5SAAT='5 saatlik limit'; MENU_HAFTA='Haftalık'
        MENU_SIFIRLA='Konumu sıfırla (sağ üst)'; MENU_KAPAT='Kapat'; MENU_KAPALI='Kapalı'
        MENU_TEMA='Görünüm'; TEMA_KART='Kart'; TEMA_SERIT='Şerit (alt bar)'
        SERIT_5SA='5sa'; SERIT_HAFTA='hafta'
        BASLIK='CLAUDE KULLANIM'; ETIKET_5SAAT='5 saatlik limit'; ETIKET_HAFTA='Haftalık'
        SON7='SON 7 GÜN'; BUGUN='bugün {0:0.0}×'; CANLI='canlı'; TAMAM='Tamam'; KAYNAK_MASAUSTU='masaüstü'
        SONRASI_KULLANIM='Ölçümden sonra Claude en az bir tur bitirdi — gerçek değer bundan yüksek.'
        SIFIRLANDI='sıfırlandı'; BIRAZDAN='birazdan sıfırlanır'
        KALAN_DK='{0} dk sonra'; KALAN_SADK='{0} sa {1} dk sonra'
        YAS_SIMDI='az önce'; YAS_DK='{0} dk önce'; YAS_SA='{0} sa önce'; YAS_GUN='{0} gün önce'
        SURE_DK='{0} dk'; SURE_SADK='{0} sa {1} dk'
        HIZ_UYARI='Bu hızla ~{0} içinde biter'
        VERI_YOK='Henüz veri yok. Claude masaüstü uygulaması ya da terminalde Claude Code açılınca dolar.'
        VERI_BAYAT='Veri tazelenmiyor: ne Claude masaüstü uygulaması ne de terminal Claude Code oturumu açık görünüyor.'
        OLAY_BITTI='Claude bitirdi'; OLAY_IZIN='İzin bekliyor'; OLAY_GIRDI='Girdi bekliyor'
        OLAY_AJAN_GIRDI='Ajan girdi bekliyor'; OLAY_AJAN_BITTI='Ajan tamamlandı'; OLAY_BEKLIYOR='Claude sizi bekliyor'
        UYARI_BASLIK='Kullanım uyarısı'; UYARI_METIN='{0} %{1:0} seviyesine ulaştı (eşik %{2}).'
        UYARI_SIFIRLANMA='Sıfırlanma: {0}'
        ESIK_5SAAT='5 saatlik limit'; ESIK_HAFTA='Haftalık limit'
    }
    en = @{
        MENU_ARKAPLAN='Background'; MENU_YOK='None (transparent)'; MENU_HAFIF='Light'; MENU_KOYU='Dark'
        MENU_ESIK='Alert threshold'; MENU_5SAAT='5-hour limit'; MENU_HAFTA='Weekly'
        MENU_SIFIRLA='Reset position (top right)'; MENU_KAPAT='Close'; MENU_KAPALI='Off'
        MENU_TEMA='Appearance'; TEMA_KART='Card'; TEMA_SERIT='Strip (taskbar)'
        SERIT_5SA='5h'; SERIT_HAFTA='week'
        BASLIK='CLAUDE USAGE'; ETIKET_5SAAT='5-hour limit'; ETIKET_HAFTA='Weekly'
        SON7='LAST 7 DAYS'; BUGUN='today {0:0.0}×'; CANLI='live'; TAMAM='OK'; KAYNAK_MASAUSTU='desktop'
        SONRASI_KULLANIM='Claude finished at least one turn after this measurement — the real value is higher.'
        SIFIRLANDI='reset'; BIRAZDAN='resetting shortly'
        KALAN_DK='in {0} min'; KALAN_SADK='in {0} h {1} min'
        YAS_SIMDI='just now'; YAS_DK='{0} min ago'; YAS_SA='{0} h ago'; YAS_GUN='{0} d ago'
        SURE_DK='{0} min'; SURE_SADK='{0} h {1} min'
        HIZ_UYARI='At this rate it runs out in ~{0}'
        VERI_YOK='No data yet. It fills once the Claude desktop app or a terminal Claude Code session is running.'
        VERI_BAYAT='Not refreshing: neither the Claude desktop app nor a terminal Claude Code session seems to be running.'
        OLAY_BITTI='Claude finished'; OLAY_IZIN='Waiting for permission'; OLAY_GIRDI='Waiting for input'
        OLAY_AJAN_GIRDI='Agent needs input'; OLAY_AJAN_BITTI='Agent completed'; OLAY_BEKLIYOR='Claude is waiting for you'
        UYARI_BASLIK='Usage alert'; UYARI_METIN='{0} reached {1:0}% (threshold {2}%).'
        UYARI_SIFIRLANMA='Resets: {0}'
        ESIK_5SAAT='5-hour limit'; ESIK_HAFTA='Weekly limit'
    }
}

function T { param([string]$Anahtar) return $METINLER[$DIL][$Anahtar] }

# ─────────────────────────────────────────────────────────────────────────────
# Arayüz
# ─────────────────────────────────────────────────────────────────────────────
$xamlMetin = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Kullanim"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="False" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight" WindowStartupLocation="Manual"
        UseLayoutRounding="True" TextOptions.TextRenderingMode="ClearType">

  <Window.ContextMenu>
    <ContextMenu>
      <MenuItem Header="@@MENU_ARKAPLAN@@">
        <MenuItem x:Name="MnuBgYok"   Header="@@MENU_YOK@@" IsCheckable="True"/>
        <MenuItem x:Name="MnuBgHafif" Header="@@MENU_HAFIF@@"            IsCheckable="True"/>
        <MenuItem x:Name="MnuBgKoyu"  Header="@@MENU_KOYU@@"             IsCheckable="True"/>
      </MenuItem>
      <MenuItem Header="@@MENU_TEMA@@">
        <MenuItem x:Name="MnuTemaKart"  Header="@@TEMA_KART@@"  IsCheckable="True"/>
        <MenuItem x:Name="MnuTemaSerit" Header="@@TEMA_SERIT@@" IsCheckable="True"/>
      </MenuItem>
      <MenuItem Header="@@MENU_ESIK@@">
        <MenuItem x:Name="MnuEsik5" Header="@@MENU_5SAAT@@"/>
        <MenuItem x:Name="MnuEsikH" Header="@@MENU_HAFTA@@"/>
      </MenuItem>
      <Separator/>
      <MenuItem x:Name="MnuSifirla" Header="@@MENU_SIFIRLA@@"/>
      <MenuItem x:Name="MnuKapat"   Header="@@MENU_KAPAT@@"/>
    </ContextMenu>
  </Window.ContextMenu>

  <Grid>
  <!-- ŞERİT (alt bar) teması: görev çubuğunun üstünde iki satırlık ince katman.
       5 saatlik ve haftalık ALT ALTA: yan yana dizilim 48 px'lik çubukta hem
       uzun hem de tek bakışta okunmuyordu. -->
  <Border x:Name="SeritKapsul" Visibility="Collapsed" CornerRadius="7" Padding="10,3,12,4"
          Background="#D91C1F26" BorderBrush="#26FFFFFF" BorderThickness="1">
    <Grid VerticalAlignment="Center">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <TextBlock Grid.RowSpan="2" Text="CLAUDE" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold"
                 Foreground="#E8EDF5" Opacity="0.5" VerticalAlignment="Center" Margin="0,0,10,0"/>

      <!-- 1. satır: 5 saat -->
      <TextBlock Grid.Row="0" Grid.Column="1" Text="@@SERIT_5SA@@" FontFamily="Segoe UI" FontSize="9.5"
                 Foreground="#E8EDF5" Opacity="0.55" VerticalAlignment="Center" TextAlignment="Right" Margin="0,0,6,0"/>
      <Border Grid.Row="0" Grid.Column="2" Width="70" Height="4" CornerRadius="2" Background="#26FFFFFF" VerticalAlignment="Center">
        <Border x:Name="Serit5Dolgu" Width="0" CornerRadius="2" HorizontalAlignment="Left" Background="#4C8DF6"/>
      </Border>
      <TextBlock Grid.Row="0" Grid.Column="3" x:Name="Serit5Yuzde" FontFamily="Segoe UI" FontSize="10.5" FontWeight="SemiBold"
                 Foreground="#F0F4FA" VerticalAlignment="Center" MinWidth="32" TextAlignment="Right" Margin="6,0,0,0"
                 Typography.NumeralAlignment="Tabular"/>
      <TextBlock Grid.Row="0" Grid.Column="4" x:Name="SeritKalan" FontFamily="Segoe UI" FontSize="9.5"
                 Foreground="#E8EDF5" Opacity="0.55" VerticalAlignment="Center" Margin="10,0,0,0"/>

      <!-- 2. satır: hafta -->
      <TextBlock Grid.Row="1" Grid.Column="1" Text="@@SERIT_HAFTA@@" FontFamily="Segoe UI" FontSize="9.5"
                 Foreground="#E8EDF5" Opacity="0.55" VerticalAlignment="Center" TextAlignment="Right" Margin="0,1,6,0"/>
      <Border Grid.Row="1" Grid.Column="2" Width="70" Height="4" CornerRadius="2" Background="#26FFFFFF" VerticalAlignment="Center" Margin="0,1,0,0">
        <Border x:Name="SeritHDolgu" Width="0" CornerRadius="2" HorizontalAlignment="Left" Background="#4C8DF6"/>
      </Border>
      <TextBlock Grid.Row="1" Grid.Column="3" x:Name="SeritHYuzde" FontFamily="Segoe UI" FontSize="10.5" FontWeight="SemiBold"
                 Foreground="#F0F4FA" VerticalAlignment="Center" MinWidth="32" TextAlignment="Right" Margin="6,1,0,0"
                 Typography.NumeralAlignment="Tabular"/>
      <TextBlock Grid.Row="1" Grid.Column="4" x:Name="SeritYas" FontFamily="Segoe UI" FontSize="9" Foreground="#E8A33D"
                 VerticalAlignment="Center" Margin="10,1,0,0"/>
    </Grid>
  </Border>

  <Border x:Name="Kapsul" CornerRadius="16" Padding="18,13,18,15" Background="#59000000">
    <StackPanel x:Name="Kok" Width="232">
      <StackPanel.Effect>
        <DropShadowEffect BlurRadius="7" ShadowDepth="0" Opacity="0.9" Color="#FF000000"/>
      </StackPanel.Effect>

      <!-- baslik -->
      <Grid Margin="0,0,0,10">
        <TextBlock Text="@@BASLIK@@" FontFamily="Segoe UI" FontSize="9.5"
                   FontWeight="SemiBold" Foreground="#E8EDF5" Opacity="0.55"/>
        <TextBlock x:Name="Yas" HorizontalAlignment="Right" FontFamily="Segoe UI"
                   FontSize="9.5" Foreground="#E8EDF5" Opacity="0.45"/>
      </Grid>

      <!-- 5 saatlik limit -->
      <Grid Margin="0,0,0,5">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="@@ETIKET_5SAAT@@" FontFamily="Segoe UI" FontSize="11.5"
                   Foreground="#F0F4FA"/>
        <TextBlock x:Name="Sifir5" Grid.Column="1" FontFamily="Segoe UI" FontSize="10.5"
                   Foreground="#E8EDF5" Opacity="0.5" TextAlignment="Right" Margin="10,1,10,0"/>
        <TextBlock x:Name="Yuzde5" Grid.Column="2" FontFamily="Segoe UI" FontSize="11.5"
                   FontWeight="SemiBold" Foreground="#F0F4FA" TextAlignment="Right" MinWidth="34"
                   Typography.NumeralAlignment="Tabular"/>
      </Grid>
      <Border Width="232" Height="5" CornerRadius="2.5" Background="#26FFFFFF" HorizontalAlignment="Left">
        <Border x:Name="Dolgu5" Width="0" CornerRadius="2.5" HorizontalAlignment="Left" Background="#4C8DF6"/>
      </Border>

      <!-- haftalik limit -->
      <Grid Margin="0,14,0,5">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="@@ETIKET_HAFTA@@" FontFamily="Segoe UI" FontSize="11.5"
                   Foreground="#F0F4FA"/>
        <TextBlock x:Name="SifirH" Grid.Column="1" FontFamily="Segoe UI" FontSize="10.5"
                   Foreground="#E8EDF5" Opacity="0.5" TextAlignment="Right" Margin="10,1,10,0"/>
        <TextBlock x:Name="YuzdeH" Grid.Column="2" FontFamily="Segoe UI" FontSize="11.5"
                   FontWeight="SemiBold" Foreground="#F0F4FA" TextAlignment="Right" MinWidth="34"
                   Typography.NumeralAlignment="Tabular"/>
      </Grid>
      <Border Width="232" Height="5" CornerRadius="2.5" Background="#26FFFFFF" HorizontalAlignment="Left">
        <Border x:Name="DolguH" Width="0" CornerRadius="2.5" HorizontalAlignment="Left" Background="#4C8DF6"/>
      </Border>

      <!-- tuketim hizi uyarisi -->
      <TextBlock x:Name="HizUyari" FontFamily="Segoe UI" FontSize="10" Foreground="#E5484D"
                 Margin="0,9,0,0" Visibility="Collapsed" TextWrapping="Wrap" MaxWidth="232"/>

      <!-- son 7 gun -->
      <StackPanel x:Name="HaftaBolum" Margin="0,14,0,0" Visibility="Collapsed">
        <Grid>
          <TextBlock Text="@@SON7@@" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold"
                     Foreground="#E8EDF5" Opacity="0.45"/>
          <TextBlock x:Name="BugunOzet" HorizontalAlignment="Right" FontFamily="Segoe UI"
                     FontSize="9" Foreground="#E8EDF5" Opacity="0.45"/>
        </Grid>
        <Grid Margin="0,6,0,0" Width="232" HorizontalAlignment="Left">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid Grid.Column="0">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub0" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="#4C8DF6"/>
            <TextBlock x:Name="Etk0" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="#E8EDF5" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="1">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub1" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="#4C8DF6"/>
            <TextBlock x:Name="Etk1" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="#E8EDF5" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="2">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub2" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="#4C8DF6"/>
            <TextBlock x:Name="Etk2" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="#E8EDF5" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="3">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub3" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="#4C8DF6"/>
            <TextBlock x:Name="Etk3" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="#E8EDF5" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="4">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub4" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="#4C8DF6"/>
            <TextBlock x:Name="Etk4" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="#E8EDF5" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="5">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub5" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="#4C8DF6"/>
            <TextBlock x:Name="Etk5" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="#E8EDF5" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="6">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub6" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="#4C8DF6"/>
            <TextBlock x:Name="Etk6" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="#E8EDF5" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
        </Grid>
      </StackPanel>

      <!-- olay satiri: Claude bitirdi / izin bekliyor -->
      <Border x:Name="OlayKutu" Visibility="Collapsed" Margin="0,13,0,0" CornerRadius="7"
              Padding="9,6,9,6" Background="#1F3BD16F" Width="232">
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="OlayIkon" FontFamily="Segoe MDL2 Assets" FontSize="12"
                     VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#3BD16F"/>
          <StackPanel VerticalAlignment="Center">
            <TextBlock x:Name="OlayMetin" FontFamily="Segoe UI" FontSize="10.5"
                       Foreground="#EAF3EC" TextTrimming="CharacterEllipsis" MaxWidth="186"/>
            <TextBlock x:Name="OlayAlt" FontFamily="Segoe UI" FontSize="9.5" Opacity="0.6"
                       Foreground="#EAF3EC" TextTrimming="CharacterEllipsis" MaxWidth="186"
                       Margin="0,1,0,0"/>
          </StackPanel>
        </StackPanel>
      </Border>

      <!-- veri yoksa -->
      <TextBlock x:Name="Uyari" FontFamily="Segoe UI" FontSize="10.5" Foreground="#E8A33D"
                 Opacity="0.85" Margin="0,11,0,0" Visibility="Collapsed" TextWrapping="Wrap"
                 MaxWidth="232"/>
    </StackPanel>
  </Border>
  </Grid>
</Window>
'@

# XAML'deki @@ANAHTAR@@ yer tutucuları dile göre dolduruluyor. Böylece her
# metin öğesine x:Name verip koddan tek tek atamak gerekmiyor.
foreach ($a in $METINLER[$DIL].Keys) { $xamlMetin = $xamlMetin.Replace("@@$a@@", $METINLER[$DIL][$a]) }
[xml]$xaml = $xamlMetin
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
function Get-Ogesi { param([string]$Ad) $win.FindName($Ad) }

# Tanı günlüğü — yalnızca KULLANIM_TANI=1 iken yazar
function Write-Tani {
    param([string]$Mesaj)
    if ($env:KULLANIM_TANI -ne '1') { return }
    try {
        Add-Content -Path (Join-Path $env:TEMP 'claude-kullanim-tani.log') `
                    -Value ("{0:HH:mm:ss}  {1}" -f [DateTime]::Now, $Mesaj) -Encoding UTF8
    } catch { }
}

$Kapsul = Get-Ogesi 'Kapsul';  $Kok    = Get-Ogesi 'Kok'
$Yas    = Get-Ogesi 'Yas';     $Uyari  = Get-Ogesi 'Uyari'
$Sifir5 = Get-Ogesi 'Sifir5';  $Yuzde5 = Get-Ogesi 'Yuzde5'; $Dolgu5 = Get-Ogesi 'Dolgu5'
$SifirH = Get-Ogesi 'SifirH';  $YuzdeH = Get-Ogesi 'YuzdeH'; $DolguH = Get-Ogesi 'DolguH'
$OlayKutu = Get-Ogesi 'OlayKutu'; $OlayIkon = Get-Ogesi 'OlayIkon'
$OlayMetin = Get-Ogesi 'OlayMetin'; $OlayAlt = Get-Ogesi 'OlayAlt'
$HizUyari = Get-Ogesi 'HizUyari'
$SeritKapsul = Get-Ogesi 'SeritKapsul'
$Serit5Dolgu = Get-Ogesi 'Serit5Dolgu'; $Serit5Yuzde = Get-Ogesi 'Serit5Yuzde'
$SeritHDolgu = Get-Ogesi 'SeritHDolgu'; $SeritHYuzde = Get-Ogesi 'SeritHYuzde'
$SeritKalan  = Get-Ogesi 'SeritKalan';  $SeritYas    = Get-Ogesi 'SeritYas'
$SERIT_IZ = 70.0    # şeritteki mini bar rayının genişliği (XAML ile aynı)
$SERIT_TEPSI_PAYI = 250.0   # sağdaki saat/bildirim alanını örtmemek için pay
$HaftaBolum = Get-Ogesi 'HaftaBolum'; $BugunOzet = Get-Ogesi 'BugunOzet'
$CUBUKLAR  = @(0..6 | ForEach-Object { Get-Ogesi ('Cub{0}' -f $_) })
$ETIKETLER = @(0..6 | ForEach-Object { Get-Ogesi ('Etk{0}' -f $_) })

$script:Ayar = Get-Ayarlar
$script:Veri = $null                 # birleştirilmiş görünüm (ekrana bu gider)
$script:DurumHam = $null             # statusLine'ın yazdığı ham dosya
$script:SonYazma = [datetime]::MinValue
$script:Masaustu = $null             # masaüstü uygulamasından son örnek + türevleri
$script:MasaustuSonYazma = [datetime]::MinValue
$script:SonOlayMs = [int64]0          # hook'un yazdığı son olayın zamanı
$script:KullanimSonrasi = $false     # ölçümden sonra Claude tur bitirdi mi
$script:VeriTaze = $false    # veri hiç okunmadan uyarı tetiklenmesin


function Set-ArkaPlan {
    param([string]$Ad)
    if (-not $ArkaPlanlar.ContainsKey($Ad)) { $Ad = 'hafif' }
    $script:Ayar.arkaPlan = $Ad
    $Kapsul.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($ArkaPlanlar[$Ad])
    (Get-Ogesi 'MnuBgYok').IsChecked   = ($Ad -eq 'yok')
    (Get-Ogesi 'MnuBgHafif').IsChecked = ($Ad -eq 'hafif')
    (Get-Ogesi 'MnuBgKoyu').IsChecked  = ($Ad -eq 'koyu')
}

# ─────────────────────────────────────────────────────────────────────────────
# Görünüm teması: kart (masaüstü seviyesinde) / şerit (görev çubuğu üstünde)
#
# Şerit, görev çubuğu widget'ı gibi HER ZAMAN görünür olmalı; o yüzden o modda
# "hep dipte" kancasını kapatıp Topmost'a geçiyoruz. Kart teması eskisi gibi
# masaüstü seviyesinde durur ve hiçbir pencerenin önüne geçmez.
# ─────────────────────────────────────────────────────────────────────────────
function Set-Tema {
    param([string]$Ad, [switch]$Kaydetme)

    if ($Ad -ne 'serit') { $Ad = 'kart' }
    $script:Ayar.tema = $Ad
    $seritMi = ($Ad -eq 'serit')

    $SeritKapsul.Visibility = $(if ($seritMi) { 'Visible' } else { 'Collapsed' })
    $Kapsul.Visibility      = $(if ($seritMi) { 'Collapsed' } else { 'Visible' })

    [ZDuzeni]::Dipte = -not $seritMi
    $win.Topmost = $seritMi

    (Get-Ogesi 'MnuTemaKart').IsChecked  = -not $seritMi
    (Get-Ogesi 'MnuTemaSerit').IsChecked = $seritMi

    Update-Gorunum      # şerit öğeleri boş doğmasın
    Set-TemaKonumu      # ölçüler oturduktan SONRA konumla
    if (-not $Kaydetme) { Save-Ayarlar -Ayar $script:Ayar }
}

# Her temanın kendi konumu var: kartı sağ üstte, şeridi görev çubuğunun üstünde
# tutmak istersiniz; tek konumu paylaşsalardı tema değişiminde biri kayardı.
function Set-TemaKonumu {
    # Yerlesim daha oturmadan olcu almak yanlis konum uretiyor (serit 28 px
    # olacakken gecis ortasinda 72 px okunuyordu). Bu yuzden konumlandirmayi
    # yerlesim tamamlandiktan SONRAya erteliyoruz.
    $win.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded,
        [System.Action]{ Set-TemaKonumuSimdi }) | Out-Null
}

function Set-TemaKonumuSimdi {
    $win.UpdateLayout()

    if ($script:Ayar.tema -eq 'serit') {
        if ($null -ne $script:Ayar.seritSol -and $null -ne $script:Ayar.seritUst) {
            Set-PencereKonumu -Sol ([double]$script:Ayar.seritSol) -Ust ([double]$script:Ayar.seritUst)
        } else {
            Set-SeritVarsayilanKonumu
        }
    } else {
        if ($null -ne $script:Ayar.sol -and $null -ne $script:Ayar.ust) {
            Set-PencereKonumu -Sol ([double]$script:Ayar.sol) -Ust ([double]$script:Ayar.ust)
        } else {
            Set-VarsayilanKonum
        }
    }
}

# Serit, gorev cubugunun UZERINE oturur - onun bir parcasiymis gibi gorunsun
# diye. Windows 11'de gorev cubuguna icerik eklemenin desteklenen bir yolu yok
# (deskband API'si kaldirildi); explorer'a mudahale eden ucuncu parti yontemler
# ise hem kirilgan hem de kurumsal guvenlik yazilimlarinin engelledigi turden.
# Bu yuzden ustune binen, her zaman gorunur ince bir katman kullaniyoruz.
function Get-GorevCubuguSeridi {
    # Ekranin calisma alani disinda kalan bant = gorev cubugu. Kenari kendisi
    # soyler; kullanici cubugu ust/alt kenara tasirsa serit onu takip eder.
    $ca = [System.Windows.SystemParameters]::WorkArea
    $ey = [System.Windows.SystemParameters]::PrimaryScreenHeight

    if ($ey - $ca.Bottom -ge 20) { return @{ Ust = $ca.Bottom; Yuk = $ey - $ca.Bottom } }
    if ($ca.Top -ge 20)          { return @{ Ust = 0.0;        Yuk = $ca.Top } }
    return $null   # yan kenarda ya da otomatik gizlenen cubuk: bant yok
}

function Set-SeritVarsayilanKonumu {
    $win.UpdateLayout()
    $g = if ([double]::IsNaN($win.ActualWidth)  -or $win.ActualWidth  -le 0) { 430 } else { $win.ActualWidth }
    $y = if ([double]::IsNaN($win.ActualHeight) -or $win.ActualHeight -le 0) {  30 } else { $win.ActualHeight }

    $bant = Get-GorevCubuguSeridi
    if ($null -ne $bant) {
        # Yatayda saat/tepsi bolgesini ortmeyelim: sagdan SERIT_TEPSI_PAYI kadar geride dur.
        $sol = [Math]::Max(0, [System.Windows.SystemParameters]::PrimaryScreenWidth - $g - $SERIT_TEPSI_PAYI)
        $ust = $bant.Ust + [Math]::Max(0, ($bant.Yuk - $y) / 2)
    } else {
        # Cubuk yan kenarda / gizli: calisma alaninin sag alt kosesine yasla.
        $ca = [System.Windows.SystemParameters]::WorkArea
        $sol = [Math]::Max(0, $ca.Right - $g - 12)
        $ust = [Math]::Max(0, $ca.Bottom - $y - 6)
    }
    Set-PencereKonumu -Sol $sol -Ust $ust
}

# ─────────────────────────────────────────────────────────────────────────────
# Veri okuma
# ─────────────────────────────────────────────────────────────────────────────
function Read-DurumDosyasi {
    if (-not (Test-Path $DurumDosya)) { $script:DurumHam = $null; return }
    try {
        $bilgi = Get-Item $DurumDosya
        if ($bilgi.LastWriteTime -le $script:SonYazma) { return }   # değişmediyse okuma
        $script:DurumHam = Get-Content $DurumDosya -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:SonYazma = $bilgi.LastWriteTime
    } catch {
        # Yarım yazılmış dosyaya denk geldiysek bir sonraki turda tekrar denenir.
    }
}

function Test-Ozellik {
    param($Nesne, [string]$Ad)
    return ($null -ne $Nesne -and $Nesne.PSObject.Properties.Name -contains $Ad -and $null -ne $Nesne.$Ad)
}

# Bir örnek serisinde (fh ya da sd) mevcut pencerenin başladığı anı bulur: en
# son DÜŞÜŞTEN sonraki ilk örneğin zamanı. Masaüstü dosyasında resets_at yok;
# eşik uyarısının "bu pencere için zaten uyardım" hafızası bu anahtarla çalışır.
function Get-PencereBaslangici {
    param($Ornekler, [string]$Alan)
    $onceki = $null; $baslangic = $null
    foreach ($o in $Ornekler) {
        if (-not (Test-Ozellik $o.u $Alan)) { continue }
        $deger = [double]$o.u.$Alan
        if ($null -eq $baslangic -or ($null -ne $onceki -and $deger -lt $onceki)) { $baslangic = [int64]$o.t }
        $onceki = $deger
    }
    return $baslangic
}

# durum-yaz.js'teki hizHesapla'nın aynısı, masaüstü örnekleriyle: son
# MASAUSTU_HIZ_DK dakikadaki artıştan yüzde/dk, oradan "kaç dakikada biter".
# Arada düşüş (sıfırlanma) varsa hesaplanmaz — yanıltıcı olur.
function Get-MasaustuHiz {
    param($Ornekler, [int64]$SimdiMs, [double]$Fh)
    $pencere = @($Ornekler | Where-Object {
        (Test-Ozellik $_.u 'fh') -and ($SimdiMs - [int64]$_.t) -le ($MASAUSTU_HIZ_DK * 60000) })
    if ($pencere.Count -lt 2) { return $null }
    for ($i = 1; $i -lt $pencere.Count; $i++) {
        if ([double]$pencere[$i].u.fh -lt [double]$pencere[$i - 1].u.fh) { return $null }
    }
    $ilk = $pencere[0]
    $dakika = ($SimdiMs - [int64]$ilk.t) / 60000.0
    if ($dakika -lt 1) { return $null }
    $yuzdeDk = ($Fh - [double]$ilk.u.fh) / $dakika
    if ($yuzdeDk -le 0.01) { return $null }
    return [pscustomobject]@{ yuzdeDk = $yuzdeDk; bitisDk = [int][Math]::Round((100 - $Fh) / $yuzdeDk) }
}

function Read-Masaustu {
    if (-not (Test-Path $MasaustuDosya)) { $script:Masaustu = $null; return }
    try {
        $bilgi = Get-Item $MasaustuDosya
        if ($bilgi.LastWriteTime -le $script:MasaustuSonYazma) { return }
        $j = Get-Content $MasaustuDosya -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:MasaustuSonYazma = $bilgi.LastWriteTime

        # Şema kapısı: bildiğimiz biçim değilse hiç yorumlamaya kalkma.
        if (-not (Test-Ozellik $j 'version') -or [int]$j.version -ne 2 -or -not (Test-Ozellik $j 'samples')) {
            Write-Tani 'masaustu: sema uyumsuz, yok sayildi'
            $script:Masaustu = $null; return
        }
        $ornekler = @($j.samples | Where-Object { (Test-Ozellik $_ 't') -and (Test-Ozellik $_ 'u') } |
                     Sort-Object { [int64]$_.t })
        if ($ornekler.Count -eq 0) { $script:Masaustu = $null; return }
        $son = $ornekler[-1]

        $fh = if (Test-Ozellik $son.u 'fh') { [double]$son.u.fh } else { $null }
        $sd = if (Test-Ozellik $son.u 'sd') { [double]$son.u.sd } else { $null }
        $script:Masaustu = [pscustomobject]@{
            t   = [int64]$son.t
            fh  = $fh
            sd  = $sd
            hiz = $(if ($null -ne $fh) { Get-MasaustuHiz -Ornekler $ornekler -SimdiMs ([int64]$son.t) -Fh $fh } else { $null })
            pencere5 = Get-PencereBaslangici -Ornekler $ornekler -Alan 'fh'
            pencereH = Get-PencereBaslangici -Ornekler $ornekler -Alan 'sd'
        }
        Write-Tani ("masaustu: t={0} fh={1} sd={2} ornek={3}" -f $son.t, $fh, $sd, $ornekler.Count)
    } catch {
        Write-Tani ("masaustu: okuma hatasi " + $_.Exception.Message)
    }
}

# İki kaynak da aynı API'nin bir fotoğrafı; ÖLÇÜM ZAMANI daha yeni olan kazanır.
# Masaüstü kazanırsa yüzdeler oradan gelir; sıfırlanma saati yalnızca
# statusLine'ın gördüğü pencere hâlâ açıksa korunur — pencere dönmüşse
# uydurulmaz, boş bırakılır (geri sayım gösterilmez).
function Merge-Kaynaklar {
    $d = $script:DurumHam
    $m = $script:Masaustu
    if ($null -eq $m) { return $d }

    $dOlcum = $null
    if ($null -ne $d) {
        $dOlcum = if (Test-Ozellik $d 'olcumZamani') { [int64]$d.olcumZamani }
                  elseif (Test-Ozellik $d 'yazildi')  { [int64]$d.yazildi } else { 0 }
        if ($dOlcum -ge $m.t) { return $d }          # statusLine daha taze
    }

    $bes = [pscustomobject]@{ used_percentage = $m.fh; resets_at = $null; pencere_anahtari = $m.pencere5 }
    $haf = [pscustomobject]@{ used_percentage = $m.sd; resets_at = $null; pencere_anahtari = $m.pencereH }
    if ($null -ne $d) {
        foreach ($cift in @(@($bes, 'five_hour', $m.fh), @($haf, 'seven_day', $m.sd))) {
            $hedef, $alan, $yeni = $cift
            if (-not (Test-Ozellik $d $alan) -or -not (Test-Ozellik $d.$alan 'resets_at')) { continue }
            $sifirMs = [int64]$d.$alan.resets_at * 1000
            $eskiYuzde = if (Test-Ozellik $d.$alan 'used_percentage') { [double]$d.$alan.used_percentage } else { -1 }
            # Aynı pencere: sıfırlanma hâlâ ileride VE yüzde geri gitmemiş.
            if ($sifirMs -gt $m.t -and $null -ne $yeni -and $yeni -ge $eskiYuzde) { $hedef.resets_at = $d.$alan.resets_at }
        }
    }

    $v = [ordered]@{ yazildi = $m.t; olcumZamani = $m.t; five_hour = $null; seven_day = $null
                     hiz = $null; haftalik = @(); oturum = $null }
    if ($null -ne $d) { foreach ($oz in $d.PSObject.Properties) { $v[$oz.Name] = $oz.Value } }
    $v.five_hour = $bes
    $v.seven_day = $haf
    $v.olcumZamani = $m.t
    if ($null -eq $v.yazildi -or [int64]$v.yazildi -lt $m.t) { $v.yazildi = $m.t }
    $v.hiz = $m.hiz
    $v.kaynak = 'masaustu'
    return [pscustomobject]$v
}

function Read-Durum {
    Read-DurumDosyasi
    Read-Masaustu
    $script:Veri = Merge-Kaynaklar
}

function Get-Kaynak {
    if (Test-Ozellik $script:Veri 'kaynak') { return [string]$script:Veri.kaynak }
    return 'terminal'
}

function ConvertFrom-UnixSaniye {
    param($Saniye)
    if ($null -eq $Saniye) { return $null }
    try { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Saniye).LocalDateTime } catch { return $null }
}

function Update-Bar {
    param($Pencere, $YuzdeMetin, $SifirMetin, $Dolgu, $BitisDk = $null)

    if ($null -eq $Pencere -or $null -eq $Pencere.used_percentage) {
        $YuzdeMetin.Text = '—'
        $SifirMetin.Text = ''
        $Dolgu.Width = 0
        return
    }

    $sifirlanma = ConvertFrom-UnixSaniye $Pencere.resets_at
    $yuzde = [double]$Pencere.used_percentage

    # Sıfırlanma anı geçtiyse pencere gerçekten sıfırlanmıştır — bayat yüzdeyi
    # göstermeye devam etmek yanıltıcı olur.
    if ($null -ne $sifirlanma -and $sifirlanma -le [DateTime]::Now) { $yuzde = 0 }

    $YuzdeMetin.Text = ('{0}%' -f [int][Math]::Round($yuzde))
    $SifirMetin.Text = Format-Kalan $sifirlanma
    # DIKKAT: [Math]::Min(1, $oran) YAZMAYIN. Literal 1 Int32 olduğu için
    # PowerShell tamsayı aşırı yüklemesini seçer ve 0.56'yı 1'e yuvarlar —
    # sonuç: her bar %100 dolu çizilir. Sınırlamayı elle yapıyoruz.
    $oran = [double]$yuzde / 100.0
    if ($oran -lt 0.0) { $oran = 0.0 }
    if ($oran -gt 1.0) { $oran = 1.0 }
    $Dolgu.Width = $oran * $IZ_GENISLIK
    # Bayat veride bar GRİYE döner. Yalnızca soluklaştırmak yetmiyordu: soluk
    # da olsa mavi/amber bir bar "canlı veri" gibi okunuyor ve eski yüzde
    # güncel sanılıyor. Renk, tazeliğin en güçlü sinyali.
    $renk = if ($script:VeriTaze) {
        Get-BarRengi -Yuzde $yuzde -Sifirlanma $sifirlanma -BitisDk $BitisDk
    } else {
        '#5A6472'
    }
    $Dolgu.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($renk)
    Write-Tani ("bar: yuzde={0} izGenislik={1} atanan={2} gercek={3} hizalama={4}" -f `
        $yuzde, $IZ_GENISLIK, $Dolgu.Width, $Dolgu.ActualWidth, $Dolgu.HorizontalAlignment)
}

# ─────────────────────────────────────────────────────────────────────────────
# Eşik aşımı pop-up'ı
#
# Açık uyarılar listede tutuluyor: tıklanana kadar durdukları için ikincisi
# birincinin üstüne değil, üstüne doğru istiflenmeli.
# ─────────────────────────────────────────────────────────────────────────────
$script:AcikUyarilar = New-Object System.Collections.ArrayList

[xml]$uyariXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Kullanim uyarisi"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize"
        SizeToContent="Height" Width="330" WindowStartupLocation="Manual"
        UseLayoutRounding="True" TextOptions.TextRenderingMode="ClearType">
  <Border CornerRadius="14" Background="#F21C1F26" BorderBrush="#59E8A33D" BorderThickness="1"
          Padding="18,15,18,16">
    <Border.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.55" Color="#FF000000"/>
    </Border.Effect>
    <StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,9">
        <TextBlock x:Name="UIkon" FontFamily="Segoe MDL2 Assets" FontSize="16"
                   VerticalAlignment="Center" Margin="0,0,9,0" Foreground="#E8A33D"/>
        <TextBlock x:Name="UBaslik" FontFamily="Segoe UI" FontSize="13" FontWeight="SemiBold"
                   VerticalAlignment="Center" Foreground="#F5F8FC"/>
      </StackPanel>
      <TextBlock x:Name="UMetin" FontFamily="Segoe UI" FontSize="11.5" Foreground="#E8EDF5"
                 Opacity="0.85" TextWrapping="Wrap" Margin="0,0,0,4"/>
      <TextBlock x:Name="UAlt" FontFamily="Segoe UI" FontSize="10.5" Foreground="#E8EDF5"
                 Opacity="0.55" TextWrapping="Wrap"/>
      <Border x:Name="UTamam" HorizontalAlignment="Right" Margin="0,13,0,0" CornerRadius="7"
              Background="#26FFFFFF" Padding="16,5,16,6">
        <TextBlock Text="@@TAMAM@@" FontFamily="Segoe UI" FontSize="11" Foreground="#F5F8FC"/>
      </Border>
    </StackPanel>
  </Border>
</Window>
'@

function Show-Uyari {
    param([string]$Etiket, [double]$Yuzde, [Nullable[datetime]]$Sifirlanma, [int]$Esik)

    $u = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $uyariXaml))
    $u.FindName('UIkon').Text = [char]0xE7BA        # uyarı üçgeni
    $u.FindName('UBaslik').Text = (T 'UYARI_BASLIK')
    $u.FindName('UMetin').Text = ((T 'UYARI_METIN') -f $Etiket, $Yuzde, $Esik)

    # Geri sayım DEĞİL, sıfırlanma SAATİ yazıyoruz: pencere tıklanana kadar
    # açık kalacağı için geri sayım zamanla yanlışa döner, saat dönmez.
    if ($null -ne $Sifirlanma) {
        $u.FindName('UAlt').Text = ((T 'UYARI_SIFIRLANMA') -f $Sifirlanma.ToString('d MMMM HH:mm', $Kultur))
    } else {
        $u.FindName('UAlt').Text = ''
    }

    # Kırmızı bölge ise rengi sertleştir
    if ($Yuzde -ge 90) {
        $kirmizi = [Windows.Media.BrushConverter]::new().ConvertFromString('#E5484D')
        $u.FindName('UIkon').Foreground = $kirmizi
    }

    # İstifleme: ekranın sağ altından yukarı doğru
    $sira = $script:AcikUyarilar.Count
    $u.Add_ContentRendered({
        $u.Left = [System.Windows.SystemParameters]::PrimaryScreenWidth - $u.ActualWidth - 26
        $u.Top  = [System.Windows.SystemParameters]::PrimaryScreenHeight - $u.ActualHeight - 60 - ($sira * ($u.ActualHeight + 12))
        # Odak çalmasın: yazı yazarken tuşlarınızı kesmemeli.
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $u).Handle
        $ex = [Widget.Win32]::GetWindowLong($h, $GWL_EXSTYLE)
        [void][Widget.Win32]::SetWindowLong($h, $GWL_EXSTYLE, ($ex -bor $WS_EX_NOACTIVATE -bor $WS_EX_TOOLWINDOW))
    }.GetNewClosure())

    $kapat = { param($s, $e) $e.Handled = $true; $u.Close() }.GetNewClosure()
    $u.FindName('UTamam').Add_MouseLeftButtonUp($kapat)
    $u.Add_MouseLeftButtonUp($kapat)
    $u.Add_Closed({ [void]$script:AcikUyarilar.Remove($u) }.GetNewClosure())

    [void]$script:AcikUyarilar.Add($u)
    $u.Show()
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    Write-Tani ("uyari gosterildi: {0} %{1} (esik {2})" -f $Etiket, $Yuzde, $Esik)
}

function Test-Esik {
    param($Pencere, [string]$Etiket, [string]$EsikAlan, [string]$AtesliAlan)

    $esik = [int]$script:Ayar.$EsikAlan
    if ($esik -le 0) { return }                                   # kapalı
    if (-not $script:VeriTaze) { return }                         # bayat veride uyarma
    if ($null -eq $Pencere -or $null -eq $Pencere.used_percentage) { return }

    $sifirlanma = ConvertFrom-UnixSaniye $Pencere.resets_at
    # Sıfırlanma anı geçmişse pencere zaten dönmüştür; eski yüzdeyle uyarmak yanlış.
    if ($null -ne $sifirlanma -and $sifirlanma -le [DateTime]::Now) { return }

    if ([double]$Pencere.used_percentage -lt $esik) { return }

    # Buradan sonrası yalnızca eşik aşıldığında çalışır — tanı günlüğü ancak
    # bu noktada yazıyor, yoksa saniyede iki satırla dosyayı boğardı.
    # Pencere kimliği: sıfırlanma saati. Masaüstü kaynağında o yok; orada
    # pencerenin başladığı örnek zamanı kullanılır. İkisi de yoksa uyarılmaz —
    # anahtarsız uyarı ya hiç susmaz ya hiç tekrarlamaz.
    $anahtar = $null
    if ($null -ne $Pencere.resets_at) { $anahtar = [int64]$Pencere.resets_at }
    elseif (Test-Ozellik $Pencere 'pencere_anahtari') { $anahtar = [int64]$Pencere.pencere_anahtari }
    if ($null -eq $anahtar) { return }
    if ($null -ne $script:Ayar.$AtesliAlan -and [int64]$script:Ayar.$AtesliAlan -eq $anahtar) {
        return                                # bu pencere için zaten uyarıldı
    }
    Write-Tani ("esik asildi {0}: %{1} >= {2}, pencere anahtari {3}" -f `
        $Etiket, $Pencere.used_percentage, $esik, $anahtar)

    # Önce kaydet, sonra göster: pencere gösterimi hata verse bile aynı pencere
    # için tekrar tekrar uyarı çıkmasın.
    $script:Ayar.$AtesliAlan = $anahtar
    Save-Ayarlar -Ayar $script:Ayar
    Show-Uyari -Etiket $Etiket -Yuzde ([double]$Pencere.used_percentage) -Sifirlanma $sifirlanma -Esik $esik
}

# ─────────────────────────────────────────────────────────────────────────────
# Tüketim hızı uyarısı
# ─────────────────────────────────────────────────────────────────────────────
function Update-Hiz {
    param($BitisDk)

    $HizUyari.Visibility = 'Collapsed'
    if ($null -eq $BitisDk -or $null -eq $script:Veri) { return }

    $sifirlanma = ConvertFrom-UnixSaniye $script:Veri.five_hour.resets_at
    if ($null -eq $sifirlanma) { return }

    $kalanDk = ($sifirlanma - [DateTime]::Now).TotalMinutes
    # Uyarı yalnızca limit sıfırlanmadan ÖNCE bitecekse anlamlı; aksi hâlde
    # "bu hızla biter" demek gereksiz korkutur.
    if ($kalanDk -le 0 -or [int]$BitisDk -ge $kalanDk) { return }

    $HizUyari.Text = ((T 'HIZ_UYARI') -f (Format-Sure ([int]$BitisDk)))
    $HizUyari.Visibility = 'Visible'
}

# ─────────────────────────────────────────────────────────────────────────────
# Son 7 gün grafiği
# ─────────────────────────────────────────────────────────────────────────────
function Update-Hafta {
    if ($null -eq $script:Veri -or
        -not ($script:Veri.PSObject.Properties.Name -contains 'haftalik') -or
        $null -eq $script:Veri.haftalik -or $script:Veri.haftalik.Count -lt 7) {
        $HaftaBolum.Visibility = 'Collapsed'
        return
    }

    $gunler = @($script:Veri.haftalik)
    $enBuyuk = ($gunler | ForEach-Object { [double]$_.tuketim } | Measure-Object -Maximum).Maximum
    Write-Tani ("hafta: enBuyuk={0} degerler={1}" -f $enBuyuk, (($gunler | ForEach-Object { $_.tuketim }) -join ','))
    if ($enBuyuk -le 0) { $HaftaBolum.Visibility = 'Collapsed'; return }

    $bugun = [DateTime]::Now.ToString('yyyy-MM-dd')

    for ($i = 0; $i -lt 7; $i++) {
        $g = $gunler[$i]
        $tuketim = [double]$g.tuketim
        # Yükseklik en büyük güne göre ölçekli; sıfır olsa bile 2px iz kalsın.
        $CUBUKLAR[$i].Height = [Math]::Max(2.0, ($tuketim / $enBuyuk) * 26.0)

        $tarih = [datetime]::ParseExact($g.gun, 'yyyy-MM-dd', $null)
        $ETIKETLER[$i].Text = Get-GunKisa -Gun $tarih.DayOfWeek.ToString()

        $buGunMu = ($g.gun -eq $bugun)
        $CUBUKLAR[$i].Background = [Windows.Media.BrushConverter]::new().ConvertFromString(
            $(if ($buGunMu) { '#4C8DF6' } else { '#3D5E8C' }))
        $ETIKETLER[$i].Opacity = $(if ($buGunMu) { 0.85 } else { 0.4 })
    }

    # Bugünün tüketimi "5 saatlik pencere" cinsinden: 100 puan = 1 tam pencere.
    $bugunVeri = $gunler | Where-Object { $_.gun -eq $bugun }
    if ($bugunVeri) {
        $BugunOzet.Text = ((T 'BUGUN') -f ([double]$bugunVeri.tuketim / 100))
    } else {
        $BugunOzet.Text = ''
    }

    $HaftaBolum.Visibility = 'Visible'
}

# ─────────────────────────────────────────────────────────────────────────────
# Olay satırı (Stop / Notification hook'ları)
# ─────────────────────────────────────────────────────────────────────────────
$IKON_ONAY    = [char]0xE73E   # ✓
$IKON_BEKLE   = [char]0xE823   # kum saati

function Update-Olay {
    if (-not (Test-Path $OlayDosya)) { $script:SonOlayMs = 0; $OlayKutu.Visibility = 'Collapsed'; return }

    try {
        $o = Get-Content $OlayDosya -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return   # yarım yazılmış dosya — bir sonraki turda tekrar denenir
    }

    # Hook'lar masaüstü uygulamasında da ateşleniyor (ölçüldü). Bu zaman damgası
    # "ölçümden sonra kullanım oldu mu" sorusunun cevabı; olay kutusu kapansa da tutulur.
    if (Test-Ozellik $o 'zaman') { $script:SonOlayMs = [int64]$o.zaman }

    $zaman = ConvertFrom-UnixSaniye ([int64]$o.zaman / 1000)
    if ($null -eq $zaman) { $OlayKutu.Visibility = 'Collapsed'; return }

    $yasSn = ([DateTime]::Now - $zaman).TotalSeconds
    if ($yasSn -gt $OLAY_OMUR_SN -or $yasSn -lt -60) {
        $OlayKutu.Visibility = 'Collapsed'
        return
    }

    $alt = @()

    if ($o.tur -eq 'bitti') {
        $renk = '#3BD16F'                     # yeşil
        $ikon = $IKON_ONAY
        $metin = (T 'OLAY_BITTI')

        # Satır sayısı statusLine'ın yazdığı oturum bloğundan, olay ise hook'tan
        # gelir — İKİSİ FARKLI OTURUMA AİT OLABİLİR. Bayat bir sayıyı ya da başka
        # projenin sayısını taze olayın altına koymak yanıltıcıdır: widget
        # "B projesi bitirdi · +501" diyebiliyordu ama o 501 satır saatler önceki
        # A projesi oturumundan kalmaydı. Bu yüzden iki koşul birden aranıyor:
        # veri taze OLACAK ve aynı projeye ait OLACAK.
        if ($null -ne $script:Veri -and $null -ne $script:Veri.oturum) {
            $veriTaze = $false
            if ($null -ne $script:Veri.yazildi) {
                $vy = ConvertFrom-UnixSaniye ([int64]$script:Veri.yazildi / 1000)
                if ($null -ne $vy) { $veriTaze = ((([DateTime]::Now - $vy).TotalSeconds) -le $BAYAT_SN) }
            }

            $ayniProje = $false
            if ($null -ne $script:Veri.oturum.dizin -and $null -ne $o.dizin) {
                $ayniProje = ((Split-Path $script:Veri.oturum.dizin -Leaf) -eq $o.dizin)
            }

            if ($veriTaze -and $ayniProje) {
                $ek = [int]$script:Veri.oturum.satirEkli
                $sil = [int]$script:Veri.oturum.satirSilinen
                if ($ek -gt 0 -or $sil -gt 0) { $alt += ('+{0} −{1}' -f $ek, $sil) }
            }
        }
    } else {
        $renk = '#E8A33D'                     # amber
        $ikon = $IKON_BEKLE
        $metin = switch ($o.tip) {
            'permission_prompt' { (T 'OLAY_IZIN') }
            'idle_prompt'       { (T 'OLAY_GIRDI') }
            'agent_needs_input' { (T 'OLAY_AJAN_GIRDI') }
            'agent_completed'   { (T 'OLAY_AJAN_BITTI') }
            default             { (T 'OLAY_BEKLIYOR') }
        }
    }

    # Üst satır: ne olduğu + ne zaman. Alt satır: ayrıntı (satır sayısı, dizin).
    $metin = '{0}  ·  {1}' -f $metin, (Format-Yas $zaman)
    if ($o.dizin) { $alt += $o.dizin }

    $firca = [Windows.Media.BrushConverter]::new().ConvertFromString($renk)
    $OlayIkon.Text = $ikon
    $OlayIkon.Foreground = $firca
    $OlayMetin.Text = $metin
    $OlayAlt.Text = ($alt -join '  ·  ')
    $OlayAlt.Visibility = if ($alt.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $OlayKutu.Visibility = 'Visible'

    # İlk saniyelerde yanıp sönsün — başka pencerede çalışırken göz ucuyla yakalanır.
    if ($yasSn -lt $YANIP_SONME_SN) {
        $acik = ([int][Math]::Floor($yasSn * 2)) % 2 -eq 0
        $arka = if ($acik) { $renk.Replace('#', '#4C') } else { $renk.Replace('#', '#1F') }
        $OlayKutu.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($arka)
    } else {
        $OlayKutu.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($renk.Replace('#', '#1F'))
    }
}

function Update-Gorunum {
    Read-Durum
    Update-Olay

    if ($null -eq $script:Veri) {
        $Kok.Opacity = 1.0
        $Yas.Text = ''
        $Uyari.Visibility = 'Visible'
        $Uyari.Text = (T 'VERI_YOK')
        Update-Bar $null $Yuzde5 $Sifir5 $Dolgu5
        Update-Bar $null $YuzdeH $SifirH $DolguH
        if ($script:Ayar.tema -eq 'serit') { Update-Serit $null }
        return
    }

    $Uyari.Visibility = 'Collapsed'

    # Tazelik ölçütü dosyanın YAZILDIĞI an değil, değerlerin ÖLÇÜLDÜĞÜ an.
    # rate_limits o oturumun son API yanıtından kalma bir fotoğraf; boşta duran
    # bir oturum dosyayı 15 saniyede bir yazıp aynı fotoğrafı gönderebiliyor —
    # yazma zamanına bakmak "canlı" yalanı üretirdi.
    $olcumMs = $script:Veri.yazildi
    if ($script:Veri.PSObject.Properties.Name -contains 'olcumZamani' -and
        $null -ne $script:Veri.olcumZamani) {
        $olcumMs = $script:Veri.olcumZamani
    }
    $yazildi = ConvertFrom-UnixSaniye ([int64]$olcumMs / 1000)
    # Ölçümden en az 90 sn sonra bir tur bitmişse sayı artık bir TABAN. 90 sn:
    # terminalde Stop hook'u ile statusLine yazımı aynı ana düşer, o eş zamanlı
    # çift yanlış pozitif vermesin.
    $script:KullanimSonrasi = ($script:SonOlayMs -gt ([int64]$olcumMs + 90000))
    if ($null -ne $yazildi) {
        $yasSn = ([DateTime]::Now - $yazildi).TotalSeconds
        # Masaüstü kaynağı 15 dk'da bir örnekler; ona 5 dk'lık eşik uygulansa
        # sürekli "bayat" görünür. Eşik kaynağa göre.
        $bayatEsigi = if ((Get-Kaynak) -eq 'masaustu') { $MASAUSTU_BAYAT_SN } else { $BAYAT_SN }
        $script:VeriTaze = ($yasSn -le $bayatEsigi)
        # Bayat veri: soluklaştır ve yaşını yaz — güncel sanıp bakmayalım.
        if ($yasSn -gt $bayatEsigi) {
            $Kok.Opacity = 0.45
            $Yas.Text = Format-Yas $yazildi
            $Yas.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#E8A33D')
            $Yas.Opacity = 1.0
        } else {
            $Kok.Opacity = 1.0
            # Masaüstü kaynağı 15 dk'da bir örnekler; ona "canlı" demek yerine
            # gerçek yaşını yaz: "masaüstü · 7 dk önce". Terminal olay bazlı, o "canlı".
            $Yas.Text = if ((Get-Kaynak) -eq 'masaustu') { '{0} · {1}' -f (T 'KAYNAK_MASAUSTU'), (Format-Yas $yazildi) } else { (T 'CANLI') }
            $Yas.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#E8EDF5')
            $Yas.Opacity = 0.45
        }

        # Uzun süredir beslenmiyorsa SEBEBİNİ de söyle. Yalnızca soluklaşmak
        # "widget bozuldu mu?" sorusunu doğuruyor; asıl sebep veri kaynağının
        # yalnızca terminal oturumunda çalışması.
        if ($yasSn -gt $COK_BAYAT_SN) {
            $Uyari.Text = (T 'VERI_BAYAT')
            $Uyari.Visibility = 'Visible'
        }
    }

    # Tüketim hızı yalnızca 5 saatlik pencere için hesaplanıyor.
    $bitisDk = $null
    if ($script:Veri.PSObject.Properties.Name -contains 'hiz' -and $null -ne $script:Veri.hiz) {
        $bitisDk = [int]$script:Veri.hiz.bitisDk
    }

    Update-Bar $script:Veri.five_hour $Yuzde5 $Sifir5 $Dolgu5 $bitisDk
    Update-Bar $script:Veri.seven_day $YuzdeH $SifirH $DolguH

    # Ölçümden SONRA Claude tur bitirmişse yüzde "en az bu kadar" demektir; ok
    # bunu söyler. Hook masaüstünde de ateşlendiği için bu işaret 15 dk'lık
    # örnekleme boşluklarını dürüstçe doldurur — sayı uydurmadan.
    $Yuzde5.ToolTip = $null
    if ($script:VeriTaze -and $script:KullanimSonrasi -and $Yuzde5.Text -ne '—') {
        $Yuzde5.Text += ' ▲'
        $Yuzde5.ToolTip = (T 'SONRASI_KULLANIM')
    }

    Update-Hiz $bitisDk
    Update-Hafta

    Test-Esik $script:Veri.five_hour (T 'ESIK_5SAAT') 'esik5' 'atesli5'
    Test-Esik $script:Veri.seven_day (T 'ESIK_HAFTA') 'esikH' 'atesliH'

    if ($script:Ayar.tema -eq 'serit') { Update-Serit $bitisDk }
}

# Kart temasındaki bilgiyi tek satıra sıkıştırır. Renk/bayatlık kuralları
# kartla AYNI kaynaktan (Get-BarRengi + $script:VeriTaze) gelir; iki tema
# birbirinden farklı bir gerçeklik göstermesin.
function Update-Serit {
    param($BitisDk)

    $gri  = '#5A6472'
    $bes  = if ($null -ne $script:Veri) { $script:Veri.five_hour } else { $null }
    $haf  = if ($null -ne $script:Veri) { $script:Veri.seven_day } else { $null }

    foreach ($p in @(
        @{ P = $bes; Y = $Serit5Yuzde; D = $Serit5Dolgu; B = $BitisDk },
        @{ P = $haf; Y = $SeritHYuzde; D = $SeritHDolgu; B = $null })) {

        if ($null -eq $p.P -or $null -eq $p.P.used_percentage) {
            $p.Y.Text = '—'
            $p.D.Width = 0
            continue
        }

        $sifirlanma = ConvertFrom-UnixSaniye $p.P.resets_at
        $yuzde = [double]$p.P.used_percentage
        if ($null -ne $sifirlanma -and $sifirlanma -le [DateTime]::Now) { $yuzde = 0 }

        $p.Y.Text = ('{0}%' -f [int][Math]::Round($yuzde))

        # [Math]::Min burada KULLANILMAZ: int aşırı yüklemesi seçilip oran
        # 1'e yuvarlanıyor ve bütün barlar dolu görünüyordu.
        $oran = $yuzde / 100.0
        if ($oran -lt 0.0) { $oran = 0.0 }
        if ($oran -gt 1.0) { $oran = 1.0 }
        $p.D.Width = $oran * $SERIT_IZ

        $renk = if ($script:VeriTaze) {
            Get-BarRengi -Yuzde $yuzde -Sifirlanma $sifirlanma -BitisDk $p.B
        } else { $gri }
        $p.D.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($renk)
    }

    if ($script:VeriTaze -and $script:KullanimSonrasi -and $Serit5Yuzde.Text -ne '—') { $Serit5Yuzde.Text += ' ▲' }
    $SeritKalan.Text = if ($null -ne $bes) { Format-Kalan (ConvertFrom-UnixSaniye $bes.resets_at) } else { '' }
    $SeritYas.Text   = if ($script:VeriTaze) { '' } else { $Yas.Text }
}

# ─────────────────────────────────────────────────────────────────────────────
# Masaüstü seviyesi (saat widget'ı ile aynı yaklaşım)
# ─────────────────────────────────────────────────────────────────────────────
function Get-Tutamac { return (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle }

function Set-MasaustuSeviyesi {
    $hwnd = Get-Tutamac
    if ($hwnd -eq [IntPtr]::Zero) { return }
    $ex = [Widget.Win32]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    [void][Widget.Win32]::SetWindowLong($hwnd, $GWL_EXSTYLE, ($ex -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE))

    # Bundan sonrasını mesaj kancası hallediyor — periyodik yoklama YOK.
    [ZDuzeni]::Bagla($hwnd)
    Push-Dibe
}

# Yalnızca başlangıçta bir kez çağrılır. Düzenli aralıkla çağırmayın:
# masaüstü sağ tık menüsünü kapatır ve simge seçimini bozar.
function Push-Dibe {
    $hwnd = Get-Tutamac
    if ($hwnd -eq [IntPtr]::Zero) { return }
    if ([Widget.Win32]::IsIconic($hwnd)) { [void][Widget.Win32]::ShowWindow($hwnd, $SW_SHOWNOACTIVATE) }
    [void][Widget.Win32]::SetWindowPos($hwnd, $HWND_BOTTOM, 0, 0, 0, 0,
        ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOACTIVATE))
}

# ─────────────────────────────────────────────────────────────────────────────
# Konum + sürükleme
# ─────────────────────────────────────────────────────────────────────────────
function Get-DpiOlcegi {
    $k = [System.Windows.PresentationSource]::FromVisual($win)
    if ($null -ne $k -and $null -ne $k.CompositionTarget) { return $k.CompositionTarget.TransformToDevice.M11 }
    return 1.0
}

$script:KonumSol = 0.0
$script:KonumUst = 0.0

function Set-PencereKonumu {
    param([double]$Sol, [double]$Ust)
    $script:KonumSol = $Sol
    $script:KonumUst = $Ust
    $win.Left = $Sol
    $win.Top  = $Ust
}

function Set-VarsayilanKonum {
    $win.UpdateLayout()
    $g = if ([double]::IsNaN($win.ActualWidth) -or $win.ActualWidth -le 0) { 300 } else { $win.ActualWidth }
    Set-PencereKonumu -Sol ([Math]::Max(0, [System.Windows.SystemParameters]::PrimaryScreenWidth - $g - 28)) -Ust 190
}

$script:surukle = $null

$win.Add_MouseLeftButtonDown({
    $p = New-Object 'Widget.Win32+POINT'
    if ([Widget.Win32]::GetCursorPos([ref]$p)) {
        $script:surukle = @{ mx = $p.X; my = $p.Y; sol = $script:KonumSol; ust = $script:KonumUst }
        [void]$win.CaptureMouse()
    }
})

$win.Add_MouseMove({
    if ($null -ne $script:surukle) {
        $p = New-Object 'Widget.Win32+POINT'
        if ([Widget.Win32]::GetCursorPos([ref]$p)) {
            $olcek = Get-DpiOlcegi
            Set-PencereKonumu -Sol ($script:surukle.sol + ($p.X - $script:surukle.mx) / $olcek) `
                              -Ust ($script:surukle.ust + ($p.Y - $script:surukle.my) / $olcek)
        }
    }
})

$win.Add_MouseLeftButtonUp({
    if ($null -ne $script:surukle) {
        $win.ReleaseMouseCapture()
        $script:surukle = $null
        if ($script:Ayar.tema -eq 'serit') {
            $script:Ayar.seritSol = $script:KonumSol
            $script:Ayar.seritUst = $script:KonumUst
        } else {
            $script:Ayar.sol = $script:KonumSol
            $script:Ayar.ust = $script:KonumUst
        }
        Save-Ayarlar -Ayar $script:Ayar
    }
})

(Get-Ogesi 'MnuBgYok').Add_Click({   Set-ArkaPlan 'yok';   Save-Ayarlar -Ayar $script:Ayar })
(Get-Ogesi 'MnuBgHafif').Add_Click({ Set-ArkaPlan 'hafif'; Save-Ayarlar -Ayar $script:Ayar })
(Get-Ogesi 'MnuBgKoyu').Add_Click({  Set-ArkaPlan 'koyu';  Save-Ayarlar -Ayar $script:Ayar })

# Eşik menüleri kodla üretiliyor — XAML'e 18 satır elle yazmak yerine tek
# kaynaktan. Widget klavye odağı almadığı için sayı YAZILAMAZ; seçenekler
# hazır listeden tıklanır.
$ESIK_SECENEKLERI = @(0, 50, 60, 70, 75, 80, 85, 90, 95)

# TUZAK: Bu gövde bilerek ayrı bir fonksiyonda duruyor.
#
# Menü tıklama işleyicisi .GetNewClosure() ile kuruluyor ve closure YENİ BİR
# MODÜL KAPSAMINA bağlanıyor — orada `$script:` artık betiğin script kapsamı
# değildir. Closure içinde `$script:Ayar.esikH = 85` yazmak aslında
# `$null.esikH = 85` demekti ve widget çöküyordu:
#   "The property 'esikH' cannot be found on this object."
#
# Closure artık yalnızca yerel değişkenleri ($EsikAlan, $Kok) taşıyıp bu
# fonksiyonu çağırıyor; `$script:` erişimi normal betik kapsamında kalıyor.
function Set-EsikDegeri {
    param([string]$Alan, [int]$Deger, $Kok)

    $script:Ayar.$Alan = $Deger

    # Eşik değişince "zaten uyarıldı" durumu sıfırlanır: yeni eşik yeni bir
    # soru demektir, eski cevabı taşımak yanlış olur.
    $atesliAlan = $Alan -replace '^esik', 'atesli'
    $script:Ayar.$atesliAlan = $null
    Save-Ayarlar -Ayar $script:Ayar

    # Menüyü yeniden KURMUYORUZ: tıklanan öğe hâlâ olayı işliyor, Items.Clear()
    # onu koparır. Yalnızca işaretleri güncellemek yeterli.
    foreach ($oge in $Kok.Items) { $oge.IsChecked = ([int]$oge.Tag -eq $Deger) }
}

function Build-EsikMenusu {
    param($Kok, [string]$EsikAlan)

    $Kok.Items.Clear()
    foreach ($deger in $ESIK_SECENEKLERI) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $(if ($deger -eq 0) { (T 'MENU_KAPALI') } else { "$deger%" })
        $mi.IsCheckable = $true
        $mi.IsChecked = ([int]$script:Ayar.$EsikAlan -eq $deger)
        $mi.Tag = $deger
        $mi.Add_Click({
            param($s, $e)
            Set-EsikDegeri -Alan $EsikAlan -Deger ([int]$s.Tag) -Kok $Kok
        }.GetNewClosure())
        [void]$Kok.Items.Add($mi)
    }
}

Build-EsikMenusu -Kok (Get-Ogesi 'MnuEsik5') -EsikAlan 'esik5'
Build-EsikMenusu -Kok (Get-Ogesi 'MnuEsikH') -EsikAlan 'esikH'

(Get-Ogesi 'MnuSifirla').Add_Click({
    if ($script:Ayar.tema -eq 'serit') {
        Set-SeritVarsayilanKonumu
        $script:Ayar.seritSol = $script:KonumSol
        $script:Ayar.seritUst = $script:KonumUst
    } else {
        Set-VarsayilanKonum
        $script:Ayar.sol = $script:KonumSol
        $script:Ayar.ust = $script:KonumUst
    }
    Save-Ayarlar -Ayar $script:Ayar
})

(Get-Ogesi 'MnuKapat').Add_Click({ $win.Close() })
(Get-Ogesi 'MnuTemaKart').Add_Click({  Set-Tema 'kart' })
(Get-Ogesi 'MnuTemaSerit').Add_Click({ Set-Tema 'serit' })

# ─────────────────────────────────────────────────────────────────────────────
# Sağ tık menüsü kapatma nöbetçisi
#
# Pencere WS_EX_NOACTIVATE ile çalıştığı için hiçbir zaman odak almıyor.
# WPF'in "dışarı tıklanınca menüyü kapat" mekanizması ise tam olarak odak /
# fare yakalama kaybına dayanıyor — bizde o olay hiç gerçekleşmediğinden menü
# ekranda asılı kalıyordu. Çözüm: menü açıkken fareyi yoklayıp dışarıdaki ilk
# tıklamada menüyü elle kapatmak.
#
# "Dışarısı" = tıklanan noktadaki pencere BİZE ait değilse. Alt menüler de
# bizim sürecimize ait ayrı pencereler olduğu için bu ölçüt onları yanlışlıkla
# kapatmaz; widget'ın kendisine tıklamak ise kapatır.
# ─────────────────────────────────────────────────────────────────────────────
$script:OncekiBasili = $true

$menuIzleyici = New-Object System.Windows.Threading.DispatcherTimer
$menuIzleyici.Interval = [TimeSpan]::FromMilliseconds(100)
$menuIzleyici.Add_Tick({
    $menu = $win.ContextMenu
    if ($null -eq $menu -or -not $menu.IsOpen) { $menuIzleyici.Stop(); return }

    $basili = ((([Widget.Win32]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0) -or
               (([Widget.Win32]::GetAsyncKeyState(0x02) -band 0x8000) -ne 0))

    # Yalnızca basılı-değilden basılıya GEÇİŞ sayılır; basılı tutmak tekrar
    # tetiklemesin.
    if ($basili -and -not $script:OncekiBasili) {
        $p = New-Object 'Widget.Win32+POINT'
        if ([Widget.Win32]::GetCursorPos([ref]$p)) {
            $h = [Widget.Win32]::WindowFromPoint($p)
            $sahip = 0
            [void][Widget.Win32]::GetWindowThreadProcessId($h, [ref]$sahip)
            if ($sahip -ne $PID -or $h -eq (Get-Tutamac)) {
                $menu.IsOpen = $false
                Write-Tani 'menu disariya tiklandigi icin kapatildi'
            }
        }
    }
    $script:OncekiBasili = $basili
})

$win.ContextMenu.Add_Opened({
    # Menüyü açan sağ tık hâlâ basılı olabilir; ilk turda tıklama sayılmasın.
    $script:OncekiBasili = $true
    $menuIzleyici.Start()
})
$win.ContextMenu.Add_Closed({ $menuIzleyici.Stop() })

# ─────────────────────────────────────────────────────────────────────────────
# Zamanlayıcılar
# ─────────────────────────────────────────────────────────────────────────────
$veriTimer = New-Object System.Windows.Threading.DispatcherTimer
$veriTimer.Interval = [TimeSpan]::FromSeconds(1)
$veriTimer.Add_Tick({
    try { Update-Gorunum } catch { Write-Tani ("HATA Update-Gorunum: " + $_.Exception.Message) }
})

# Win+D ("masaüstünü göster") pencereyi küçültür. Yoklama yerine olayı
# dinliyoruz — küçültüldüğü anda geri aç.
$win.Add_StateChanged({
    if ($win.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $win.WindowState = [System.Windows.WindowState]::Normal
    }
})

Set-ArkaPlan $script:Ayar.arkaPlan
Update-Gorunum

$win.Add_SourceInitialized({
    if ($null -ne $script:Ayar.sol -and $null -ne $script:Ayar.ust) {
        Set-PencereKonumu -Sol ([double]$script:Ayar.sol) -Ust ([double]$script:Ayar.ust)
    } else {
        Set-VarsayilanKonum
    }
})

$win.Add_ContentRendered({
    Set-MasaustuSeviyesi
    Set-Tema $script:Ayar.tema -Kaydetme    # kayıtlı temayı geri yükle
    $veriTimer.Start()

    # Öz-test (KULLANIM_ESIKTEST=1): eşik menüsü öğesine GERÇEKTEN tıklar.
    # Bu yol daha önce sınanmamıştı ve closure kapsam hatası yüzünden widget'ı
    # çökertiyordu; regresyon buradan yakalanır.
    # Öz-test (KULLANIM_TEMATEST=1): tema menüsüne GERÇEKTEN tıklar. Eşik
    # menüsündeki closure kapsam hatası tam da "elle ayar dosyası yazarak
    # test ettim" diye gözden kaçmıştı; tema anahtarı aynı tuzağa düşmesin.
    if ($env:KULLANIM_TEMATEST -eq '1') {
        $tikla = {
            param($Ad)
            (Get-Ogesi $Ad).RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent)))
        }
        foreach ($adim in @(@('MnuTemaSerit', 'serit'), @('MnuTemaKart', 'kart'))) {
            try {
                & $tikla $adim[0]
                $win.UpdateLayout()
                Write-Tani ("TEMATEST {0}: ayar={1} serit={2} kart={3} topmost={4} dipte={5}" -f `
                    $adim[1], $script:Ayar.tema, $SeritKapsul.Visibility, $Kapsul.Visibility,
                    $win.Topmost, [ZDuzeni]::Dipte)
            } catch {
                Write-Tani ("TEMATEST {0} HATA: {1}" -f $adim[1], $_.Exception.Message)
            }
        }
        # Konumlandırma ertelenmiş olduğu için ölçüyü bir tur sonra al.
        $win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
            [System.Action]{ Write-Tani ("TEMATEST konum: sol={0} ust={1} gen={2} yuk={3}" -f `
                $win.Left, $win.Top, $win.ActualWidth, $win.ActualHeight) }) | Out-Null
    }

    if ($env:KULLANIM_ESIKTEST -eq '1') {
        try {
            $hedef = (Get-Ogesi 'MnuEsikH').Items | Where-Object { [int]$_.Tag -eq 85 } | Select-Object -First 1
            Write-Tani ("OZTEST once : esikH=$($script:Ayar.esikH) hedefVar=$($null -ne $hedef)")
            $hedef.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent)))
            $isaretli = ((Get-Ogesi 'MnuEsikH').Items | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag }) -join ','
            Write-Tani ("OZTEST sonra: esikH=$($script:Ayar.esikH) atesliH=$($script:Ayar.atesliH) isaretli=$isaretli")
        } catch {
            Write-Tani ("OZTEST HATA: " + $_.Exception.Message)
        }
    }
    # Not: eşik menüsünü programla açıp (ContextMenu.IsOpen) doğrulamayı
    # denemeyin — odak alamayan pencerede menü açılıp süreci düşürüyor.
    # Menü içeriği kurulumda Build-EsikMenusu ile üretiliyor; hata olsaydı
    # StrictMode altında betik hiç başlamazdı.
})

$win.Add_Closed({ $veriTimer.Stop() })

[void]$win.ShowDialog()
