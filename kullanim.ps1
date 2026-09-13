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

Add-Type -Namespace Widget -Name Win32 -MemberDefinition @'
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

    // Betigi calistiran konsol. Bkz. Hide-Konsol.
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("kernel32.dll")]
    public static extern bool FreeConsole();
'@

# Arkada duran boş konsol penceresini yok et.
#
# Kısayol `-WindowStyle Hidden` ile açıyor ama bu YETMİYOR: kullanıcının
# varsayılan konsol barındırıcısı Windows Terminal ise pencere sınıfı
# `CASCADIA_HOSTING_WINDOW_CLASS` oluyor, yani PowerShell'in gizlemeye
# çalıştığı pencere gerçek sahibi değil — ekranda "Claude Kullanım" başlıklı
# boş bir terminal açık kalıyor. Aynısı betik çift tıkla ya da çıktı
# yönlendirmeli başlatıldığında da oluyor.
#
# İki adım birden: klasik conhost için pencereyi gizle, Windows Terminal için
# konsolu tamamen bırak. Widget'ın penceresi WPF; konsola hiç ihtiyacı yok ve
# mesaj döngüsü konsoldan bağımsız çalışmaya devam ediyor.
function Hide-Konsol {
    try {
        $konsol = [Widget.Win32]::GetConsoleWindow()
        if ($konsol -eq [IntPtr]::Zero) { return }          # zaten konsolsuz
        [void][Widget.Win32]::ShowWindow($konsol, 0)        # SW_HIDE
        [void][Widget.Win32]::FreeConsole()
    } catch { }
}
Hide-Konsol

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
$HWND_TOPMOST      = [IntPtr](-1)
$SW_SHOWNOACTIVATE = 4
$SWP_NOSIZE        = 0x0001
$SWP_NOMOVE        = 0x0002
$SWP_NOACTIVATE    = 0x0010

# ─────────────────────────────────────────────────────────────────────────────
# Dosyalar
# ─────────────────────────────────────────────────────────────────────────────
$VeriKlasor  = Join-Path $env:APPDATA 'ClaudeKullanim'

# ÖMÜR GÜNLÜĞÜ — her zaman açık, ayrıntılı tanıdan (Write-Tani) farklı.
#
# Yalnızca hayati olaylar yazılır: başlangıç, kapanış, yakalanan hata. Amaç,
# "kendi kendine kapanıyor" gibi bir şikâyette tahmin yürütmek yerine kanıta
# bakabilmek. Write-Tani ayrıntılıdır ve KULLANIM_TANI=1 ister; o kapalıyken
# elimizde hiçbir iz kalmıyordu.
#
# Dosya sınırlı: 300 satırı geçince başı atılır, sessizce büyümez.
$GunlukDosya = Join-Path $VeriKlasor 'gunluk.txt'

# İkinci kopyanın çalışan kopyaya bıraktığı "beni göster" notu.
# Dosya tabanlı çünkü widget zaten saniyede bir dosya okuyor; bunun için
# ayrı bir IPC kanalı kurmak gereksiz karmaşıklık olurdu.
$CagriDosya = Join-Path $VeriKlasor 'cagri.tmp'

function Write-Kayit {
    param([string]$Mesaj)
    try {
        if (-not (Test-Path $VeriKlasor)) { New-Item -ItemType Directory -Path $VeriKlasor -Force | Out-Null }
        $satir = '{0:yyyy-MM-dd HH:mm:ss}  pid {1,-6} {2}' -f [DateTime]::Now, $PID, $Mesaj
        Add-Content -Path $GunlukDosya -Value $satir -Encoding UTF8
        $hepsi = @(Get-Content $GunlukDosya -ErrorAction SilentlyContinue)
        if ($hepsi.Count -gt 300) {
            Set-Content -Path $GunlukDosya -Value ($hepsi[-200..-1]) -Encoding UTF8
        }
    } catch { }
}
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

# ÜÇÜNCÜ KAYNAK — OPSİYONEL, VARSAYILAN KAPALI: "canlı yoklama".
#
# Widget'ın iki varsayılan kaynağı Claude'un zaten diske yazdığı dosyalardır;
# hiçbir kimlik bilgisine dokunulmaz, ağa çıkılmaz. Bunun bedeli masaüstü
# oturumlarında ~15 dakikaya varan gecikmedir.
#
# Kullanıcı isterse bu gecikmeyi ~60 saniyeye indirebilir: ayrı bir betik
# (kota-yokla.js) OAuth jetonuyla resmi kullanım ucunu yoklar ve sonucu
# kota.json'a yazar. Widget o dosyayı diğer ikisi gibi yalnızca OKUR —
# jetonu hiç görmez. Sır taşıyan kod tek dosyada toplanmıştır.
#
# Bu seçenek AÇIKÇA açılmadıkça hiçbir şey değişmez: kota-yokla.js
# çalıştırılmaz, kota.json okunmaz.
$KotaDosya = Join-Path $VeriKlasor 'kota.json'         # yoklayıcı yazar (yalnızca BAŞARILI ölçüm)

# Yoklama hatası artık kota.json'u EZMİYOR, kendi dosyasında duruyor.
# Eskiden her hata son iyi ölçümün üstüne yazılıyordu; uç nokta her iki
# yoklamadan birinde 429 dönünce widget API kaynağını kaybedip dosya
# kaynaklarına düşüyor, sonraki başarılı yoklamada geri dönüyordu. Ekranda bu,
# sayıların iki dakikada bir ZIPLAMASI olarak görünüyordu — ve kullanıcı bunu
# "yenilenmiyor" diye okuyor. Son iyi ölçüm artık yerinde kalır; bayatlık
# kuralları onu zaten yaşlandırır.
$KotaHataDosya = Join-Path $VeriKlasor 'kota-hata.json'
$YoklayiciBetik = Join-Path $PSScriptRoot 'kota-yokla.js'

# Açılışta başlatma kısayolu. Menüden açılıp kapatılabiliyor, o yüzden yolu
# widget'ın da bilmesi gerek. KULLANIM_BASLANGIC_YOL yalnızca testler için:
# gerçek Başlangıç klasörüne dokunmadan sınamayı sağlıyor.
$KISAYOL_ADI = 'Claude Usage.lnk'
$IkonDosya = Join-Path $PSScriptRoot 'claude-usage.ico'
$BaslangicKisayolu = if ($env:KULLANIM_BASLANGIC_YOL) { $env:KULLANIM_BASLANGIC_YOL }
                     else { Join-Path ([Environment]::GetFolderPath('Startup')) $KISAYOL_ADI }
$API_BAYAT_SN = 300     # API ölçümü bu kadar sonra bayat sayılır
$YOKLAMA_SECENEKLERI = @(0, 60, 120, 300)   # 0 = kapalı
$YOKLAMA_TAVAN_SN = 900   # geri çekilmenin üst sınırı
$YOKLAMA_INIS_BASARI = 10 # tabanı bir kademe indirmeden önce gereken ardışık başarı
$YOKLAMA_INIS_DK = 15     # ya da: bu kadar dakikadır uzak hata gelmediyse

$OLAY_OMUR_SN  = 900    # olay satırı 15 dk sonra kaybolur
$YANIP_SONME_SN = 12    # ilk 12 saniye dikkat çeksin diye yanıp söner
$COK_BAYAT_SN  = 43200  # 12 saatten eskiyse sebebini de yaz

# Bar rayının genişliği. XAML'deki iki Border Width'i ve Kok.Width ile AYNI
# olmalı. 232 + 2×18 kapsül dolgusu = 268 → masaüstü saat widget'ı ile aynı en.
$IZ_GENISLIK = 232.0
$BAYAT_SN    = 300      # 5 dk'dan eski veri "bayat" sayılır
# Gelecek tarihli ölçüm ZEHİRDİR. Yaşı negatif olduğu için hiçbir bayatlık
# eşiğini geçemez: bar asla grileşmez, yaş etiketi asla uyarmaz, eşik pop-up'ı
# yanlış sayı üzerinde kurulu kalır — ve birleştirmede "ölçüm zamanı yeni olan
# kazanır" kuralını kalıcı olarak kazanır. Yeniden başlatmadan çıkış yok.
#
# İki üreticinin de saatini biz kontrol etmiyoruz (Node statusLine betiği ve
# masaüstü uygulamasının `t` alanı); geriye NTP düzeltmesi ya da UTC/yerel
# karışması bu durumu üretmeye yeter. Olay yolu bu korumayı zaten yapıyordu
# (Update-Olay, -lt -60); ölçüm yolunda eksikti.
$GELECEK_PAYI_SN = 300      # gerçek saat kaymasına tolerans; ötesi reddedilir
$MASAUSTU_BAYAT_SN = 1200   # masaüstü 15 dk'da bir örnekler (+5 dk pay); ötesi bayat
$MASAUSTU_HIZ_DK   = 60     # tüketim hızı için geriye bakış (15 dk'lık örneklerle 45 dk çok dar)

# Arka plan artık ALFA seçiyor; rengi tema veriyor. İkisi çarpışmasın diye
# ayrıldı: "koyu/hafif/yok" saydamlık tercihidir, tema ise palet.
# TEK ÖRNEK KORUMASI
#
# İki kopya aynı anda çalışırsa ikisi de pencere.json'a yazıyor: biri
# sürüklenince diğeri eski konumu geri yazıyor, menü seçimleri birbirini
# eziyor. Üstelik ekranda üst üste duran iki pencere "kapattım ama duruyor"
# ya da "açtım ama kapandı" gibi görünüyor.
#
# Kilidin adı VERİ KLASÖRÜNDEN türüyor: yalıtılmış APPDATA ile çalışan
# testler birbirini ve üretimi engellemesin.
$kilitAdi = 'Local\ClaudeUsageWidget_' + (
    ([System.Security.Cryptography.MD5]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($VeriKlasor.ToLowerInvariant())
    ) | ForEach-Object { $_.ToString('x2') }) -join '')
Write-Kayit 'baslatildi'

# Dispatcher yakalayıcısı yalnızca UI iş parçacığını kapsıyor. Arka plan
# iş parçacığındaki bir istisna (COM geri çağırması, zamanlayıcı havuzu)
# .NET'te süreci DOĞRUDAN sonlandırır — engellenemez, ama kaydedilebilir.
# Bu satır olmadan böyle bir ölüm günlükte hiçbir iz bırakmıyordu.
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($k, $o)
    try {
        $x = $o.ExceptionObject
        Write-Kayit ('OLUMCUL (UI disi): ' + $x.GetType().Name + ' - ' + $x.Message)
    } catch { }
})
$script:TekOrnek = New-Object System.Threading.Mutex($false, $kilitAdi)
if (-not $script:TekOrnek.WaitOne(0)) {
    # Zaten açık. Sessizce çık — ikinci pencere açmak faydadan çok zarar.
    # DİKKAT: burada Write-Tani ÇAĞRILAMAZ — o fonksiyon bu satırdan ~500 satır
    # sonra tanımlanıyor ve ErrorActionPreference='Stop' altında tanımsız komut
    # süreci düşürür. Betik yukarıdan aşağı çalışır; erken bloklarda yalnızca
    # o noktaya kadar tanımlanmış şeyler kullanılabilir.
    # SESSİZCE ÇIKMAK YETMİYOR — bu tam olarak "açtım, açılmadı" gibi
    # görünüyor. Kullanıcı kısayola basmışsa widget'ı GÖRMEK istiyordur;
    # pencere başka pencerelerin altında ya da ekran dışında olabilir.
    # Çalışan kopyaya not bırak, o kendini göstersin.
    try { Set-Content -Path $CagriDosya -Value ([DateTimeOffset]::Now.ToUnixTimeMilliseconds()) -Encoding UTF8 } catch { }
    Write-Kayit 'ikinci kopya: zaten calisiyor, calisana "kendini goster" notu birakildi'
    exit 0
}

$ArkaPlanlar = @{ yok = '00'; hafif = '59'; koyu = 'A6' }

# Renk temaları. Varsayılan dışındakiler yaygın açık kaynak paletlerden
# (Catppuccin Mocha, Dracula, Nord, Gruvbox Dark) — kod değil, yalnızca
# renk değerleri; her biri kendi projesinin MIT benzeri lisansı altında.
#
# Alanlar:
#   Zemin  kapsül rengi (alfa ArkaPlanlar'dan gelir)
#   Metin / Solgun   ana ve ikincil yazı
#   Ray    bar oluğu
#   Dusuk / Orta / Yuksek   bar dolgusu, %75 ve %90 eşiklerine göre
#   Bayat  veri eskiyince barın döndüğü renk
#   Sonuk  7 gün grafiğinde bugün olmayan çubuklar
$RENKLER = [ordered]@{
    varsayilan  = @{ Ad = 'Varsayilan';            Zemin = '000000'; Metin = '#F0F4FA'; Solgun = '#E8EDF5'
                     Ray = '#26FFFFFF'; Dusuk = '#4C8DF6'; Orta = '#E8A33D'; Yuksek = '#E5484D'
                     Bayat = '#5A6472'; Sonuk = '#3D5E8C' }
    catppuccin  = @{ Ad = 'Catppuccin Mocha'; Zemin = '1E1E2E'; Metin = '#CDD6F4'; Solgun = '#BAC2DE'
                     Ray = '#26FFFFFF'; Dusuk = '#89B4FA'; Orta = '#F9E2AF'; Yuksek = '#F38BA8'
                     Bayat = '#6C7086'; Sonuk = '#45475A' }
    dracula     = @{ Ad = 'Dracula';          Zemin = '282A36'; Metin = '#F8F8F2'; Solgun = '#D8D8D2'
                     Ray = '#26FFFFFF'; Dusuk = '#BD93F9'; Orta = '#F1FA8C'; Yuksek = '#FF5555'
                     Bayat = '#6272A4'; Sonuk = '#44475A' }
    nord        = @{ Ad = 'Nord';             Zemin = '2E3440'; Metin = '#ECEFF4'; Solgun = '#D8DEE9'
                     Ray = '#26FFFFFF'; Dusuk = '#88C0D0'; Orta = '#EBCB8B'; Yuksek = '#BF616A'
                     Bayat = '#616E88'; Sonuk = '#4C566A' }
    gruvbox     = @{ Ad = 'Gruvbox Dark';     Zemin = '282828'; Metin = '#EBDBB2'; Solgun = '#D5C4A1'
                     Ray = '#26FFFFFF'; Dusuk = '#83A598'; Orta = '#FABD2F'; Yuksek = '#FB4934'
                     Bayat = '#7C6F64'; Sonuk = '#504945' }
}
$script:Renk = $RENKLER['varsayilan']

function Get-Ayarlar {
    # esik5 / esikH : uyarı eşiği yüzdesi, 0 = kapalı
    # atesli5 / atesliH : uyarının verildiği pencerenin resets_at değeri.
    #   Pencere kimliği olarak resets_at kullanılıyor — yeni pencere başlayınca
    #   değer değişir ve uyarı hakkı kendiliğinden tazelenir. Zaman damgası
    #   tutup "24 saat geçti mi" diye bakmaktan daha doğru: kullanıcı için
    #   anlamlı sınır takvim değil, kotanın sıfırlanma anıdır.
    $v = [ordered]@{ sol = $null; ust = $null; arkaPlan = 'hafif'
                     esik5 = 0; esikH = 0; atesli5 = $null; atesliH = $null
                     tema = 'kart'; renk = 'varsayilan'
                     seritSol = $null; seritUst = $null
                     kompaktSol = $null; kompaktUst = $null
                     terminalSol = $null; terminalUst = $null
                     canliYoklama = 0; yoklamaOnaylandi = $false }
    if (Test-Path $AyarDosya) {
        try {
            $j = Get-Content $AyarDosya -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @('sol', 'ust', 'arkaPlan', 'esik5', 'esikH', 'atesli5', 'atesliH',
                             'tema', 'renk', 'seritSol', 'seritUst',
                             'kompaktSol', 'kompaktUst', 'terminalSol', 'terminalUst',
                             'canliYoklama', 'yoklamaOnaylandi')) {
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
# DİKKAT — [int] YUVARLAR, KIRPMAZ. [int](3.55) = 4, [int](119/60) = 2.
# Süre bileşenlerini ayırırken bu bir saat fazla gösteriyordu: 3 sa 32 dk
# kalan bir pencere "4 sa 32 dk" olarak yazılıyordu (dakika ≥ 30 olduğu her
# durumda). Saat/gün bileşeni DAİMA [Math]::Floor ile alınmalı.
function Format-Kalan {
    param([Nullable[datetime]]$Sifirlanma)
    if ($null -eq $Sifirlanma) { return '' }
    $fark = $Sifirlanma - [DateTime]::Now
    if ($fark.TotalSeconds -le 0) { return (T 'SIFIRLANDI') }
    if ($fark.TotalMinutes -lt 1) { return (T 'BIRAZDAN') }
    if ($fark.TotalHours -lt 1)   { return ((T 'KALAN_DK') -f [int][Math]::Floor($fark.TotalMinutes)) }
    return ((T 'KALAN_SADK') -f [int][Math]::Floor($fark.TotalHours), ($fark.Minutes))
}

# Bir ölçüm zamanı damgası kabul edilebilir mi? Tek ölçüt: makul bir paydan
# fazla İLERİDE olmasın. Geçmişteki eskilik ayrı bir mesele (bayatlık eşikleri).
function Test-OlcumZamani {
    param($Ms)
    if ($null -eq $Ms) { return $false }
    $ileriSn = ([double]$Ms - [double][DateTimeOffset]::Now.ToUnixTimeMilliseconds()) / 1000.0
    return ($ileriSn -le $GELECEK_PAYI_SN)
}

function Format-Yas {
    param([datetime]$Zaman)
    $fark = [DateTime]::Now - $Zaman
    # İleri tarihli damga "az önce" diye okunmasın — sebebini söyle.
    if ($fark.TotalSeconds -lt -$GELECEK_PAYI_SN) { return (T 'YAS_ILERI') }
    if ($fark.TotalSeconds -lt 90)  { return (T 'YAS_SIMDI') }
    if ($fark.TotalMinutes -lt 60)  { return ((T 'YAS_DK') -f [int][Math]::Floor($fark.TotalMinutes)) }
    if ($fark.TotalHours -lt 24)    { return ((T 'YAS_SA') -f [int][Math]::Floor($fark.TotalHours)) }
    return ((T 'YAS_GUN') -f [int][Math]::Floor($fark.TotalDays))
}

# Bar rengi. Sadece doluluğa değil TÜKETİM HIZINA da bakar: pencere
# sıfırlanmadan önce bitecek gibiyse doluluk düşük olsa bile kırmızı yanar.
# ("%60 dolu ama son 20 dakikada %30 yendi" durumu asıl tehlikeli olandır.)
function Get-BarRengi {
    param([double]$Yuzde, [Nullable[datetime]]$Sifirlanma, $BitisDk)

    if ($null -ne $BitisDk -and $null -ne $Sifirlanma) {
        $kalanDk = ($Sifirlanma - [DateTime]::Now).TotalMinutes
        if ($kalanDk -gt 0 -and [double]$BitisDk -lt $kalanDk) { return $script:Renk.Yuksek }
    }
    if ($Yuzde -ge 90) { return $script:Renk.Yuksek }
    if ($Yuzde -ge 75) { return $script:Renk.Orta }
    return $script:Renk.Dusuk
}

function Format-Sure {
    param([int]$Dakika)
    if ($Dakika -lt 60) { return ((T 'SURE_DK') -f $Dakika) }
    return ((T 'SURE_SADK') -f [int][Math]::Floor($Dakika / 60), ($Dakika % 60))
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
        MENU_TEMA='Görünüm'; TEMA_KART='Kart'; TEMA_SERIT='Şerit (alt bar)'; MENU_RENK='Renkler'
        HIZ_KISA='⚠ ~{0}'; MENU_BASLANGIC='Açılışta başlat'; MENU_YOKLAMA='Canlı yoklama (API)'; YOKLAMA_KAPALI='Kapalı (varsayılan)'
        YOKLAMA_SN='{0} saniyede bir'; KAYNAK_API='API'
        YOKLAMA_BASLIK='Canlı yoklamayı açmak üzeresiniz'
        YOKLAMA_UYARI=@'
Bu seçenek widget''ın çalışma biçimini değiştirir.

VARSAYILAN (kapalı): Widget yalnızca Claude''un zaten diske yazdığı dosyaları
okur. Hiçbir kimlik bilgisine dokunmaz, ağa çıkmaz. Gecikme: masaüstü
oturumlarında 15 dakikaya kadar.

AÇIK: Ayrı bir betik, Claude Code''un OAuth erişim jetonunu okuyup resmi
kullanım ucuna salt-okur istek atar. Gecikme ~{0} saniyeye iner.

Jeton hakkında: kullanım bilgisiyle sınırlı değildir — kapsamları arasında
"user:inference" vardır, yani Claude Code oturumunuzun yapabildiği her şeyi
yapabilir.

Bu ayarı istediğiniz zaman aynı menüden kapatabilirsiniz.

Açmak istiyor musunuz?
'@
        YOKLAMA_BETIK_YOK='Canlı yoklama açık ama kota-yokla.js bulunamadı — dosya kaynaklarına devam ediliyor.'
        HESAP_UYUSMAZ='Claude Code başka bir hesapta ({0}) — o kaynak yok sayıldı, sayılar masaüstü uygulamasının hesabından.'
        TEMA_KOMPAKT='Kompakt'; TEMA_TERMINAL='Terminal'
        SERIT_5SA='5sa'; SERIT_HAFTA='hafta'
        BASLIK='CLAUDE KULLANIM'; ETIKET_5SAAT='5 saatlik limit'; ETIKET_HAFTA='Haftalık'
        SON7='SON 7 GÜN'; BUGUN='bugün {0:0.0}×'; CANLI='canlı'; TAMAM='Tamam'; KAYNAK_MASAUSTU='masaüstü'
        SONRASI_KULLANIM='Ölçümden sonra Claude en az bir tur bitirdi — gerçek değer bundan yüksek.'
        SIFIRLANDI='sıfırlandı'; BIRAZDAN='birazdan sıfırlanır'
        KALAN_DK='{0} dk sonra'; KALAN_SADK='{0} sa {1} dk sonra'
        YAS_SIMDI='az önce'; YAS_DK='{0} dk önce'; YAS_SA='{0} sa önce'; YAS_GUN='{0} gün önce'
        YAS_ILERI='saat tutarsız'
        IC_HATA='Bir iç hata oluştu; ayrıntısı gunluk.txt dosyasında. Widget çalışmaya devam ediyor.'
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
        MENU_TEMA='Appearance'; TEMA_KART='Card'; TEMA_SERIT='Strip (taskbar)'; MENU_RENK='Colours'
        HIZ_KISA='⚠ ~{0}'; MENU_BASLANGIC='Start at sign-in'; MENU_YOKLAMA='Live polling (API)'; YOKLAMA_KAPALI='Off (default)'
        YOKLAMA_SN='Every {0} seconds'; KAYNAK_API='API'
        YOKLAMA_BASLIK='You are about to enable live polling'
        YOKLAMA_UYARI=@'
This option changes how the widget works.

DEFAULT (off): The widget only reads files Claude already writes to disk. It
touches no credentials and makes no network calls. Latency: up to 15 minutes
in desktop sessions.

ON: A separate script reads Claude Code''s OAuth access token and makes a
read-only request to the official usage endpoint. Latency drops to ~{0} seconds.

About the token: it is not scoped down to usage — its scopes include
"user:inference", so it can do anything your Claude Code session can.

You can turn this off again from the same menu at any time.

Do you want to enable it?
'@
        YOKLAMA_BETIK_YOK='Live polling is on but kota-yokla.js was not found — falling back to the file sources.'
        HESAP_UYUSMAZ='Claude Code is signed in to a different account ({0}) — that source is ignored; the numbers come from the desktop app account.'
        TEMA_KOMPAKT='Compact'; TEMA_TERMINAL='Terminal'
        SERIT_5SA='5h'; SERIT_HAFTA='week'
        BASLIK='CLAUDE USAGE'; ETIKET_5SAAT='5-hour limit'; ETIKET_HAFTA='Weekly'
        SON7='LAST 7 DAYS'; BUGUN='today {0:0.0}×'; CANLI='live'; TAMAM='OK'; KAYNAK_MASAUSTU='desktop'
        SONRASI_KULLANIM='Claude finished at least one turn after this measurement — the real value is higher.'
        SIFIRLANDI='reset'; BIRAZDAN='resetting shortly'
        KALAN_DK='in {0} min'; KALAN_SADK='in {0} h {1} min'
        YAS_SIMDI='just now'; YAS_DK='{0} min ago'; YAS_SA='{0} h ago'; YAS_GUN='{0} d ago'
        YAS_ILERI='clock mismatch'
        IC_HATA='An internal error occurred; details are in gunluk.txt. The widget is still running.'
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
        Title="Claude Usage"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="False" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight" WindowStartupLocation="Manual"
        UseLayoutRounding="True" TextOptions.TextRenderingMode="ClearType">

  <Window.Resources>
    <!-- Renkler DynamicResource: tema menüden değişince pencere yeniden
         kurulmadan güncellenir. Değerler Set-Renkler tarafından yazılır. -->
    <SolidColorBrush x:Key="RMetin"  Color="#F0F4FA"/>
    <SolidColorBrush x:Key="RSolgun" Color="#E8EDF5"/>
    <SolidColorBrush x:Key="RRay"    Color="#26FFFFFF"/>
    <SolidColorBrush x:Key="RDusuk"  Color="#4C8DF6"/>
    <SolidColorBrush x:Key="ROrta"   Color="#E8A33D"/>
    <SolidColorBrush x:Key="RYuksek" Color="#E5484D"/>
  </Window.Resources>

  <Window.ContextMenu>
    <ContextMenu>
      <MenuItem Header="@@MENU_ARKAPLAN@@">
        <MenuItem x:Name="MnuBgYok"   Header="@@MENU_YOK@@" IsCheckable="True"/>
        <MenuItem x:Name="MnuBgHafif" Header="@@MENU_HAFIF@@"            IsCheckable="True"/>
        <MenuItem x:Name="MnuBgKoyu"  Header="@@MENU_KOYU@@"             IsCheckable="True"/>
      </MenuItem>
      <MenuItem x:Name="MnuRenk" Header="@@MENU_RENK@@"/>
      <MenuItem Header="@@MENU_TEMA@@">
        <MenuItem x:Name="MnuTemaKart"  Header="@@TEMA_KART@@"  IsCheckable="True"/>
        <MenuItem x:Name="MnuTemaSerit" Header="@@TEMA_SERIT@@" IsCheckable="True"/>
        <MenuItem x:Name="MnuTemaKompakt" Header="@@TEMA_KOMPAKT@@" IsCheckable="True"/>
        <MenuItem x:Name="MnuTemaTerminal" Header="@@TEMA_TERMINAL@@" IsCheckable="True"/>
      </MenuItem>
      <MenuItem x:Name="MnuYoklama" Header="@@MENU_YOKLAMA@@"/>
      <MenuItem Header="@@MENU_ESIK@@">
        <MenuItem x:Name="MnuEsik5" Header="@@MENU_5SAAT@@"/>
        <MenuItem x:Name="MnuEsikH" Header="@@MENU_HAFTA@@"/>
      </MenuItem>
      <Separator/>
      <MenuItem x:Name="MnuBaslangic" Header="@@MENU_BASLANGIC@@" IsCheckable="True"/>
      <MenuItem x:Name="MnuSifirla" Header="@@MENU_SIFIRLA@@"/>
      <MenuItem x:Name="MnuKapat"   Header="@@MENU_KAPAT@@"/>
    </ContextMenu>
  </Window.ContextMenu>

  <Grid>
  <!-- ŞERİT (alt bar) teması: görev çubuğunun üstünde iki satırlık ince katman.
       5 saatlik ve haftalık ALT ALTA: yan yana dizilim 48 px'lik çubukta hem
       uzun hem de tek bakışta okunmuyordu. -->
  <Border x:Name="SeritKapsul" Visibility="Collapsed" CornerRadius="7" Padding="10,3,12,4"
          BorderBrush="{DynamicResource RRay}" BorderThickness="1">
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
                 Foreground="{DynamicResource RSolgun}" Opacity="0.5" VerticalAlignment="Center" Margin="0,0,10,0"/>

      <!-- 1. satır: 5 saat -->
      <TextBlock Grid.Row="0" Grid.Column="1" Text="@@SERIT_5SA@@" FontFamily="Segoe UI" FontSize="9.5"
                 Foreground="{DynamicResource RSolgun}" Opacity="0.55" VerticalAlignment="Center" TextAlignment="Right" Margin="0,0,6,0"/>
      <Border Grid.Row="0" Grid.Column="2" Width="70" Height="4" CornerRadius="2" Background="{DynamicResource RRay}" VerticalAlignment="Center">
        <Border x:Name="Serit5Dolgu" Width="0" CornerRadius="2" HorizontalAlignment="Left" Background="{DynamicResource RDusuk}"/>
      </Border>
      <TextBlock Grid.Row="0" Grid.Column="3" x:Name="Serit5Yuzde" FontFamily="Segoe UI" FontSize="10.5" FontWeight="SemiBold"
                 Foreground="{DynamicResource RMetin}" VerticalAlignment="Center" MinWidth="32" TextAlignment="Right" Margin="6,0,0,0"
                 Typography.NumeralAlignment="Tabular"/>
      <TextBlock Grid.Row="0" Grid.Column="4" x:Name="SeritKalan" FontFamily="Segoe UI" FontSize="9.5"
                 Foreground="{DynamicResource RSolgun}" Opacity="0.55" VerticalAlignment="Center" Margin="10,0,0,0"/>

      <!-- 2. satır: hafta -->
      <TextBlock Grid.Row="1" Grid.Column="1" Text="@@SERIT_HAFTA@@" FontFamily="Segoe UI" FontSize="9.5"
                 Foreground="{DynamicResource RSolgun}" Opacity="0.55" VerticalAlignment="Center" TextAlignment="Right" Margin="0,1,6,0"/>
      <Border Grid.Row="1" Grid.Column="2" Width="70" Height="4" CornerRadius="2" Background="{DynamicResource RRay}" VerticalAlignment="Center" Margin="0,1,0,0">
        <Border x:Name="SeritHDolgu" Width="0" CornerRadius="2" HorizontalAlignment="Left" Background="{DynamicResource RDusuk}"/>
      </Border>
      <TextBlock Grid.Row="1" Grid.Column="3" x:Name="SeritHYuzde" FontFamily="Segoe UI" FontSize="10.5" FontWeight="SemiBold"
                 Foreground="{DynamicResource RMetin}" VerticalAlignment="Center" MinWidth="32" TextAlignment="Right" Margin="6,1,0,0"
                 Typography.NumeralAlignment="Tabular"/>
      <TextBlock Grid.Row="1" Grid.Column="4" x:Name="SeritYas" FontFamily="Segoe UI" FontSize="9" Foreground="{DynamicResource ROrta}"
                 VerticalAlignment="Center" Margin="10,1,0,0"/>
    </Grid>
  </Border>

  <!-- KOMPAKT: yalnızca iki yüzde. Ekranda yer kaplamasın, göz ucuyla
       bakılsın diye; bar yok, sayı büyük. -->
  <Border x:Name="KompaktKapsul" Visibility="Collapsed" CornerRadius="10" Padding="12,8,12,9"
          BorderBrush="{DynamicResource RRay}" BorderThickness="1">
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <StackPanel Margin="0,0,14,0">
        <TextBlock Text="@@SERIT_5SA@@" FontFamily="Segoe UI" FontSize="9"
                   Foreground="{DynamicResource RSolgun}" Opacity="0.5" TextAlignment="Center"/>
        <TextBlock x:Name="Kompakt5" FontFamily="Segoe UI" FontSize="20" FontWeight="SemiBold"
                   Foreground="{DynamicResource RMetin}" TextAlignment="Center"
                   Typography.NumeralAlignment="Tabular" Margin="0,-2,0,0"/>
        <Border Width="46" Height="3" CornerRadius="1.5" Background="{DynamicResource RRay}" HorizontalAlignment="Center">
          <Border x:Name="Kompakt5Dolgu" Width="0" CornerRadius="1.5" HorizontalAlignment="Left" Background="{DynamicResource RDusuk}"/>
        </Border>
      </StackPanel>
      <StackPanel>
        <TextBlock Text="@@SERIT_HAFTA@@" FontFamily="Segoe UI" FontSize="9"
                   Foreground="{DynamicResource RSolgun}" Opacity="0.5" TextAlignment="Center"/>
        <TextBlock x:Name="KompaktH" FontFamily="Segoe UI" FontSize="20" FontWeight="SemiBold"
                   Foreground="{DynamicResource RMetin}" TextAlignment="Center"
                   Typography.NumeralAlignment="Tabular" Margin="0,-2,0,0"/>
        <Border Width="46" Height="3" CornerRadius="1.5" Background="{DynamicResource RRay}" HorizontalAlignment="Center">
          <Border x:Name="KompaktHDolgu" Width="0" CornerRadius="1.5" HorizontalAlignment="Left" Background="{DynamicResource RDusuk}"/>
        </Border>
      </StackPanel>
    </StackPanel>
  </Border>

  <!-- TERMINAL: tek aralıklı yazı tipi ve karakterden barlar. Kod yazarken
       ekranın geri kalanına karışmayan, "üçüncü bir terminal penceresi" gibi
       duran görünüm. Barlar Update-Terminal'de iki Run ile boyanıyor. -->
  <Border x:Name="TerminalKapsul" Visibility="Collapsed" CornerRadius="6" Padding="12,9,12,10"
          BorderBrush="{DynamicResource RRay}" BorderThickness="1">
    <StackPanel>
      <TextBlock FontFamily="Consolas,Cascadia Mono,Courier New" FontSize="10"
                 Foreground="{DynamicResource RSolgun}" Opacity="0.5" Text="claude ~ limits" Margin="0,0,0,4"/>
      <TextBlock x:Name="Terminal5" FontFamily="Consolas,Cascadia Mono,Courier New" FontSize="11.5"
                 Foreground="{DynamicResource RMetin}"/>
      <TextBlock x:Name="TerminalH" FontFamily="Consolas,Cascadia Mono,Courier New" FontSize="11.5"
                 Foreground="{DynamicResource RMetin}" Margin="0,2,0,0"/>
      <TextBlock x:Name="TerminalAlt" FontFamily="Consolas,Cascadia Mono,Courier New" FontSize="9.5"
                 Foreground="{DynamicResource RSolgun}" Opacity="0.45" Margin="0,4,0,0"/>
    </StackPanel>
  </Border>

  <Border x:Name="Kapsul" CornerRadius="16" Padding="18,13,18,15" Background="#59000000">
    <StackPanel x:Name="Kok" Width="232">
      <StackPanel.Effect>
        <DropShadowEffect BlurRadius="7" ShadowDepth="0" Opacity="0.9" Color="#FF000000"/>
      </StackPanel.Effect>

      <!-- baslik -->
      <Grid Margin="0,0,0,10">
        <TextBlock Text="@@BASLIK@@" FontFamily="Segoe UI" FontSize="9.5"
                   FontWeight="SemiBold" Foreground="{DynamicResource RSolgun}" Opacity="0.55"/>
        <TextBlock x:Name="Yas" HorizontalAlignment="Right" FontFamily="Segoe UI"
                   FontSize="9.5" Foreground="{DynamicResource RSolgun}" Opacity="0.45"/>
      </Grid>

      <!-- 5 saatlik limit -->
      <Grid Margin="0,0,0,5">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="@@ETIKET_5SAAT@@" FontFamily="Segoe UI" FontSize="11.5"
                   Foreground="{DynamicResource RMetin}"/>
        <TextBlock x:Name="Sifir5" Grid.Column="1" FontFamily="Segoe UI" FontSize="10.5"
                   Foreground="{DynamicResource RSolgun}" Opacity="0.5" TextAlignment="Right" Margin="10,1,10,0"/>
        <TextBlock x:Name="Yuzde5" Grid.Column="2" FontFamily="Segoe UI" FontSize="11.5"
                   FontWeight="SemiBold" Foreground="{DynamicResource RMetin}" TextAlignment="Right" MinWidth="34"
                   Typography.NumeralAlignment="Tabular"/>
      </Grid>
      <Border Width="232" Height="5" CornerRadius="2.5" Background="{DynamicResource RRay}" HorizontalAlignment="Left">
        <Border x:Name="Dolgu5" Width="0" CornerRadius="2.5" HorizontalAlignment="Left" Background="{DynamicResource RDusuk}"/>
      </Border>

      <!-- haftalik limit -->
      <Grid Margin="0,14,0,5">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="@@ETIKET_HAFTA@@" FontFamily="Segoe UI" FontSize="11.5"
                   Foreground="{DynamicResource RMetin}"/>
        <TextBlock x:Name="SifirH" Grid.Column="1" FontFamily="Segoe UI" FontSize="10.5"
                   Foreground="{DynamicResource RSolgun}" Opacity="0.5" TextAlignment="Right" Margin="10,1,10,0"/>
        <TextBlock x:Name="YuzdeH" Grid.Column="2" FontFamily="Segoe UI" FontSize="11.5"
                   FontWeight="SemiBold" Foreground="{DynamicResource RMetin}" TextAlignment="Right" MinWidth="34"
                   Typography.NumeralAlignment="Tabular"/>
      </Grid>
      <Border Width="232" Height="5" CornerRadius="2.5" Background="{DynamicResource RRay}" HorizontalAlignment="Left">
        <Border x:Name="DolguH" Width="0" CornerRadius="2.5" HorizontalAlignment="Left" Background="{DynamicResource RDusuk}"/>
      </Border>

      <!-- tuketim hizi uyarisi -->
      <TextBlock x:Name="HizUyari" FontFamily="Segoe UI" FontSize="10" Foreground="{DynamicResource RYuksek}"
                 Margin="0,9,0,0" Visibility="Collapsed" TextWrapping="Wrap" MaxWidth="232"/>

      <!-- son 7 gun -->
      <StackPanel x:Name="HaftaBolum" Margin="0,14,0,0" Visibility="Collapsed">
        <Grid>
          <TextBlock Text="@@SON7@@" FontFamily="Segoe UI" FontSize="9" FontWeight="SemiBold"
                     Foreground="{DynamicResource RSolgun}" Opacity="0.45"/>
          <TextBlock x:Name="BugunOzet" HorizontalAlignment="Right" FontFamily="Segoe UI"
                     FontSize="9" Foreground="{DynamicResource RSolgun}" Opacity="0.45"/>
        </Grid>
        <Grid Margin="0,6,0,0" Width="232" HorizontalAlignment="Left">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid Grid.Column="0">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub0" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="{DynamicResource RDusuk}"/>
            <TextBlock x:Name="Etk0" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="{DynamicResource RSolgun}" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="1">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub1" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="{DynamicResource RDusuk}"/>
            <TextBlock x:Name="Etk1" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="{DynamicResource RSolgun}" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="2">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub2" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="{DynamicResource RDusuk}"/>
            <TextBlock x:Name="Etk2" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="{DynamicResource RSolgun}" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="3">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub3" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="{DynamicResource RDusuk}"/>
            <TextBlock x:Name="Etk3" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="{DynamicResource RSolgun}" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="4">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub4" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="{DynamicResource RDusuk}"/>
            <TextBlock x:Name="Etk4" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="{DynamicResource RSolgun}" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="5">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub5" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="{DynamicResource RDusuk}"/>
            <TextBlock x:Name="Etk5" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="{DynamicResource RSolgun}" Opacity="0.4" Margin="0,3,0,0"/>
          </Grid>
          <Grid Grid.Column="6">
            <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Border x:Name="Cub6" Grid.Row="0" VerticalAlignment="Bottom" Height="2" Margin="4,0,4,0" CornerRadius="1.5" Background="{DynamicResource RDusuk}"/>
            <TextBlock x:Name="Etk6" Grid.Row="1" FontFamily="Segoe UI" FontSize="8.5" TextAlignment="Center" Foreground="{DynamicResource RSolgun}" Opacity="0.4" Margin="0,3,0,0"/>
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
      <TextBlock x:Name="Uyari" FontFamily="Segoe UI" FontSize="10.5" Foreground="{DynamicResource ROrta}"
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
# TICK HATALARI SESSİZ KALMAMALI.
#
# Tick'teki catch'lerin hepsi yalnızca Write-Tani'ye yazıyordu; o da
# KULLANIM_TANI=1 yoksa hiçbir şey yapmıyor. Update-Gorunum her turda patlasa
# bile kalıcı günlükte tek satır olmuyordu: "çalışıyor ama yenilenmiyor"
# şikâyetinde elimizde hiçbir kanıt kalmıyordu.
#
# Artık kalıcı günlüğe de yazılıyor. Saniyede bir tekrarlayan bir hata 300
# satırlık dosyayı boğmasın diye AYNI mesaj dakikada bir kez kaydediliyor.
$script:TickHataSon = @{}
function Write-TickHatasi {
    param([string]$Nerede, [string]$Mesaj)
    Write-Tani ("HATA {0}: {1}" -f $Nerede, $Mesaj)

    $anahtar = '{0}|{1}' -f $Nerede, $Mesaj
    $simdi = [DateTime]::Now
    if ($script:TickHataSon.ContainsKey($anahtar) -and
        ($simdi - $script:TickHataSon[$anahtar]).TotalSeconds -lt 60) { return }

    # Sözlük sınırsız büyümesin: anahtar tam hata METNİ ve bazı mesajlar içinde
    # değişken değer taşıyor. Günlerce çalışan bir süreçte bu sessiz bir
    # sızıntı olur; sınırı aşınca sıfırlıyoruz — en kötüsü bir mesaj bir kez
    # fazladan kaydedilir.
    if ($script:TickHataSon.Count -gt 64) { $script:TickHataSon.Clear() }

    $ilkDefa = -not $script:TickHataSon.ContainsKey($anahtar)
    $script:TickHataSon[$anahtar] = $simdi
    Write-Kayit ("TICK HATASI {0}: {1}" -f $Nerede, $Mesaj)

    # İÇ HATA YAZISI YALNIZCA ISRARLI HATADA.
    #
    # İlk denemede her tick hatası kartta kalıcı "iç hata" bırakıyordu; o yazı
    # en yüksek öncelikli olduğu için hesap uyuşmazlığı ve bayat veri
    # açıklamalarını da eziyordu. Tek seferlik bir aksaklık bunu hak etmiyor.
    # Aynı hata 60 saniyelik pencereyi aşıp TEKRAR gelirse kalıcıdır; asıl
    # söylemek istediğimiz de o.
    if (-not $ilkDefa) { $script:IcHata = $true }
}

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
$KompaktKapsul = Get-Ogesi 'KompaktKapsul'
$Kompakt5 = Get-Ogesi 'Kompakt5'; $Kompakt5Dolgu = Get-Ogesi 'Kompakt5Dolgu'
$KompaktH = Get-Ogesi 'KompaktH'; $KompaktHDolgu = Get-Ogesi 'KompaktHDolgu'
$TerminalKapsul = Get-Ogesi 'TerminalKapsul'
$Terminal5 = Get-Ogesi 'Terminal5'; $TerminalH = Get-Ogesi 'TerminalH'
$TerminalAlt = Get-Ogesi 'TerminalAlt'
$KOMPAKT_IZ = 46.0  # kompakt mini bar rayı (XAML ile aynı)
$TERMINAL_HANE = 14 # terminal barındaki karakter sayısı
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
$script:Kota = $null                  # canlı yoklama sonucu (opsiyonel kaynak)
$script:KotaSonYazma = [datetime]::MinValue
$script:KotaHataSonYazma = [datetime]::MinValue
$script:SonYoklama = [datetime]::MinValue
$script:YoklayiciUyarildi = $false
$script:YoklamaAralik = 0     # yürürlükteki aralık (geri çekilmeyle büyür)
# UYARLANABİLİR TABAN — geri çekilmenin yakınsaması için.
#
# Eski kural "başarıda aralığı yarıya indir, tabana kadar" idi. Taban 60 iken
# 120'nin yarısı tam tabana düşüyor, oradan anında yine 429 geliyor: günlükte
# saatte ~20 kez tekrarlayan sonsuz 60↔120 salınımı. Salınımı bitirmek için
# BAŞARISIZ OLDUĞU KANITLANAN aralık taban olarak yükseltilir; koşullar
# düzelirse yeterince ardışık başarıdan sonra bir kademe geri inilir.
$script:YoklamaTaban = 0      # yürürlükteki alt sınır (kullanıcı ayarından küçük olamaz)
$script:ArdisikBasari = 0     # tabanı indirmeyi denemek için sayaç
# Tabanın inişi SAYAÇA DEĞİL DUVAR SAATİNE bağlı.
#
# İki uç da denendi ve ikisi de yanlıştı. "Her hatada tabanı yükselt + 10
# ardışık başarıda indir": uç nokta yoklamaların yarısına 429 dönerken 10
# ardışık başarı hiç gelmiyor, taban tavanda kilitleniyor. "Tabanı yalnızca
# ardışık iki hatada yükselt": aralıklı 429'da her başarı tabanı tekrar 60'a
# çekiyor ve 43f6afa'da öldürülen 60↔120 salınımı geri geliyor (ölçüldü).
#
# Doğrusu: taban HER uzak hatada yükselir (salınım imkânsız), ama bir süredir
# uzak hata GELMEDİYSE bir kademe iner. Böylece gerçekten düzelen bir uç
# dakikalar içinde tabana dönüyor, hâlâ bozuk olan uç ise tırmandığı yerde
# kalıyor.
$script:SonUzakHata = [datetime]::MinValue
$script:YoklamaHesapKisitli = $false   # tavan hesap uyuşmazlığı yüzünden mi
$script:HizKisa = $null               # dar yerleşimler için kısa hız uyarısı
$script:IcHata = $false               # yakalanmış iç hata oldu mu (kalıcı)
$script:Baslangic = [DateTime]::Now   # kalp atışı için
$script:VurguBitis = $null            # "kendini göster" vurgusunun bitiş anı
$script:SonOlayMs = [int64]0          # hook'un yazdığı son olayın zamanı
$script:OlayHam = $null               # olay.json'un çözümlenmiş son hâli
$script:OlaySonYazma = [datetime]::MinValue
$script:KullanimSonrasi = $false     # ölçümden sonra Claude tur bitirdi mi
$script:VeriTaze = $false    # veri hiç okunmadan uyarı tetiklenmesin

# HESAP KİMLİĞİ — kaynaklar aynı hesaba ait olmak ZORUNDA.
#
# Bir makinede birden fazla Claude hesabı olabilir: Claude Code bir hesaba,
# masaüstü uygulaması başkasına bağlı olabilir. Üç kaynağı "aynı gerçeğin
# fotoğrafı" saymak o zaman yanlış oluyor — üretimde masaüstü %81 derken API
# %4 diyordu ve bar ikisi arasında gidip geliyordu.
#
# Yetkili hesap MASAÜSTÜ UYGULAMASININ hesabıdır: widget onun penceresini
# gösterir. Diğer kaynaklar ancak aynı organizasyona aitse kabul edilir.
# Damgası olmayan (eski sürüm betiklerin yazdığı) kayıt reddedilmez —
# yükseltme sırasında ekranı boşaltmak, yanlış hesabı göstermekten daha kötü
# olurdu; betikler bir sonraki yazımda damgayı zaten koyar.
$script:YetkiliHesap = $null          # masaüstü kaynağının organizasyon kimliği
$script:RedEdilenHesap = $null        # uyuşmazlık yüzünden yok sayılan kaynağın e-postası


function ConvertTo-Fircasi { param([string]$Renk) [Windows.Media.BrushConverter]::new().ConvertFromString($Renk) }

# Renk teması. Kaynak sözlüğüne yazdığı için XAML'deki her DynamicResource
# kendiliğinden güncellenir; koddan boyanan yerler (barlar, hafta çubukları)
# bir sonraki Update-Gorunum turunda zaten yeniden renklenir.
function Set-Renkler {
    param([string]$Ad, [switch]$Kaydetme)

    if (-not $RENKLER.Contains($Ad)) { $Ad = 'varsayilan' }
    $script:Ayar.renk = $Ad
    $script:Renk = $RENKLER[$Ad]

    foreach ($es in @(@('RMetin', 'Metin'), @('RSolgun', 'Solgun'), @('RRay', 'Ray'),
                      @('RDusuk', 'Dusuk'), @('ROrta', 'Orta'), @('RYuksek', 'Yuksek'))) {
        $win.Resources[$es[0]] = ConvertTo-Fircasi $script:Renk[$es[1]]
    }

    Set-ArkaPlan $script:Ayar.arkaPlan       # zemin rengi temadan geliyor
    foreach ($oge in (Get-Ogesi 'MnuRenk').Items) { $oge.IsChecked = ([string]$oge.Tag -eq $Ad) }
    if (-not $Kaydetme) { Save-Ayarlar -Ayar $script:Ayar }
    Update-Gorunum
}

function Set-ArkaPlan {
    param([string]$Ad)
    if (-not $ArkaPlanlar.ContainsKey($Ad)) { $Ad = 'hafif' }
    $script:Ayar.arkaPlan = $Ad
    # Alfa seçimden, RGB temadan: '#59' + '1E1E2E'
    $Kapsul.Background = ConvertTo-Fircasi ('#{0}{1}' -f $ArkaPlanlar[$Ad], $script:Renk.Zemin)
    # Şerit her zaman okunur kalmalı — görev çubuğunun üstünde saydam bir
    # şerit zemine karışıyor; onun alfası sabit tutuluyor.
    # Şerit/kompakt/terminal görev çubuğu ya da pencere üstünde durabiliyor;
    # okunurluk için zeminleri saydamlık seçiminden bağımsız, sabit koyu.
    $koyuZemin = ConvertTo-Fircasi ('#D9{0}' -f $script:Renk.Zemin)
    $SeritKapsul.Background    = $koyuZemin
    $KompaktKapsul.Background  = $koyuZemin
    $TerminalKapsul.Background = $koyuZemin
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
# Yerleşimler ve pencere davranışları.
#   Dipte : masaüstü seviyesinde mi dursun (kart gibi) yoksa üstte mi (şerit)
#   Anahtar : ayar dosyasındaki konum anahtarlarının ön eki
$YERLESIMLER = [ordered]@{
    kart     = @{ Menu = 'MnuTemaKart';     Dipte = $true;  Onek = ''         }
    serit    = @{ Menu = 'MnuTemaSerit';    Dipte = $false; Onek = 'serit'    }
    kompakt  = @{ Menu = 'MnuTemaKompakt';  Dipte = $true;  Onek = 'kompakt'  }
    terminal = @{ Menu = 'MnuTemaTerminal'; Dipte = $true;  Onek = 'terminal' }
}

function Set-Tema {
    param([string]$Ad, [switch]$Kaydetme)

    if (-not $YERLESIMLER.Contains($Ad)) { $Ad = 'kart' }
    $script:Ayar.tema = $Ad
    $y = $YERLESIMLER[$Ad]

    $Kapsul.Visibility         = $(if ($Ad -eq 'kart')     { 'Visible' } else { 'Collapsed' })
    $SeritKapsul.Visibility    = $(if ($Ad -eq 'serit')    { 'Visible' } else { 'Collapsed' })
    $KompaktKapsul.Visibility  = $(if ($Ad -eq 'kompakt')  { 'Visible' } else { 'Collapsed' })
    $TerminalKapsul.Visibility = $(if ($Ad -eq 'terminal') { 'Visible' } else { 'Collapsed' })

    [ZDuzeni]::Dipte = $y.Dipte
    $win.Topmost = -not $y.Dipte

    foreach ($k in $YERLESIMLER.Keys) { (Get-Ogesi $YERLESIMLER[$k].Menu).IsChecked = ($k -eq $Ad) }

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

# Her yerleşim kendi konumunu tutar; ortak tek konum olsaydı her geçişte
# biri kayardı. Anahtarlar: kart -> sol/ust, diğerleri -> <ön ek>Sol/<ön ek>Ust.
function Get-KonumAnahtari {
    # Ayar dosyası elle düzenlenmiş olabilir; tanınmayan yerleşim adı burada
    # null başvuruya dönüşmesin. Set-Tema da aynı şekilde karta düşüyor.
    $ad = [string]$script:Ayar.tema
    if (-not $YERLESIMLER.Contains($ad)) { $ad = 'kart' }
    $onek = $YERLESIMLER[$ad].Onek
    if ($onek -eq '') { return @('sol', 'ust') }
    return @(($onek + 'Sol'), ($onek + 'Ust'))
}

function Set-TemaKonumuSimdi {
    $win.UpdateLayout()
    $a = Get-KonumAnahtari

    if ($null -ne $script:Ayar.($a[0]) -and $null -ne $script:Ayar.($a[1])) {
        Set-PencereKonumu -Sol ([double]$script:Ayar.($a[0])) -Ust ([double]$script:Ayar.($a[1]))
    } elseif ($script:Ayar.tema -eq 'serit') {
        Set-SeritVarsayilanKonumu
    } else {
        Set-VarsayilanKonum
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
        if ($bilgi.LastWriteTime -eq $script:SonYazma) { return }   # değişmediyse okuma
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

# SON 7 GÜN GRAFİĞİNİ MASAÜSTÜ SERİSİNDEN TÜRET
#
# `haftalik` yalnızca durum.json'da vardı, onu da yalnızca terminaldeki
# statusLine yazıyor. Masaüstünde çalışan bir kullanıcıda grafik son terminal
# oturumunda donup kalıyor — üstelik birleştirme taze kazananın damgasını
# kaydın tamamına vurduğu için ekran "api · şimdi" derken grafiğin verisi
# günler öncesine ait oluyordu. Kartın en görünür parçası buydu.
#
# Veri zaten elimizde: masaüstü dosyası 30 günlük örnek tutuyor. Semantik
# durum-yaz.js'teki gecmisIsle ile AYNI: günlük tüketim, 5 saatlik pencerenin
# ARTIŞLARININ toplamıdır; pencere sıfırlandığında (değer düştüğünde) yeni
# değerin kendisi eklenir.
#
# Fark: masaüstü 15 dakikada bir örnekliyor, statusLine 60 saniyede bir. İki
# örnek arasına sığan bir sıfırlanma görülmez, yani bu toplam bir ALT SINIR.
# Yanlış değil, eksik — ve donmuş bir grafikten kat kat iyi.
function Get-MasaustuHaftalik {
    param($Ornekler)

    # YALNIZCA SON 8 GÜN. Masaüstü dosyası 30 günlük örnek tutuyor ve bu
    # fonksiyon UI iş parçacığında, dosya her değiştiğinde (15 dk'da bir)
    # çalışıyor. 7 gün çiziyoruz; 8. gün yalnızca ilk günün artışını
    # hesaplayabilmek için gereken çapa. Tamamını taramak boşuna gecikme.
    $sinir = [DateTimeOffset]::new([DateTime]::Now.Date.AddDays(-7)).ToUnixTimeMilliseconds()
    $gunler = @{}
    $onceki = $null
    foreach ($o in $Ornekler) {
        if ([int64]$o.t -lt $sinir) { continue }
        if (-not (Test-Ozellik $o.u 'fh')) { continue }
        $fh = [double]$o.u.fh
        if ($null -ne $onceki) {
            $fark = $fh - $onceki
            $eklenecek = if ($fark -ge 0) { $fark } else { $fh }
            if ($eklenecek -gt 0) {
                $anahtar = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$o.t).LocalDateTime.ToString('yyyy-MM-dd')
                if (-not $gunler.ContainsKey($anahtar)) { $gunler[$anahtar] = @{ tuketim = 0.0; zirve = 0.0 } }
                $gunler[$anahtar].tuketim += $eklenecek
                if ((Test-Ozellik $o.u 'sd') -and [double]$o.u.sd -gt $gunler[$anahtar].zirve) {
                    $gunler[$anahtar].zirve = [double]$o.u.sd
                }
            }
        }
        $onceki = $fh
    }

    $bugun = [DateTime]::Now.Date
    $liste = @()
    for ($i = 6; $i -ge 0; $i--) {
        $anahtar = $bugun.AddDays(-$i).ToString('yyyy-MM-dd')
        $g = $gunler[$anahtar]
        $liste += [pscustomobject]@{
            gun     = $anahtar
            tuketim = $(if ($null -eq $g) { 0.0 } else { [Math]::Round($g.tuketim, 1) })
            zirve   = $(if ($null -eq $g) { 0.0 } else { [Math]::Round($g.zirve, 0) })
        }
    }
    # "VERİ YOK" ile "SIFIR TÜKETİM" AYNI ŞEY DEĞİL.
    #
    # Seriden hiç artış türetilemiyorsa (tek örnek, hepsi aynı değer, ya da
    # yalnızca sd taşıyan örnekler) yedi sıfır dönmek, durum.json'da duran
    # gerçek bir grafiği ezip bölümü kapatıyordu. Türetemiyorsak $null deriz
    # ve birleştirme diğer kaynağı korur.
    $toplam = ($liste | ForEach-Object { $_.tuketim } | Measure-Object -Sum).Sum
    if ($null -eq $toplam -or $toplam -le 0) { return $null }
    return $liste
}

function Read-Masaustu {
    # YETKİLİ HESAP, MASAÜSTÜ KAYDIYLA AYNI ÖMRE SAHİP.
    #
    # Kimlik ayrı bir değişkende tutulduğu için kayıt null'lanırken o yerinde
    # kalabiliyordu: masaüstü dosyası silinince/bozulunca "hayalet yetkili
    # hesap" kalıyor ve diğer iki kaynak artık kıyaslanacak gerçek bir otorite
    # olmadan reddedilmeye devam ediyordu — kart hiçbir açıklama vermeden
    # boşalıyordu. Kaydı null'layan her yer kimliği de null'lar.
    #
    # catch bloğu bilerek dışarıda: orada hem kayıt hem kimlik korunuyor.
    if (-not (Test-Path $MasaustuDosya)) { $script:Masaustu = $null; $script:YetkiliHesap = $null; return }
    try {
        $bilgi = Get-Item $MasaustuDosya
        if ($bilgi.LastWriteTime -eq $script:MasaustuSonYazma) { return }
        $j = Get-Content $MasaustuDosya -Raw -Encoding UTF8 | ConvertFrom-Json
        # Damga AYRIŞTIRMADAN HEMEN SONRA basılır, doğrulamadan önce.
        #
        # Bir ara şema kapısının arkasına alınmıştı ("kapıya takılan dosya
        # görülmüş sayılmasın" diye) ama bu daha kötüydü: tanınmayan biçimdeki
        # 66 KB'lık dosya SANİYEDE BİR yeniden okunup ayrıştırılmaya başladı.
        # Kapılar dosyanın baytları üzerinde deterministik; aynı baytları
        # tekrar tekrar elemek saf israf. Yarım yazılmış dosya zaten bu satıra
        # ulaşmadan yukarıda throw eder ve damga basılmadığı için tekrar
        # denenir — korunmak istenen durum buydu ve hâlâ korunuyor.
        $script:MasaustuSonYazma = $bilgi.LastWriteTime

        # Şema kapısı: bildiğimiz biçim değilse hiç yorumlamaya kalkma.
        if (-not (Test-Ozellik $j 'version') -or [int]$j.version -ne 2 -or -not (Test-Ozellik $j 'samples')) {
            Write-Tani 'masaustu: sema uyumsuz, yok sayildi'
            $script:Masaustu = $null; $script:YetkiliHesap = $null; return
        }
        # Süzme örnek listesinin TAMAMINA uygulanıyor: hız hesabı ve pencere
        # başlangıcı da bu seriden türüyor, ileri tarihli tek örnek ikisini de
        # bozardı.
        $ham = @($j.samples | Where-Object { (Test-Ozellik $_ 't') -and (Test-Ozellik $_ 'u') } |
                 Sort-Object { [int64]$_.t })
        $ornekler = @($ham | Where-Object { Test-OlcumZamani ([int64]$_.t) })
        if ($ornekler.Count -lt $ham.Count) {
            Write-Tani ("masaustu: {0} ileri tarihli ornek atildi" -f ($ham.Count - $ornekler.Count))
        }
        if ($ornekler.Count -eq 0) { $script:Masaustu = $null; $script:YetkiliHesap = $null; return }
        $son = $ornekler[-1]

        $fh = if (Test-Ozellik $son.u 'fh') { [double]$son.u.fh } else { $null }
        $sd = if (Test-Ozellik $son.u 'sd') { [double]$son.u.sd } else { $null }

        # YETKİLİ HESAP burada belirleniyor. Masaüstü uygulaması hangi hesaba
        # bağlıysa widget onun penceresini gösterir; diğer kaynaklar ancak aynı
        # organizasyona aitse kabul edilir. Alan dosyada zaten vardı, yalnızca
        # okunmuyordu.
        $org = if (Test-Ozellik $son 'org') { [string]$son.org } else { $null }
        $script:YetkiliHesap = $org

        $script:Masaustu = [pscustomobject]@{
            t   = [int64]$son.t
            fh  = $fh
            sd  = $sd
            org = $org
            hiz = $(if ($null -ne $fh) { Get-MasaustuHiz -Ornekler $ornekler -SimdiMs ([int64]$son.t) -Fh $fh } else { $null })
            haftalik = Get-MasaustuHaftalik -Ornekler $ornekler
            pencere5 = Get-PencereBaslangici -Ornekler $ornekler -Alan 'fh'
            pencereH = Get-PencereBaslangici -Ornekler $ornekler -Alan 'sd'
        }
        Write-Tani ("masaustu: t={0} fh={1} sd={2} ornek={3} org={4}" -f $son.t, $fh, $sd, $ornekler.Count, $org)
    } catch {
        Write-Tani ("masaustu: okuma hatasi " + $_.Exception.Message)
    }
}

# Canlı yoklama sonucu. Widget burada da yalnızca OKUR; jetonu gören tek yer
# kota-yokla.js'tir. Dosya bir hata durumu taşıyorsa (jeton yok, süresi dolmuş,
# HTTP hatası) sessizce yok sayılır — dosya kaynakları zaten yerinde.
function Read-Kota {
    if ($script:Ayar.canliYoklama -le 0) { $script:Kota = $null; return }
    if (-not (Test-Path $KotaDosya)) { $script:Kota = $null; return }
    try {
        $bilgi = Get-Item $KotaDosya
        if ($bilgi.LastWriteTime -eq $script:KotaSonYazma) { return }
        $j = Get-Content $KotaDosya -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:KotaSonYazma = $bilgi.LastWriteTime

        # ESKİ BİÇİM. Hata kaydı bir zamanlar kota.json'un üstüne yazılıyordu;
        # artık kota-hata.json'a gidiyor. Yükseltmeden önce kalmış böyle bir
        # dosyaya denk gelebiliriz — veri değil, yok say. Bir sonraki başarılı
        # yoklama üstüne yazar.
        if (Test-Ozellik $j 'hata') { $script:Kota = $null; return }

        $olcum = if (Test-Ozellik $j 'olcumZamani') { [int64]$j.olcumZamani } else { $null }
        if (-not (Test-OlcumZamani $olcum)) {
            Write-Tani 'kota: ileri tarihli olcum, yok sayildi'
            $script:Kota = $null; return
        }
        if (-not (Test-Ozellik $j 'five_hour') -and -not (Test-Ozellik $j 'seven_day')) {
            $script:Kota = $null; return
        }
        $script:Kota = $j
        Set-YoklamaBasari
        Write-Tani ("kota: olcum={0} f5={1}" -f $olcum, $j.five_hour.used_percentage)
    } catch {
        Write-Tani ("kota: okuma hatasi " + $_.Exception.Message)
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Yoklama aralığı — UYARLANABİLİR TABAN
#
# Uç nokta üçüncü-parti yoklamayı sınırlıyor. Eski kural "hatada ikiye katla,
# başarıda yarıya indir, tabana kadar" idi ve YAKINSAMIYORDU: taban 60 iken
# 120'nin yarısı tam tabana düşüyor, oradan anında yine 429 geliyordu. Günlükte
# saatte ~20 kez tekrarlayan 60↔120 salınımı bundandı.
#
# Yeni kural: BAŞARISIZ OLDUĞU KANITLANAN aralık taban olarak yükseltilir.
# Böylece sistem uç noktanın kaldırdığı hıza oturur. Koşullar düzelebileceği
# için yeterince ardışık başarıdan sonra taban bir kademe geri denenir —
# ama her başarıda değil, yoksa eski salınım geri gelir.
# ─────────────────────────────────────────────────────────────────────────────
function Set-YoklamaBasari {
    $ayar = [int]$script:Ayar.canliYoklama
    if ($script:YoklamaTaban -lt $ayar) { $script:YoklamaTaban = $ayar }
    $script:ArdisikBasari++

    # HESAP KISITI VARSA TABAN HİÇ İNMEZ.
    #
    # Oradaki tavan bir hız sınırı değil: jeton başka hesaba ait ve sonuç zaten
    # atılıyor. İniş ölçütü ("uzak hata gelmedi") burada her zaman doğru çıkıyor
    # — çünkü gerçekten hata almıyoruz, sadece yanlış hesabı okuyoruz. Üretimde
    # bu, 900 → 450 → 900 arasında saniyede bir salınım ve günlük kirlenmesi
    # olarak göründü. Tavanı yalnızca Clear-YoklamaHesapKisiti kaldırır.
    if ($script:YoklamaHesapKisitli) { return }

    # İki yoldan biri yeterli: yeterince ardışık başarı, YA DA bir süredir uzak
    # hata gelmemiş olması. İkincisi olmadan, hataların yarı yarıya geldiği bir
    # uçta taban hiç inemiyordu.
    $hatasizDk = ($script:SonUzakHata -eq [datetime]::MinValue) `
        -or (([DateTime]::Now - $script:SonUzakHata).TotalMinutes -ge $YOKLAMA_INIS_DK)
    if ($script:YoklamaTaban -gt $ayar -and
        ($script:ArdisikBasari -ge $YOKLAMA_INIS_BASARI -or $hatasizDk)) {
        $yeni = [Math]::Max($ayar, [int]($script:YoklamaTaban / 2))
        if ($yeni -ne $script:YoklamaTaban) {
            Write-Kayit ("canli yoklama tabani indirildi: {0} sn ({1} ardisik basari)" -f `
                $yeni, $script:ArdisikBasari)
            $script:YoklamaTaban = $yeni
        }
        $script:ArdisikBasari = 0
    }

    if ($script:YoklamaAralik -ne $script:YoklamaTaban) {
        Write-Kayit ("canli yoklama siklasti: {0} sn" -f $script:YoklamaTaban)
        $script:YoklamaAralik = $script:YoklamaTaban
    }
}

function Set-YoklamaHata {
    param($Hata)
    $ayar = [int]$script:Ayar.canliYoklama
    if ($script:YoklamaTaban -lt $ayar) { $script:YoklamaTaban = $ayar }
    $script:ArdisikBasari = 0

    # YEREL hatada geri ÇEKİLME: jeton süresi dolmuş, kimlik dosyası yok gibi
    # durumlarda yoklayıcı hiç istek atmıyor — idare edilecek bir uzak çağrı
    # yok. Durum her an kendiliğinden düzelebilir (Claude Code kullanıldıkça
    # jetonu tazeler) ve 900 saniyeye çıkmış bir aralık bunu 15 dakika geç fark
    # eder. Tabanda kal.
    if ((Test-Ozellik $Hata 'yerel') -and $Hata.yerel) {
        if ($script:YoklamaAralik -ne $script:YoklamaTaban) {
            Write-Kayit ("canli yoklama tabana alindi ({0} sn): yerel durum, ag istegi yok ({1})" -f `
                $script:YoklamaTaban, [string]$Hata.hata)
        }
        $script:YoklamaAralik = $script:YoklamaTaban
        return
    }

    # Uzak hata: BU ARALIK ÇALIŞMIYOR. İkiye katla ve tabanı da oraya çek —
    # bir daha aynı duvara toslamayalım. Sunucu Retry-After söylediyse ONA
    # uyulur; bizim ikiye katlamamızdan daha bilgili bir sayıdır.
    $script:SonUzakHata = [DateTime]::Now
    $yeni = [Math]::Min([Math]::Max($script:YoklamaAralik, $script:YoklamaTaban) * 2, $YOKLAMA_TAVAN_SN)
    if ((Test-Ozellik $Hata 'tekrarSn') -and [int]$Hata.tekrarSn -gt 0) {
        $yeni = [Math]::Max($yeni, [Math]::Min([int]$Hata.tekrarSn, $YOKLAMA_TAVAN_SN))
    }
    if ($yeni -ne $script:YoklamaAralik) {
        Write-Kayit ("canli yoklama geri cekildi: {0} sn (hata: {1}{2})" -f `
            $yeni, [string]$Hata.hata, $(if (Test-Ozellik $Hata 'http') { ' ' + $Hata.http } else { '' }))
    }
    $script:YoklamaAralik = $yeni
    # Taban HER uzak hatada yükselir: başarısız olduğu kanıtlanan aralığa geri
    # dönmek salınımdan başka bir şey üretmiyor. İniş yolu yukarıdaki
    # zaman ölçütü.
    if ($script:YoklamaTaban -lt $yeni) { $script:YoklamaTaban = $yeni }
}

# YABANCI HESABI YOKLAMAYA DEVAM ETMENİN ANLAMI YOK.
#
# Yoklayıcı Claude Code'un jetonunu kullanır; o hesap masaüstününkinden
# farklıysa gelen sonuç zaten reddediliyor. Dakikada bir ağa çıkıp atacağımız
# bir cevabı istemek hem boşuna hem de uç noktayı gereksiz yere zorluyor
# (429'ların bir kısmı bundandı).
#
# Yoklamayı tamamen DURDURMUYORUZ: kullanıcı Claude Code'u diğer hesaba
# geçirebilir ve widget bunu fark etmeli. Tavana çekiyoruz — 15 dakikada bir
# yoklama, durum düzelirse Set-YoklamaBasari tabanı yeniden indirir.
# Hesap düzeldiğinde tavanı HEMEN bırak.
#
# Tavan bir hız sınırı yüzünden değil, hesap yüzünden konmuştu; sebep ortadan
# kalkınca normal iniş kuralını (10 ardışık başarı) beklemek yanlış olurdu —
# ölçüldü: 900 sn aralıkla tabana dönmek ~10 saat sürüyordu.
function Clear-YoklamaHesapKisiti {
    if (-not $script:YoklamaHesapKisitli) { return }
    $ayar = [int]$script:Ayar.canliYoklama
    Write-Kayit ("canli yoklama tabana alindi ({0} sn): jeton artik dogru hesapta" -f $ayar)
    $script:YoklamaHesapKisitli = $false
    $script:YoklamaTaban  = $ayar
    $script:YoklamaAralik = $ayar
    $script:ArdisikBasari = 0
    $script:SonUzakHata   = [datetime]::MinValue
}

function Set-YoklamaHesapUyusmazligi {
    # SAYAÇ ÖNCE SIFIRLANIR, erken çıkıştan önce. Yabancı hesabın yoklaması ağ
    # açısından "başarılı" sayıldığı için Set-YoklamaBasari sayacı ilerletiyor;
    # sıfırlamasak 10 yoklamada bir taban inip tekrar tavana çıkardı.
    $script:ArdisikBasari = 0
    $script:YoklamaHesapKisitli = $true

    if ($script:YoklamaTaban -ge $YOKLAMA_TAVAN_SN) { return }   # zaten tavanda
    Write-Kayit ("canli yoklama tavana alindi ({0} sn): jeton baska hesaba ait" -f $YOKLAMA_TAVAN_SN)
    $script:YoklamaTaban  = $YOKLAMA_TAVAN_SN
    $script:YoklamaAralik = $YOKLAMA_TAVAN_SN
}

# Yoklayıcının bıraktığı hata kaydı. Başarıda dosyayı kendisi siliyor, yani
# "dosya yok" = son yoklama temiz demektir.
function Read-YoklamaHatasi {
    if ($script:Ayar.canliYoklama -le 0) { return }
    if (-not (Test-Path $KotaHataDosya)) { return }
    try {
        $bilgi = Get-Item $KotaHataDosya
        if ($bilgi.LastWriteTime -eq $script:KotaHataSonYazma) { return }   # yeni hata yok
        $j = Get-Content $KotaHataDosya -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:KotaHataSonYazma = $bilgi.LastWriteTime
        if (Test-Ozellik $j 'hata') { Set-YoklamaHata $j }
    } catch {
        Write-Tani ("kota-hata: okuma hatasi " + $_.Exception.Message)
    }
}

# ŞERİT GÖREV ÇUBUĞUNUN ALTINDA KALIYOR
#
# Şerit teması çubuğun ÜSTÜNDE durmalı. İkisi de topmost, ama topmost bandının
# kendi içinde bir sıra var: explorer çubuğu öne aldığında (Başlat'a basmak,
# çubuğa tıklamak, explorer'ın yeniden başlaması) biz altında kalıyoruz.
#
# WM_WINDOWPOSCHANGING kancası burada yardım edemiyor: o mesaj yalnızca BİZİM
# konumumuz değişirken geliyor, başka bir pencere kendini öne aldığında değil.
# WPF'in `$win.Topmost = $true` ataması da işe yaramıyor — değer zaten $true
# olduğu için hiçbir SetWindowPos çağrısı üretmiyor.
#
# Kör yoklama yapmıyoruz (1.2.0'daki 2 saniyelik SetWindowPos döngüsü masaüstü
# sağ tık menüsünü bozmuştu). Bunun yerine ÖLÇÜYORUZ: kendi merkezimizdeki
# piksel bize mi ait? Değilse örtülmüşüz, yalnızca o zaman öne alıyoruz.
function Update-SeritUstte {
    if ($script:Ayar.tema -ne 'serit') { return }
    if ($null -ne $script:VurguBitis) { return }      # vurgu zaten üstte tutuyor
    if ($win.ActualWidth -le 0 -or $win.ActualHeight -le 0) { return }

    $hwnd = Get-Tutamac
    if ($hwnd -eq [IntPtr]::Zero) { return }

    # WindowFromPoint FİZİKSEL piksel ister; konumlarımız DIP.
    $olcek = Get-DpiOlcegi
    $n = New-Object 'Widget.Win32+POINT'
    $n.X = [int]((($script:KonumSol + $win.ActualWidth  / 2)) * $olcek)
    $n.Y = [int]((($script:KonumUst  + $win.ActualHeight / 2)) * $olcek)

    $ust = [Widget.Win32]::WindowFromPoint($n)
    if ($ust -eq [IntPtr]::Zero) { return }
    $sahip = 0
    [void][Widget.Win32]::GetWindowThreadProcessId($ust, [ref]$sahip)
    if ($sahip -eq $PID) { return }                    # zaten üstteyiz

    [void][Widget.Win32]::SetWindowPos($hwnd, $HWND_TOPMOST, 0, 0, 0, 0,
        ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOACTIVATE))
}

# İkinci kopyadan gelen "kendini göster" çağrısına cevap.
#
# Yapılan iki şey: ekran dışındaysa görünür bir yere al, ve birkaç saniye
# öne çıkar. Konumu KORUYORUZ — kullanıcı widget'ı bilerek bir yere koymuş
# olabilir; yalnızca gerçekten görünmez durumdaysa taşıyoruz.
function Invoke-Cagri {
    if (-not (Test-Path $CagriDosya)) { return }
    try { Remove-Item $CagriDosya -Force } catch { return }

    # ÖLÇÜT TÜM EKRAN, çalışma alanı DEĞİL. Şerit teması görev çubuğunun
    # üstünde, yani bilerek çalışma alanının DIŞINDA duruyor; WorkArea ile
    # ölçünce kullanıcının kendi yerleştirdiği şerit "ekran dışı" sayılıp
    # varsayılan konuma taşınıyordu — düzeltirken bozmak tam olarak bu.
    # ÖLÇÜT TÜM MONİTÖRLER, yalnızca birincil ekran DEĞİL.
    #
    # PrimaryScreen ile ölçünce ikinci monitöre yerleştirilmiş bir widget
    # "ekran dışı" sayılıp her çağrıda birincil ekrana geri taşınıyordu —
    # kullanıcının kendi yerleşimini bozan, düzeltirken bozmanın bir başka
    # örneği. Sanal masaüstü sol/üst koordinatları NEGATİF olabilir (monitör
    # ana ekranın soluna ya da üstüne konmuşsa), o yüzden sıfırdan değil
    # sınırlardan ölçüyoruz.
    #
    # WorkArea'ya DÖNMÜYORUZ: şerit teması görev çubuğunun üstünde, bilerek
    # çalışma alanının dışında duruyor (7325d5b).
    $vSol = [System.Windows.SystemParameters]::VirtualScreenLeft
    $vUst = [System.Windows.SystemParameters]::VirtualScreenTop
    $vSag = $vSol + [System.Windows.SystemParameters]::VirtualScreenWidth
    $vAlt = $vUst + [System.Windows.SystemParameters]::VirtualScreenHeight
    $tamamenDisarida = ($win.Left + $win.ActualWidth -lt $vSol + 20) -or
                       ($win.Left -gt $vSag - 20) -or
                       ($win.Top + $win.ActualHeight -lt $vUst + 20) -or
                       ($win.Top -gt $vAlt - 20)
    if ($tamamenDisarida) {
        Write-Kayit 'cagri: pencere ekran disindaydi, varsayilan konuma alindi'
        if ($script:Ayar.tema -eq 'serit') { Set-SeritVarsayilanKonumu } else { Set-VarsayilanKonum }
        $a = Get-KonumAnahtari
        $script:Ayar.($a[0]) = $script:KonumSol
        $script:Ayar.($a[1]) = $script:KonumUst
        Save-Ayarlar -Ayar $script:Ayar
    } else {
        Write-Kayit 'cagri: pencere one cikarildi'
    }

    # Göze çarpsın: birkaç saniye en üstte dursun, sonra temanın kendi
    # davranışına geri dönsün.
    # DİKKAT: yalnızca Topmost'u açmak YETMEZ. WM_WINDOWPOSCHANGING kancası
    # kart temasında her z-düzeni değişiminde pencereyi HWND_BOTTOM'a geri
    # itiyor ve Topmost'u anında eziyor. Vurgu süresince kancayı da kapatmak
    # gerekiyor — ilk denemede bu unutuldu ve vurgu sessizce hiç görünmedi.
    $script:VurguBitis = [DateTime]::Now.AddSeconds(4)
    [ZDuzeni]::Dipte = $false
    $win.Topmost = $true
    $Kok.Opacity = 1.0
}

# Vurgu süresi dolunca temanın normal z-düzeni davranışına dön.
function Update-Vurgu {
    if ($null -eq $script:VurguBitis) { return }
    if ([DateTime]::Now -lt $script:VurguBitis) { return }
    $script:VurguBitis = $null
    # Temanın kendi davranışına geri dön: kancayı ve Topmost'u birlikte.
    [ZDuzeni]::Dipte = $YERLESIMLER[$script:Ayar.tema].Dipte
    $win.Topmost = -not $YERLESIMLER[$script:Ayar.tema].Dipte
}

# Yoklayıcıyı tetikler. Jetonu okuyan ve ağa çıkan TEK yer o betiktir; widget
# yalnızca "şimdi çalış" der. Konsol penceresi açılmasın diye WScript.Shell ile
# gizli başlatılıyor (Start-Process kısa ömürlü konsol uygulamalarında
# göz kırpma üretiyor).
function Invoke-Yoklayici {
    $ayar = [int]$script:Ayar.canliYoklama
    if ($ayar -le 0) { return }

    # Yoklayıcının bıraktığı hata kaydı burada okunuyor: aralık kararı
    # veriden değil, YOKLAMANIN SONUCUNDAN çıkar.
    Read-YoklamaHatasi

    if ($script:YoklamaTaban -lt $ayar) { $script:YoklamaTaban = $ayar }
    if ($script:YoklamaAralik -lt $script:YoklamaTaban) { $script:YoklamaAralik = $script:YoklamaTaban }
    if (([DateTime]::Now - $script:SonYoklama).TotalSeconds -lt $script:YoklamaAralik) { return }

    if (-not (Test-Path $YoklayiciBetik)) {
        if (-not $script:YoklayiciUyarildi) {
            Write-Tani ('yoklayici betigi yok: ' + $YoklayiciBetik)
            $script:YoklayiciUyarildi = $true
        }
        return
    }
    $script:SonYoklama = [DateTime]::Now
    try {
        $kabuk = New-Object -ComObject WScript.Shell
        [void]$kabuk.Run(('node "{0}"' -f $YoklayiciBetik), 0, $false)   # 0 = gizli pencere
    } catch {
        Write-Tani ('yoklayici baslatilamadi: ' + $_.Exception.Message)
    }
}

# "Bu hızla ne kadar sürede biter?"
#
# Hızın kendisi (puan/dk) kaynaktan bağımsızdır, ama kalan süre GÖSTERİLEN
# yüzdeye bağlıdır. Kaynaklar farklı olabiliyor: hız masaüstü serisinden
# türerken ekrandaki yüzde API'den gelebiliyor. Bu durumda kaydedilmiş
# bitisDk yanlış referansa göre hesaplanmış olur — ekranda %44 yazarken
# tahmin %40 üzerinden yapılmış olurdu.
#
# Çözüm: bitisDk'yı okuma anında, ekrandaki yüzdeyle yeniden hesapla.
# yuzdeDk yoksa (eski dosya biçimi) kaydedilmiş değere düşülür.
function Get-BitisDakikasi {
    if ($null -eq $script:Veri -or -not (Test-Ozellik $script:Veri 'hiz')) { return $null }
    $h = $script:Veri.hiz

    $kayitli = if (Test-Ozellik $h 'bitisDk') { [int]$h.bitisDk } else { $null }
    if (-not (Test-Ozellik $h 'yuzdeDk')) { return $kayitli }

    $yuzdeDk = [double]$h.yuzdeDk
    if ($yuzdeDk -le 0.01) { return $kayitli }
    if (-not (Test-Ozellik $script:Veri 'five_hour')) { return $kayitli }
    if ($null -eq $script:Veri.five_hour.used_percentage) { return $kayitli }

    $kalan = 100.0 - [double]$script:Veri.five_hour.used_percentage
    if ($kalan -le 0) { return 0 }
    return [int][Math]::Round($kalan / $yuzdeDk)
}

# Kaynaklar aynı API'nin fotoğrafı; ÖLÇÜM ZAMANI daha yeni olan kazanır.
# Masaüstü kazanırsa yüzdeler oradan gelir; sıfırlanma saati yalnızca
# statusLine'ın gördüğü pencere hâlâ açıksa korunur — pencere dönmüşse
# uydurulmaz, boş bırakılır (geri sayım gösterilmez).
function Get-DurumOlcumu {
    param($Durum)
    if (Test-Ozellik $Durum 'olcumZamani') { return [int64]$Durum.olcumZamani }
    if (Test-Ozellik $Durum 'yazildi')     { return [int64]$Durum.yazildi }
    return 0
}

# Bir kaydın hesabı yetkili hesapla uyuşuyor mu?
#
# Damgası OLMAYAN kayıt reddedilmez: eski sürüm betiklerin yazdığı dosyalar
# böyle ve yükseltme sırasında ekranı boşaltmak, yanlış hesabı göstermekten
# daha kötü olurdu. Betikler bir sonraki yazımda damgayı zaten koyar.
# Yetkili hesap bilinmiyorsa (masaüstü dosyası yok) kıyaslanacak bir şey de
# yoktur — o zaman da kabul edilir.
function Test-Hesap {
    param($Kayit)
    if ($null -eq $script:YetkiliHesap) { return $true }
    if (-not (Test-Ozellik $Kayit 'hesap')) { return $true }
    if (-not (Test-Ozellik $Kayit.hesap 'org')) { return $true }
    if ([string]$Kayit.hesap.org -eq [string]$script:YetkiliHesap) { return $true }
    $script:RedEdilenHesap = $(if (Test-Ozellik $Kayit.hesap 'posta') { [string]$Kayit.hesap.posta } else { [string]$Kayit.hesap.org })
    return $false
}

function Merge-Kaynaklar {
    $d = $script:DurumHam
    $m = $script:Masaustu

    # statusLine ileri tarihliyse hiç güvenme: ne yarışa girsin ne de
    # sıfırlanma saatini ödünç versin.
    $dGecerli = ($null -ne $d) -and (Test-OlcumZamani (Get-DurumOlcumu $d))
    if ($null -ne $d -and -not $dGecerli) { Write-Tani 'durum.json: ileri tarihli olcum, yok sayildi' }

    # BAŞKA HESABIN VERİSİ HİÇ YARIŞA GİRMEZ. Claude Code masaüstü
    # uygulamasından farklı bir hesaba bağlıysa durum.json başka bir kotayı
    # anlatıyor demektir; onu birleştirmek iki hesabın yüzdelerini aynı barda
    # karıştırır.
    if ($dGecerli -and -not (Test-Hesap $d)) {
        Write-Tani 'durum.json: baska hesap, yok sayildi'
        $dGecerli = $false
    }

    if ($null -eq $m) { return $(if ($dGecerli) { $d } else { $null }) }

    if ($dGecerli -and (Get-DurumOlcumu $d) -ge $m.t) { return $d }   # statusLine daha taze

    $bes = [pscustomobject]@{ used_percentage = $m.fh; resets_at = $null; pencere_anahtari = $m.pencere5 }
    $haf = [pscustomobject]@{ used_percentage = $m.sd; resets_at = $null; pencere_anahtari = $m.pencereH }
    if ($dGecerli) {
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
    if ($dGecerli) { foreach ($oz in $d.PSObject.Properties) { $v[$oz.Name] = $oz.Value } }
    $v.five_hour = $bes
    $v.seven_day = $haf
    $v.olcumZamani = $m.t
    if ($null -eq $v.yazildi -or [int64]$v.yazildi -lt $m.t) { $v.yazildi = $m.t }
    $v.hiz = $m.hiz
    # GRAFİĞİ KAYNAĞA GÖRE SEÇME — GÜN BAZINDA BİRLEŞTİR.
    #
    # Önce "kayıt masaüstününse grafik de masaüstünün" deniyordu. Bu, donmuş
    # grafiği çözdü ama yenisini getirdi: iki kaynak tazelik yarışını sırayla
    # kazandıkça grafik iki farklı türetme arasında gidip geliyordu, ve
    # masaüstü serisi bir şey türetemediğinde durum.json'un gerçek verisi
    # sıfırlarla eziliyordu.
    #
    # Doğrusu: iki seri de AYNI tüketimin ALT SINIRI (biri terminal açıkken
    # 60 sn'de, diğeri masaüstü açıkken 15 dk'da örnekliyor; ikisi de arada
    # kalan sıfırlanmaları kaçırabiliyor). Gün anahtarına göre eşleyip
    # büyüğünü almak hem salınımı bitiriyor hem de her iki alt sınırdan daha
    # sıkı bir tahmin veriyor — ve sonuç, yarışı kimin kazandığından bağımsız.
    if ($null -ne $m.haftalik -and $m.haftalik.Count -eq 7) {
        $eskiGun = @{}
        if ($dGecerli -and (Test-Ozellik $d 'haftalik')) {
            foreach ($g in @($d.haftalik)) { if ($null -ne $g.gun) { $eskiGun[[string]$g.gun] = $g } }
        }
        $v.haftalik = @($m.haftalik | ForEach-Object {
            $e = $eskiGun[[string]$_.gun]
            if ($null -eq $e) { $_ }
            else {
                [pscustomobject]@{
                    gun     = $_.gun
                    tuketim = [Math]::Max([double]$_.tuketim, [double]$e.tuketim)
                    zirve   = [Math]::Max([double]$_.zirve,   [double]$e.zirve)
                }
            }
        })
    }
    $v.kaynak = 'masaustu'
    return [pscustomobject]$v
}

function Read-Durum {
    $script:RedEdilenHesap = $null   # her turda yeniden karar verilir
    Read-DurumDosyasi
    Read-Masaustu
    Read-Kota
    $script:Veri = Merge-Kaynaklar
    # Canlı yoklama açıksa API sonucu en taze kaynaktır; ölçüm zamanı ona göre.
    #
    # Hesap kapısı BURADA, Read-Kota'da değil: orası mtime ile korumalı, yani
    # dosya değişmediği turlarda hiç çalışmıyor. Kapı her turda işlemeli,
    # yoksa önbellekteki yanlış hesap sessizce geçer.
    if ($null -ne $script:Kota -and -not (Test-Hesap $script:Kota)) {
        Write-Tani 'kota.json: baska hesap, yok sayildi'
        Set-YoklamaHesapUyusmazligi
    } elseif ($null -ne $script:Kota) {
        Clear-YoklamaHesapKisiti      # hesap uyuşuyor: tavan gerekçesi kalktı
        $kOlcum = [int64]$script:Kota.olcumZamani
        $vOlcum = if (Test-Ozellik $script:Veri 'olcumZamani') { [int64]$script:Veri.olcumZamani } else { 0 }
        if ($kOlcum -gt $vOlcum) {
            $v = [ordered]@{}
            if ($null -ne $script:Veri) { foreach ($oz in $script:Veri.PSObject.Properties) { $v[$oz.Name] = $oz.Value } }
            $v.five_hour = $script:Kota.five_hour
            $v.seven_day = $script:Kota.seven_day
            $v.yazildi = $kOlcum
            $v.olcumZamani = $kOlcum
            $v.kaynak = 'api'
            $script:Veri = [pscustomobject]$v
        }
    }
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
        $script:Renk.Bayat
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

# Kapanan uyariyi listeden dusurur. Ayri bir fonksiyon olmasinin sebebi
# teknik: closure icinden $script: erisimi calismiyor (bkz. Show-Uyari).
function Remove-AcikUyari {
    param($Pencere)
    [void]$script:AcikUyarilar.Remove($Pencere)
}

$uyariXamlMetin = @'
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

# Yer tutucular BURADA da doldurulmalı. Ana pencere için 800. satırdaki döngü
# bunu yapıyor ama bu blok doğrudan [xml]'e cast ediliyordu: Tamam düğmesi
# ekranda harfi harfine "@@TAMAM@@" yazıyordu — iki dilde de.
foreach ($a in $METINLER[$DIL].Keys) { $uyariXamlMetin = $uyariXamlMetin.Replace("@@$a@@", $METINLER[$DIL][$a]) }
[xml]$uyariXaml = $uyariXamlMetin

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
    # DİKKAT — .GetNewClosure() İÇİNDE $script: KULLANMAYIN.
    #
    # Burada `{ [void]$script:AcikUyarilar.Remove($u) }.GetNewClosure()` vardı
    # ve uyarı KAPATILDIĞINDA "null üzerinde metot çağrılamaz" hatası veriyordu:
    # GetNewClosure yeni bir modül kapsamı açıyor, oradaki $script: bu betiğin
    # kapsamı DEĞİL — liste null görünüyor. Gövdeyi betik kapsamındaki bir
    # fonksiyona taşımak tek çözüm; closure yalnızca yerel $u'yu taşısın.
    #
    # Aynı tuzak eşik menüsünde de widget'ı çökertmişti (1.4.x). Üçüncü kez
    # düşmemek için kural: closure içinde yalnızca YEREL değişken.
    $u.Add_Closed({ Remove-AcikUyari $u }.GetNewClosure())

    [void]$script:AcikUyarilar.Add($u)
    $u.Show()
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    Write-Tani ("uyari gosterildi: {0} %{1} (esik {2})" -f $Etiket, $Yuzde, $Esik)
}

function Test-Esik {
    param($Pencere, [string]$Etiket, [string]$EsikAlan, [string]$AtesliAlan)

    $esik = [int]$script:Ayar.$EsikAlan
    if ($esik -le 0) { return }                                   # kapalı
    if (-not $script:VeriTaze) { return }                         # bayat veride ne uyar ne kurul
    if ($null -eq $Pencere -or $null -eq $Pencere.used_percentage) { return }

    $yuzde = [double]$Pencere.used_percentage
    $sifirlanma = ConvertFrom-UnixSaniye $Pencere.resets_at
    # Sıfırlanma anı geçmişse pencere dönmüştür; eski yüzde artık geçerli değil.
    if ($null -ne $sifirlanma -and $sifirlanma -le [DateTime]::Now) { $yuzde = 0 }

    # UYARI HAKKI: eşiğin ALTINA inildiğinde tazelenir, üstüne çıkıldığında
    # harcanır. Tek kural bu.
    #
    # Önce "pencere kimliği" (sıfırlanma saati) ile anahtarlanıyordu ve bu
    # yanlıştı: kimlik KAYNAĞA göre değişiyor — statusLine ve API gerçek
    # resets_at veriyor, masaüstü kaynağında o yok ve serideki son düşüşten
    # türetiliyor. Kaynak değiştiğinde anahtar da değişiyor ve kullanıcı aynı
    # pencere için yeniden uyarı alıyordu.
    #
    # Yüzdenin kendisi kaynaktan bağımsız. "Eşiğin altına indi" hem pencerenin
    # sıfırlanmasını hem de kullanıcının eşiği yukarı çekmesini doğal olarak
    # kapsıyor: iki durumda da yeni bir uyarı hak edilmiş demektir.
    if ($yuzde -lt $esik) {
        if ($null -ne $script:Ayar.$AtesliAlan) {
            $script:Ayar.$AtesliAlan = $null
            Save-Ayarlar -Ayar $script:Ayar
            Write-Tani ("esik hakki tazelendi {0}: %{1} < {2}" -f $Etiket, $yuzde, $esik)
        }
        return
    }

    if ($null -ne $script:Ayar.$AtesliAlan) { return }   # hak harcanmış, eşiğin altına inmedi

    Write-Tani ("esik asildi {0}: %{1} >= {2}" -f $Etiket, $yuzde, $esik)

    # Önce kaydet, sonra göster: pencere gösterimi hata verse bile uyarı
    # tekrar tekrar çıkmasın. Saklanan değer uyarının ZAMANI — yalnızca
    # "harcandı" bilgisi taşıyor, karşılaştırmada kullanılmıyor.
    $script:Ayar.$AtesliAlan = [int64][DateTimeOffset]::Now.ToUnixTimeSeconds()
    Save-Ayarlar -Ayar $script:Ayar
    Show-Uyari -Etiket $Etiket -Yuzde $yuzde -Sifirlanma $sifirlanma -Esik $esik
}

# ─────────────────────────────────────────────────────────────────────────────
# Tüketim hızı uyarısı
# ─────────────────────────────────────────────────────────────────────────────
function Update-Hiz {
    param($BitisDk)

    $metin = Get-HizUyarisi $BitisDk

    $HizUyari.Visibility = $(if ($null -eq $metin) { 'Collapsed' } else { 'Visible' })
    if ($null -ne $metin) { $HizUyari.Text = $metin }

    # Kart dışındaki yerleşimler bunu kendi dar alanlarında gösteriyor; metni
    # oraya taşımak için sakla.
    #
    # ARAÇ İPUCU DENENDİ, ÇALIŞMIYOR: pencere WS_EX_NOACTIVATE ile açıldığı
    # için hiçbir zaman etkin olmuyor ve WPF'in ToolTipService'i açılır
    # pencereyi göstermiyor. ToolTip ATANIYOR ama ekranda çıkmıyor — sessizce.
    # (Aynı kökten üçüncü sorun: sağ tık menüsünün kapanmaması ve odak kaybı
    # olaylarının hiç gelmemesi de buradan geliyordu.)
    $script:HizKisa = $(if ($null -eq $BitisDk -or $null -eq $metin) { $null }
                        else { (T 'HIZ_KISA') -f (Format-Sure ([int]$BitisDk)) })
    Write-Tani ("hiz: bitisDk={0} uyari={1}" -f $BitisDk, $(if ($null -eq $metin) { 'yok' } else { $metin }))
}

# Uyarı metni, yoksa $null. Tek koşul: pencere SIFIRLANMADAN ÖNCE bitecek
# olması; aksi hâlde "bu hızla biter" demek gereksiz korkutur.
function Get-HizUyarisi {
    param($BitisDk)

    if ($null -eq $BitisDk -or $null -eq $script:Veri) { return $null }
    if (-not (Test-Ozellik $script:Veri 'five_hour')) { return $null }

    $sifirlanma = ConvertFrom-UnixSaniye $script:Veri.five_hour.resets_at
    if ($null -eq $sifirlanma) { return $null }

    $kalanDk = ($sifirlanma - [DateTime]::Now).TotalMinutes
    if ($kalanDk -le 0 -or [int]$BitisDk -ge $kalanDk) { return $null }

    return ((T 'HIZ_UYARI') -f (Format-Sure ([int]$BitisDk)))
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
        $CUBUKLAR[$i].Background = ConvertTo-Fircasi (
            $(if ($buGunMu) { $script:Renk.Dusuk } else { $script:Renk.Sonuk }))
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
    if (-not (Test-Path $OlayDosya)) {
        $script:SonOlayMs = 0
        $script:OlayHam = $null
        $OlayKutu.Visibility = 'Collapsed'
        return
    }

    # DOSYAYI yalnızca değiştiğinde oku. Gerisi her turda çalışmaya devam
    # etmeli: yanıp sönme ve 15 dakikalık ömür saat bazlı, veri bazlı değil.
    # Diğer üç okuyucuda bu kapı vardı, burada yoktu — olay.json saatte ~3 kez
    # değişen bir dosyayken saniyede bir okunup ayrıştırılıyordu.
    try {
        $bilgi = Get-Item $OlayDosya
        if ($bilgi.LastWriteTime -ne $script:OlaySonYazma) {
            $script:OlayHam = Get-Content $OlayDosya -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:OlaySonYazma = $bilgi.LastWriteTime
        }
    } catch {
        # Yarım yazılmış dosya. Damga güncellenmediği için sonraki turda
        # yeniden denenir; o ana kadar elimizdeki son sağlam kayıt gösterilir.
    }

    $o = $script:OlayHam
    if ($null -eq $o) { return }

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
        # DİKKAT: Test-Ozellik şart, düz `$null -ne ...` DEĞİL.
        #
        # StrictMode altında var olmayan bir özelliğe erişmek istisnadır ve
        # kayıt yalnızca API'den geldiğinde `oturum` anahtarı HİÇ oluşmuyor
        # (Read-Durum, $script:Veri null iken $v'yi sıfırdan kuruyor). Bu,
        # Update-Olay'ın her tick'te patlaması, dolayısıyla Update-Gorunum'un
        # en başta kesilmesi ve kartın yeniden donması demekti — düzeltilen
        # şikâyetin aynısı, başka bir kapıdan. Hesap reddi bu yolu daha da
        # erişilebilir yaptığı için burada kapatılıyor.
        if ((Test-Ozellik $script:Veri 'oturum')) {
            $veriTaze = $false
            if ($null -ne $script:Veri.yazildi) {
                $vy = ConvertFrom-UnixSaniye ([int64]$script:Veri.yazildi / 1000)
                if ($null -ne $vy) { $veriTaze = ((([DateTime]::Now - $vy).TotalSeconds) -le $BAYAT_SN) }
            }

            $ayniProje = $false
            if ((Test-Ozellik $script:Veri.oturum 'dizin') -and $null -ne $o.dizin) {
                $ayniProje = ((Split-Path $script:Veri.oturum.dizin -Leaf) -eq $o.dizin)
            }

            if ($veriTaze -and $ayniProje) {
                $ek  = if (Test-Ozellik $script:Veri.oturum 'satirEkli')    { [int]$script:Veri.oturum.satirEkli }    else { 0 }
                $sil = if (Test-Ozellik $script:Veri.oturum 'satirSilinen') { [int]$script:Veri.oturum.satirSilinen } else { 0 }
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
        # Reddetme yüzünden elde hiç veri kalmadıysa asıl sebep "veri yok"
        # değil, "veri var ama başka hesabın". Kullanıcıya doğrusunu söyle:
        # aksi hâlde tek göreceği şey, kaynaklar dolu dururken "henüz veri
        # yok" yazısı olurdu.
        $Uyari.Text = $(if ($null -ne $script:RedEdilenHesap) {
            (T 'HESAP_UYUSMAZ') -f $script:RedEdilenHesap
        } else { (T 'VERI_YOK') })
        Update-Bar $null $Yuzde5 $Sifir5 $Dolgu5
        Update-Bar $null $YuzdeH $SifirH $DolguH
        Update-DigerYerlesim $null
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
        $bayatEsigi = switch (Get-Kaynak) {
            'masaustu' { $MASAUSTU_BAYAT_SN }
            # Eşik kullanıcının SEÇTİĞİ aralığa bakıyordu, yürürlükteki
            # aralığa değil. Geri çekilme 900 sn'ye çıktığında ölçümler arası
            # mesafe eşiği aşıyor ve kart, yoklayıcı düzgün çalışırken bile
            # "bayat" görünüyordu (barlar grileşiyor, eşik uyarısı susuyor).
            # Masaüstü eşiğiyle tavanlıyoruz: gerçekten terk edilmiş bir
            # yoklama yine bayata dönsün, 45 dakikalık sahte-taze pencere
            # doğmasın. ($script:YoklamaAralik ilk yoklamadan önce 0.)
            'api'      { [Math]::Min($MASAUSTU_BAYAT_SN,
                           [Math]::Max($API_BAYAT_SN,
                             [Math]::Max([int]$script:Ayar.canliYoklama, [int]$script:YoklamaAralik) * 3)) }
            default    { $BAYAT_SN }
        }
        # Alt sınır: ileri tarihli ölçüm "sonsuza kadar taze" sayılmasın.
        $script:VeriTaze = ($yasSn -le $bayatEsigi -and $yasSn -ge -$GELECEK_PAYI_SN)
        # Bayat veri: soluklaştır ve yaşını yaz — güncel sanıp bakmayalım.
        if ($yasSn -gt $bayatEsigi -or $yasSn -lt -$GELECEK_PAYI_SN) {
            $Kok.Opacity = 0.45
            $Yas.Text = Format-Yas $yazildi
            $Yas.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#E8A33D')
            $Yas.Opacity = 1.0
        } else {
            $Kok.Opacity = 1.0
            # Masaüstü kaynağı 15 dk'da bir örnekler; ona "canlı" demek yerine
            # gerçek yaşını yaz: "masaüstü · 7 dk önce". Terminal olay bazlı, o "canlı".
            $Yas.Text = switch (Get-Kaynak) {
                'masaustu' { '{0} · {1}' -f (T 'KAYNAK_MASAUSTU'), (Format-Yas $yazildi) }
                'api'      { '{0} · {1}' -f (T 'KAYNAK_API'), (Format-Yas $yazildi) }
                default    { (T 'CANLI') }
            }
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

    # Canlı yoklama açık ama yoklayıcı betik yoksa SÖYLE. Menüde seçilebilen
    # ama sessizce hiçbir şey yapmayan bir ayar, bozuk bir ayardan beterdir:
    # kullanıcı açar, sayı tazelenmez ve sebebini öğrenemez.
    if ([int]$script:Ayar.canliYoklama -gt 0 -and -not (Test-Path $YoklayiciBetik)) {
        $Uyari.Text = (T 'YOKLAMA_BETIK_YOK')
        $Uyari.Visibility = 'Visible'
    }

    # Kaynaklardan biri BAŞKA HESABA aitse SÖYLE. Sessizce yok saymak doğru
    # karar ama sebebini söylememek "widget bozuldu mu?" sorusunu doğurur —
    # yoklayıcı betiği eksik olduğunda da aynı gerekçeyle yazıyoruz.
    if ($null -ne $script:RedEdilenHesap) {
        $Uyari.Text = ((T 'HESAP_UYUSMAZ') -f $script:RedEdilenHesap)
        $Uyari.Visibility = 'Visible'
    }

    # İç hata en yüksek öncelikli: bir kez olduysa kapanana kadar görünür kalır.
    # Sessizce yutulan bir hata, çöken bir programdan daha kötüdür — kullanıcı
    # yanlış sayıya bakıp doğru sanabilir.
    if ($script:IcHata) {
        $Uyari.Text = (T 'IC_HATA')
        $Uyari.Visibility = 'Visible'
    }

    # Tüketim hızı yalnızca 5 saatlik pencere için hesaplanıyor.
    $bitisDk = Get-BitisDakikasi

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

    Update-DigerYerlesim $bitisDk
}

# Kart temasındaki bilgiyi tek satıra sıkıştırır. Renk/bayatlık kuralları
# kartla AYNI kaynaktan (Get-BarRengi + $script:VeriTaze) gelir; iki tema
# birbirinden farklı bir gerçeklik göstermesin.
function Update-DigerYerlesim {
    param($BitisDk)
    switch ($script:Ayar.tema) {
        'serit'    { Update-Serit    $BitisDk }
        'kompakt'  { Update-Kompakt  $BitisDk }
        'terminal' { Update-Terminal $BitisDk }
    }
}

# Yüzde + renk: üç yerleşim de aynı kurala uyuyor, tek yerden.
function Get-PencereGorunumu {
    param($Pencere, $BitisDk)
    if ($null -eq $Pencere -or $null -eq $Pencere.used_percentage) {
        return [pscustomobject]@{ Var = $false; Yuzde = 0.0; Renk = $script:Renk.Bayat; Sifirlanma = $null }
    }
    $sifirlanma = ConvertFrom-UnixSaniye $Pencere.resets_at
    $yuzde = [double]$Pencere.used_percentage
    if ($null -ne $sifirlanma -and $sifirlanma -le [DateTime]::Now) { $yuzde = 0 }
    $renk = if ($script:VeriTaze) {
        Get-BarRengi -Yuzde $yuzde -Sifirlanma $sifirlanma -BitisDk $BitisDk
    } else { $script:Renk.Bayat }
    return [pscustomobject]@{ Var = $true; Yuzde = $yuzde; Renk = $renk; Sifirlanma = $sifirlanma }
}

function Set-MiniBar {
    param($Gorunum, $YuzdeMetin, $Dolgu, [double]$Iz, [switch]$Ok)
    if (-not $Gorunum.Var) { $YuzdeMetin.Text = '—'; $Dolgu.Width = 0; return }
    $metin = '{0}%' -f [int][Math]::Round($Gorunum.Yuzde)
    if ($Ok -and $script:VeriTaze -and $script:KullanimSonrasi) { $metin += ' ▲' }
    $YuzdeMetin.Text = $metin
    # [Math]::Min KULLANMA: int aşırı yüklemesi oranı 1'e yuvarlıyor.
    $oran = $Gorunum.Yuzde / 100.0
    if ($oran -lt 0.0) { $oran = 0.0 }
    if ($oran -gt 1.0) { $oran = 1.0 }
    $Dolgu.Width = $oran * $Iz
    $Dolgu.Background = ConvertTo-Fircasi $Gorunum.Renk
}

function Update-Kompakt {
    param($BitisDk)
    $bes = Get-PencereGorunumu $(if ($null -ne $script:Veri) { $script:Veri.five_hour } else { $null }) $BitisDk
    $haf = Get-PencereGorunumu $(if ($null -ne $script:Veri) { $script:Veri.seven_day } else { $null }) $null
    Set-MiniBar $bes $Kompakt5 $Kompakt5Dolgu $KOMPAKT_IZ
    Set-MiniBar $haf $KompaktH $KompaktHDolgu $KOMPAKT_IZ
    # Kompakt'ta metin için yer yok; kırmızının sebebini tek işaret taşıyor.
    if ($script:VeriTaze -and $null -ne $script:HizKisa -and $bes.Var) { $Kompakt5.Text += ' ⚠' }
    $Kompakt5.Foreground = ConvertTo-Fircasi $(if ($bes.Var) { $bes.Renk } else { $script:Renk.Bayat })
    $KompaktH.Foreground = ConvertTo-Fircasi $(if ($haf.Var) { $haf.Renk } else { $script:Renk.Bayat })
}

# Karakterden bar: dolu kısım limit rengiyle, kalanı soluk. Tek TextBlock
# içinde iki Run — iki ayrı TextBlock yan yana koymak tek aralıklı yazıda
# hizayı bozuyordu.
function Set-TerminalSatiri {
    param($Metin, [string]$Etiket, $Gorunum)

    $Metin.Inlines.Clear()
    $bas = New-Object System.Windows.Documents.Run (('{0,-5}' -f $Etiket) + '[')
    $bas.Foreground = ConvertTo-Fircasi $script:Renk.Solgun
    [void]$Metin.Inlines.Add($bas)

    if ($Gorunum.Var) {
        $oran = $Gorunum.Yuzde / 100.0
        if ($oran -lt 0.0) { $oran = 0.0 }
        if ($oran -gt 1.0) { $oran = 1.0 }
        $dolu = [int][Math]::Round($oran * $TERMINAL_HANE)
    } else { $dolu = 0 }

    $r1 = New-Object System.Windows.Documents.Run ([string]([char]0x2588) * $dolu)
    $r1.Foreground = ConvertTo-Fircasi $Gorunum.Renk
    [void]$Metin.Inlines.Add($r1)

    # Boş kısım da TAM BLOK, yalnızca rengi soluk. Gölge blok (U+2591)
    # denendi: Consolas onu boşluk gibi çiziyor ve bar yarım görünüyordu.
    $r2 = New-Object System.Windows.Documents.Run ([string]([char]0x2588) * ($TERMINAL_HANE - $dolu))
    $r2.Foreground = ConvertTo-Fircasi $script:Renk.Sonuk
    [void]$Metin.Inlines.Add($r2)

    $kuyrukMetin = if ($Gorunum.Var) { ']{0,5}%' -f [int][Math]::Round($Gorunum.Yuzde) } else { ']    —' }
    $kuyruk = New-Object System.Windows.Documents.Run $kuyrukMetin
    $kuyruk.Foreground = ConvertTo-Fircasi $script:Renk.Metin
    [void]$Metin.Inlines.Add($kuyruk)
}

function Update-Terminal {
    param($BitisDk)
    $bes = Get-PencereGorunumu $(if ($null -ne $script:Veri) { $script:Veri.five_hour } else { $null }) $BitisDk
    $haf = Get-PencereGorunumu $(if ($null -ne $script:Veri) { $script:Veri.seven_day } else { $null }) $null
    Set-TerminalSatiri $Terminal5 (T 'SERIT_5SA')   $bes
    Set-TerminalSatiri $TerminalH (T 'SERIT_HAFTA') $haf

    $parca = @()
    if ($bes.Var -and $null -ne $bes.Sifirlanma) { $parca += Format-Kalan $bes.Sifirlanma }
    if ($script:VeriTaze) {
        if ($null -ne $script:HizKisa) { $parca += $script:HizKisa }
        if ($script:KullanimSonrasi)   { $parca += '+' }
    } else { $parca += $Yas.Text }
    $TerminalAlt.Text = ($parca -join '  ·  ')
    $TerminalAlt.Foreground = ConvertTo-Fircasi $(
        if ($script:VeriTaze -and $null -ne $script:HizKisa) { $script:Renk.Yuksek } else { $script:Renk.Solgun })
}

function Update-Serit {
    param($BitisDk)

    $gri  = $script:Renk.Bayat
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

    # Not yuvası, öncelik sırasıyla: veri bayatsa YAŞ (o zaman hız tahmini de
    # güvenilmez), taze ve hız uyarısı varsa UYARI, yoksa boş.
    if (-not $script:VeriTaze) {
        $SeritYas.Text = $Yas.Text
        $SeritYas.Foreground = ConvertTo-Fircasi $script:Renk.Orta
    } elseif ($null -ne $script:HizKisa) {
        $SeritYas.Text = $script:HizKisa
        $SeritYas.Foreground = ConvertTo-Fircasi $script:Renk.Yuksek
    } else {
        $SeritYas.Text = ''
    }
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
        $a = Get-KonumAnahtari
        $script:Ayar.($a[0]) = $script:KonumSol
        $script:Ayar.($a[1]) = $script:KonumUst
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

# Renk menüsü kodla üretiliyor: tablo tek kaynak, XAML'e beş satır elle
# yazmak yerine. Tıklama gövdesi script kapsamındaki Set-Renkler'i çağırır —
# GetNewClosure() kendi modül kapsamını açtığı için $script: değişkenlerine
# closure içinden yazmak eşik menüsünde çökmeye yol açmıştı.
function Set-RenkSecimi { param([string]$Ad) Set-Renkler $Ad }

$menuRenk = Get-Ogesi 'MnuRenk'
foreach ($anahtar in $RENKLER.Keys) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $RENKLER[$anahtar].Ad
    $mi.Tag = $anahtar
    $mi.IsCheckable = $true
    $mi.Add_Click({ param($s, $e) Set-RenkSecimi ([string]$s.Tag) })
    [void]$menuRenk.Items.Add($mi)
}

# Canlı yoklama menüsü. İlk kez açılırken AÇIK RIZA isteniyor: ne olduğunu,
# neyi değiştirdiğini ve jetonun dar yetkili olmadığını anlatan bir onay
# penceresi. Reddedilirse ayar değişmez.
function Set-YoklamaSecimi {
    param([int]$Sn)

    if ($Sn -gt 0 -and -not $script:Ayar.yoklamaOnaylandi) {
        $cevap = [System.Windows.MessageBox]::Show(
            ((T 'YOKLAMA_UYARI') -f $Sn), (T 'YOKLAMA_BASLIK'),
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($cevap -ne [System.Windows.MessageBoxResult]::Yes) {
            Write-Tani 'canli yoklama: kullanici reddetti'
            foreach ($o in (Get-Ogesi 'MnuYoklama').Items) { $o.IsChecked = ([int]$o.Tag -eq [int]$script:Ayar.canliYoklama) }
            return
        }
        $script:Ayar.yoklamaOnaylandi = $true
    }

    $script:Ayar.canliYoklama = $Sn
    $script:SonYoklama = [datetime]::MinValue    # açılır açılmaz ilk yoklama
    $script:YoklamaAralik = $Sn                  # geri çekilmeyi sıfırla
    $script:YoklamaTaban = $Sn                   # uyarlanabilir taban da sıfırlansın
    $script:ArdisikBasari = 0
    $script:YoklayiciUyarildi = $false
    $script:Kota = $null
    $script:KotaSonYazma = [datetime]::MinValue
    $script:KotaHataSonYazma = [datetime]::MinValue
    Save-Ayarlar -Ayar $script:Ayar
    foreach ($o in (Get-Ogesi 'MnuYoklama').Items) { $o.IsChecked = ([int]$o.Tag -eq $Sn) }
    Write-Tani ("canli yoklama: {0} sn" -f $Sn)
    Update-Gorunum
}

$menuYoklama = Get-Ogesi 'MnuYoklama'
foreach ($sn in $YOKLAMA_SECENEKLERI) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $(if ($sn -eq 0) { T 'YOKLAMA_KAPALI' } else { (T 'YOKLAMA_SN') -f $sn })
    $mi.Tag = $sn
    $mi.IsCheckable = $true
    $mi.IsChecked = ([int]$script:Ayar.canliYoklama -eq $sn)
    $mi.Add_Click({ param($s, $e) Set-YoklamaSecimi ([int]$s.Tag) })
    [void]$menuYoklama.Items.Add($mi)
}

Build-EsikMenusu -Kok (Get-Ogesi 'MnuEsik5') -EsikAlan 'esik5'
Build-EsikMenusu -Kok (Get-Ogesi 'MnuEsikH') -EsikAlan 'esikH'

(Get-Ogesi 'MnuSifirla').Add_Click({
    if ($script:Ayar.tema -eq 'serit') { Set-SeritVarsayilanKonumu } else { Set-VarsayilanKonum }
    $a = Get-KonumAnahtari
    $script:Ayar.($a[0]) = $script:KonumSol
    $script:Ayar.($a[1]) = $script:KonumUst
    Save-Ayarlar -Ayar $script:Ayar
})

# Açılışta başlatma anahtarı.
#
# Kısayolu KUR-BASLANGIC.PS1 DA oluşturuyor; burada yalnızca Başlangıç
# klasöründeki tek kısayol yönetiliyor (kurulum betiği ayrıca Başlat menüsü
# kısayolunu da koyar, o kalıcıdır — widget'ı kapattıktan sonra açmanın yolu o).
# Ayar dosyasında tutulmuyor: tek doğruluk kaynağı kısayolun kendisi, yoksa
# ayar ile gerçek birbirinden ayrı düşer.
function Test-Baslangic { return (Test-Path $BaslangicKisayolu) }

function Set-Baslangic {
    param([bool]$Acik)
    try {
        if ($Acik) {
            $betik = Join-Path $PSScriptRoot 'kullanim.ps1'
            $psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
            $dizin = Split-Path -Parent $BaslangicKisayolu
            if (-not (Test-Path $dizin)) { New-Item -ItemType Directory -Path $dizin -Force | Out-Null }

            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut($BaslangicKisayolu)
            # conhost.exe üzerinden: Windows Terminal varsayılanken
            # -WindowStyle Hidden boş bir terminal bırakıyor (bkz. Tuzaklar).
            $lnk.TargetPath       = "$env:WINDIR\System32\conhost.exe"
            $lnk.Arguments        = "$psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$betik`""
            $lnk.WorkingDirectory = $PSScriptRoot
            $lnk.Description      = 'Claude Kullanim - limit widgeti'
            $lnk.IconLocation     = $(if (Test-Path $IkonDosya) { $IkonDosya } else { "$env:WINDIR\System32\shell32.dll,222" })
            $lnk.WindowStyle      = 7
            $lnk.Save()
        } elseif (Test-Path $BaslangicKisayolu) {
            Remove-Item $BaslangicKisayolu -Force
        }
    } catch {
        Write-Tani ('baslangic ayari hatasi: ' + $_.Exception.Message)
    }
    # İşaret kutusu DİLEKTEN değil GERÇEKTEN okunuyor: yazma başarısızsa
    # (izin, kilitli klasör) menü yalan söylemesin.
    (Get-Ogesi 'MnuBaslangic').IsChecked = Test-Baslangic
}

(Get-Ogesi 'MnuBaslangic').Add_Click({ param($s, $e) Set-Baslangic ([bool]$s.IsChecked) })

(Get-Ogesi 'MnuKapat').Add_Click({ $win.Close() })
(Get-Ogesi 'MnuTemaKart').Add_Click({  Set-Tema 'kart' })
(Get-Ogesi 'MnuTemaSerit').Add_Click({ Set-Tema 'serit' })
(Get-Ogesi 'MnuTemaKompakt').Add_Click({ Set-Tema 'kompakt' })
(Get-Ogesi 'MnuTemaTerminal').Add_Click({ Set-Tema 'terminal' })

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
    try { Invoke-Cagri }      catch { Write-TickHatasi 'Invoke-Cagri'      $_.Exception.Message }
    try { Update-SeritUstte } catch { Write-TickHatasi 'Update-SeritUstte' $_.Exception.Message }
    try { Update-Vurgu }      catch { Write-TickHatasi 'Update-Vurgu'      $_.Exception.Message }
    try { Invoke-Yoklayici }  catch { Write-TickHatasi 'Invoke-Yoklayici'  $_.Exception.Message }
    try { Update-Gorunum }    catch { Write-TickHatasi 'Update-Gorunum'    $_.Exception.Message }
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
    # KAYITLI YERLEŞİMİN anahtarlarını kullan, kartınkileri değil.
    #
    # Burası her koşulda $Ayar.sol/.ust okuyordu — yani KART konumunu. Şerit
    # ya da kompakt kullanan biri pencereyi önce kartın koordinatında görüyor,
    # hemen ardından Set-Tema onu kendi yerine taşıyordu: görünür bir sıçrama.
    # Dosyadaki diğer bütün konum kullanımları zaten Get-KonumAnahtari'den
    # geçiyor; tek istisna burasıydı.
    $a = Get-KonumAnahtari
    if ($null -ne $script:Ayar.($a[0]) -and $null -ne $script:Ayar.($a[1])) {
        Set-PencereKonumu -Sol ([double]$script:Ayar.($a[0])) -Ust ([double]$script:Ayar.($a[1]))
    } elseif ($script:Ayar.tema -eq 'serit') {
        Set-SeritVarsayilanKonumu
    } else {
        Set-VarsayilanKonum
    }
})

# YAKALANMAMIŞ HATA = SESSİZ ÖLÜM.
#
# Zamanlayıcı tick'i try/catch içinde ama menü tıklamaları, fare olayları ve
# nöbetçi zamanlayıcı değil. Dispatcher iş parçacığında kaçan bir istisna WPF
# uygulamasını olduğu yerde sonlandırır — kullanıcı "kendi kendine kapandı"
# görür, ekranda hiçbir açıklama olmaz.
#
# Burada iki şey yapılıyor: olay kalıcı günlüğe yazılıyor ve istisna işlenmiş
# sayılıyor, yani widget ÖLMÜYOR. Hatayı gizlemek değil bu: günlükte duruyor
# ve kullanıcı ekranda bir uyarı görüyor. Bir limit göstergesinin çökmektense
# bozuk bir satırla ayakta kalması daha yararlı.
$win.Dispatcher.add_UnhandledException({
    param($k, $o)
    try {
        Write-Kayit ('YAKALANMAMIS HATA: ' + $o.Exception.GetType().Name + ' - ' + $o.Exception.Message)

        # .NET yığın izi burada işe yaramıyor: yalnızca PowerShell yorumlayıcı
        # çerçeveleri görünüyor, betiğin neresi olduğu görünmüyor. Asıl bilgi
        # ErrorRecord.InvocationInfo'da — satır numarası ve kaynak satırın
        # kendisi. Onsuz "null üzerinde metot çağrıldı" mesajı 2000 satırlık
        # bir dosyada hiçbir yere işaret etmiyor.
        $ir = $null
        if ($o.Exception -is [System.Management.Automation.IContainsErrorRecord]) {
            $ir = $o.Exception.ErrorRecord.InvocationInfo
        }
        if ($null -ne $ir) {
            Write-Kayit ('  satir {0}: {1}' -f $ir.ScriptLineNumber, $ir.Line.Trim())
        } else {
            Write-Kayit ('  yigin: ' + (($o.Exception.StackTrace -split "`n" | Select-Object -First 2 | ForEach-Object { $_.Trim() }) -join ' | '))
        }
        # Metni BURADA yazmak işe yaramaz: Update-Gorunum saniyede bir çalışıp
        # uyarı alanını sıfırlıyor. Bayrağı kaldır, gösterimi o üstlensin.
        $script:IcHata = $true
    } catch { }
    $o.Handled = $true      # widget ayakta kalsın
})

$win.Add_ContentRendered({
    # ZAMANLAYICILAR ÖNCE BAŞLAR.
    #
    # $veriTimer.Start() bu handler'ın SON satırıydı ve handler korumasızdı:
    # önündeki beş satırdan biri patlarsa dispatcher istisnayı yutuyor
    # ($o.Handled = $true), widget ayakta ve bir kez çizilmiş kalıyor ama bir
    # daha HİÇ yenilenmiyordu. Ekranda bu, tam olarak "program çalışıyor ama
    # güncellemiyor" gibi görünür ve günlükte tek satır iz bırakmaz.
    #
    # Yenileme, kurulumun geri kalanına bağımlı olmamalı. Öğeler zaten modül
    # düzeyindeki Update-Gorunum ile dolduruldu; bir saniye sonraki ilk tick
    # tema uygulanmadan çalışsa bile zararsızdır.
    $veriTimer.Start()
    $nabizTimer.Start()

    try {
        Set-MasaustuSeviyesi
        (Get-Ogesi 'MnuBaslangic').IsChecked = Test-Baslangic
        Set-Renkler $script:Ayar.renk -Kaydetme   # kayıtlı palet
        Set-Tema $script:Ayar.tema -Kaydetme      # kayıtlı yerleşim
    } catch {
        Write-Kayit ('ACILIS KURULUM HATASI: ' + $_.Exception.Message)
        $script:IcHata = $true
    }

    # Öz-test (KULLANIM_ESIKTEST=1): eşik menüsü öğesine GERÇEKTEN tıklar.
    # Bu yol daha önce sınanmamıştı ve closure kapsam hatası yüzünden widget'ı
    # çökertiyordu; regresyon buradan yakalanır.
    # Öz-test (KULLANIM_TEMATEST=1): tema menüsüne GERÇEKTEN tıklar. Eşik
    # menüsündeki closure kapsam hatası tam da "elle ayar dosyası yazarak
    # test ettim" diye gözden kaçmıştı; tema anahtarı aynı tuzağa düşmesin.
    # Öz-test (KULLANIM_BASLANGICTEST=1): açılışta başlat anahtarına GERÇEKTEN
    # tıklar — aç, kapat, tekrar aç. Kısayol yolu KULLANIM_BASLANGIC_YOL ile
    # yönlendirildiği için gerçek Başlangıç klasörüne dokunulmaz.
    # Öz-test (KULLANIM_HATATEST=1): dispatcher üzerinde KASTEN hata fırlatır.
    # Sınanan şey güvenlik ağı: widget ölmemeli, günlüğe yazılmalı, ekranda
    # uyarı çıkmalı. Bu ağ olmadan menü/fare olaylarındaki bir istisna
    # uygulamayı sessizce sonlandırıyordu — "kendi kendine kapandı".
    if ($env:KULLANIM_HATATEST -eq '1') {
        $win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background,
            [System.Action]{ throw 'OZTEST kasten firlatilan hata' }) | Out-Null
    }

    if ($env:KULLANIM_BASLANGICTEST -eq '1') {
        $oge = Get-Ogesi 'MnuBaslangic'
        foreach ($istenen in @($true, $false, $true)) {
            try {
                $oge.IsChecked = $istenen      # IsCheckable davranışını taklit et
                $oge.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent)))
                Write-Tani ("BASLANGICTEST istenen={0} dosyaVar={1} isaret={2}" -f `
                    $istenen, (Test-Baslangic), $oge.IsChecked)
            } catch {
                Write-Tani ("BASLANGICTEST HATA: " + $_.Exception.Message)
            }
        }
    }

    if ($env:KULLANIM_TEMATEST -eq '1') {
        $tikla = {
            param($Ad)
            (Get-Ogesi $Ad).RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent)))
        }
        foreach ($k in @('serit', 'kompakt', 'terminal', 'kart')) {
            try {
                & $tikla $YERLESIMLER[$k].Menu
                $win.UpdateLayout()
                Write-Tani ("TEMATEST {0}: ayar={1} kart={2} serit={3} kompakt={4} terminal={5} topmost={6} dipte={7}" -f `
                    $k, $script:Ayar.tema, $Kapsul.Visibility, $SeritKapsul.Visibility,
                    $KompaktKapsul.Visibility, $TerminalKapsul.Visibility, $win.Topmost, [ZDuzeni]::Dipte)
            } catch {
                Write-Tani ("TEMATEST {0} HATA: {1}" -f $k, $_.Exception.Message)
            }
        }

        # Renk menüsü kodla üretiliyor; öğeleri Tag'lerinden bulup tıklıyoruz.
        foreach ($ad in $RENKLER.Keys) {
            try {
                $oge = (Get-Ogesi 'MnuRenk').Items | Where-Object { [string]$_.Tag -eq $ad } | Select-Object -First 1
                if ($null -eq $oge) { Write-Tani ("RENKTEST {0}: MENU OGESI YOK" -f $ad); continue }
                $oge.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent)))
                Write-Tani ("RENKTEST {0}: ayar={1} dusuk={2} isaretli={3}" -f `
                    $ad, $script:Ayar.renk, $script:Renk.Dusuk, $oge.IsChecked)
            } catch {
                Write-Tani ("RENKTEST {0} HATA: {1}" -f $ad, $_.Exception.Message)
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

# KALP ATIŞI
#
# Günlükte "kapandi" satırı varsa pencere düzgün kapandı (menüden ya da
# koddan). Satır YOKSA süreç dışarıdan öldürülmüş ya da sert çökmüş demektir —
# ama ne zaman olduğunu bilemezdik. Yarım saatlik bir nabız, ölüm anını
# 30 dakikalık bir pencereye sıkıştırıyor ve "günlük burada bitiyor" ifadesini
# kanıta çeviriyor.
$nabizTimer = New-Object System.Windows.Threading.DispatcherTimer
# KULLANIM_NABIZ_DK yalnizca test icin: nabzi hizlandirip tick'in gercekten
# calistigini gorebilmek. Uretimde 30 dakika.
$nabizDk = if ($env:KULLANIM_NABIZ_DK) { [double]$env:KULLANIM_NABIZ_DK } else { 30.0 }
$nabizTimer.Interval = [TimeSpan]::FromMinutes($nabizDk)
$nabizTimer.Add_Tick({
    try {
        $dk = [int]([DateTime]::Now - $script:Baslangic).TotalMinutes
        Write-Kayit ("calisiyor ({0} dk)" -f $dk)
    } catch { }
})

$win.Add_Closed({
    $veriTimer.Stop()
    $nabizTimer.Stop()
    # Neden kapandığını kaydet: "açtım ama kapandı" şikâyetinde tek kanıt bu.
    # Süreç dışarıdan öldürülürse bu satır yazılmaz — o da bir bilgidir.
    Write-Kayit 'pencere kapandi (Close cagrildi)'
    try { $script:TekOrnek.ReleaseMutex() } catch { }
})

[void]$win.ShowDialog()
