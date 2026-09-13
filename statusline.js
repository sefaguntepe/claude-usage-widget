#!/usr/bin/env node
/*
 * ~/.claude/settings.json icindeki statusLine ayarini kurar veya kaldirir.
 *
 *   node statusline.js kur
 *   node statusline.js kaldir
 *   node statusline.js durum
 *
 * Her yazma oncesi settings.json yedeklenir. Diger ayarlara dokunulmaz.
 * (JSON duzenlemesi Node ile yapiliyor; PowerShell 5.1'in ConvertTo-Json'u
 *  Turkce karakterleri \uXXXX'e cevirip dosyayi gereksiz yere kirletiyor.)
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const AYAR = path.join(os.homedir(), '.claude', 'settings.json');
const BETIK = path.join(__dirname, 'durum-yaz.js');
const OLAY_BETIK = path.join(__dirname, 'olay-yaz.js');

/* statusLine varsayilan olarak OLAYA bagli calisir (yeni asistan mesaji,
   /compact, izin modu degisimi, limit penceresinin sifirlanmasi...). Tek bir
   uzun arac cagrisi veya alt ajan beklemesi sirasinda olay gelmedigi icin
   yuzdeler donar. refreshInterval bunu N SANIYEDE bir zamanlayiciyla tamamlar.

   30 saniye seciliyor: gecmis ornekleme 60 sn'de bir yaziyor; yenileme de
   60 sn olsaydi zamanlama kaymasi yuzunden ornekler atlanabilirdi. 30 sn,
   60 sn'lik ornegin sasmadan dusmesini garantiler. */
const YENILEME_SN = 30;

/* KENDI GIRDIMIZI ADIN HAM ALT DIZISIYLE TANIMAYIZ.

   Eskiden `command.includes('olay-yaz.js')` yetiyor sanildi. Iki yonden de
   yaniliyordu ve ikisi de sessiz:

   - YANLIS POZITIF -> VERI KAYBI. hookKur "bizim olmayani koru" diye
     suzuyor; adi yalnizca GECEN her komutu bizim sanmak, kullanicinin kendi
     hook'unu (ornegin adi argumanda anan bir kaydedici, ya da
     `olay-yaz.js-deneme` adli baska bir klasordeki baska bir proje) sessizce
     SILIYORDU. Kullanicinin ayar dosyasindan bir sey silmek, bizim girdimizi
     kuramamaktan cok daha kotu.
   - YANLIS NEGATIF -> KOPYA GIRDI. Windows yollari buyuk/kucuk harfe duyarsiz
     ve komut dizesi __dirname'in o anki yazimini koruyor; ayni dosya bir kez
     `...\olay-yaz.js`, bir kez `...\OLAY-YAZ.JS` olarak gorunebiliyor. O
     durumda kendi girdimizi tanimiyor, `kur` ikincisini ekliyor, `kaldir`
     eskisini geride birakiyordu.

   Bu yuzden ad YOL PARCASI olarak araniyor: onunde bolu, arkasinda tirnak /
   bosluk / satir sonu. Konumdan bagimsiz olmasi BILEREK: depo baska bir
   klasore tasinip `kur` yeniden calistirildiginda eski konumdaki girdinin
   temizlenmesi buna bagli. Mutlak yol eslestirseydik artik var olmayan bir
   betigi gosteren hook geride kalir ve her Stop'ta hata verirdi. */
const BETIK_DESENI = {
  olay: /[\\/]olay-yaz\.js(?=["'\s]|$)/i,
  durum: /[\\/]durum-yaz\.js(?=["'\s]|$)/i,
};

/* Stop ve Notification hook'lari: widget'a "bitti" / "bekliyor" bildirir.
   Stop'un matcher alani YOKTUR (her seferinde tetiklenir); Notification'da
   matcher destekleniyor ama turu betikte suzuyoruz - boylece ileride yeni
   bildirim turleri eklenirse ayar dosyasini degistirmek gerekmez. */
function hookTanimi() {
  return {
    Stop: [{ hooks: [{ type: 'command', command: `node "${OLAY_BETIK}" bitti` }] }],
    Notification: [{ hooks: [{ type: 'command', command: `node "${OLAY_BETIK}" bildirim` }] }],
  };
}

function bizimHookMu(giris) {
  return !!(giris && giris.hooks && Array.isArray(giris.hooks) && giris.hooks.some(
    (h) => h && typeof h.command === 'string' && BETIK_DESENI.olay.test(h.command)));
}

function bizimStatusLineMi(sl) {
  return !!(sl && typeof sl.command === 'string' && BETIK_DESENI.durum.test(sl.command));
}

function hookKur(d) {
  if (!d.hooks) d.hooks = {};
  const yeni = hookTanimi();
  for (const olay of Object.keys(yeni)) {
    const mevcut = Array.isArray(d.hooks[olay]) ? d.hooks[olay] : [];
    // Baskasinin hook'una dokunma: kendi girisimizi cikar, digerlerini koru.
    const digerleri = mevcut.filter((g) => !bizimHookMu(g));
    d.hooks[olay] = digerleri.concat(yeni[olay]);
  }
}

function hookKaldir(d) {
  if (!d.hooks) return;
  for (const olay of ['Stop', 'Notification']) {
    if (!Array.isArray(d.hooks[olay])) continue;
    d.hooks[olay] = d.hooks[olay].filter((g) => !bizimHookMu(g));
    if (d.hooks[olay].length === 0) delete d.hooks[olay];
  }
  if (Object.keys(d.hooks).length === 0) delete d.hooks;
}

/* Okuma da konusmali basarisiz olmali. Eskiden buradaki her hata cigil cigil
   bir Node yigin izi olarak ekrana dokuluyordu: dosya baska bir surec
   tarafindan kilitliyse EBUSY, dosya bozuksa SyntaxError. Ikisi de
   kullaniciya "bu arac bozuk" gibi gorunuyor, oysa sorun da cozumu de
   dosyanin kendisinde. Yazma yolundaki hata mesajlariyla ayni gerekce: ciplak
   yigin izi hem korkutucu hem yanlis yonlendirici.

   BOZUK JSON'DA YAZMAYA DEVAM EDILMEZ. Burada `{}` donup akisi surdurmek,
   ayar dosyasini bos bir nesneyle ezmek demekti -- kurtarmaya calistigimiz
   dosyayi yok etmenin en kisa yolu. */
function oku() {
  if (!fs.existsSync(AYAR)) return {};
  let ham;
  try {
    ham = fs.readFileSync(AYAR, 'utf8');
  } catch (e) {
    console.error(`settings.json okunamadi (${e.code || e.message})`);
    console.error('  ' + AYAR);
    console.error('Dosyayi acik tutan bir surec olabilir; Claude Code kapaliyken yeniden deneyin.');
    process.exit(1);
  }
  try {
    return JSON.parse(ham);
  } catch (e) {
    console.error('settings.json gecerli JSON degil, hicbir sey degistirilmedi:');
    console.error('  ' + AYAR);
    console.error('  ' + e.message);
    console.error('Ayni klasordeki settings.json.yedek-* dosyalarindan biriyle degistirebilirsiniz.');
    process.exit(1);
  }
}

/* Yazma arasinda kisa, SENKRON bekleme. setTimeout ise yaramaz: yeniden
   deneme dongusu tek bir senkron akisin icinde. */
function bekle(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function yaz(obj) {
  /* Yedek adi MILISANIYE tasiyor. Saniye cozunurlugu yetmiyordu: en dogal
     yeniden kurulum sirasi olan `kaldir` + hemen ardindan `kur` olculdugunde
     327 ms suruyor, yani iki yedek AYNI ada yaziliyor ve ikincisi birincinin
     ustune biniyordu. Geriye kalan yedek `kaldir`'in ZATEN degistirdigi hal;
     yedegin tek varlik sebebi olan "kuruluma dokunulmamis dosya" yok
     oluyordu. */
  const damga = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 23);
  const yedek = `${AYAR}.yedek-${damga}`;
  if (fs.existsSync(AYAR)) fs.copyFileSync(AYAR, yedek);

  /* settings.json'i YERINDE yazmak yanlisti. Bu dosya Claude Code'un KENDI
     ayar dosyasi ve bu betik elle calistirildiginda Claude Code ayakta
     olabiliyor. Duz writeFileSync dosyayi once sifirliyor (O_TRUNC), sonra
     dolduruyor. Gercek 11 KB'lik dosyayla olculdu: bos pencere medyan 256 us,
     p99 40 ms; es zamanli okuyan bir surec okumalarinin ~%25'inde dosyayi BOS
     gordu, 23 okumada gecersiz JSON aldi. Yazma tam orada kesilirse (Ctrl-C,
     kapanma, disk dolmasi) ayar dosyasi KALICI olarak bos kaliyor -- izinler,
     eklentiler, statusLine, hepsi birden.

     Cozum durum-yaz.js'teki jsonYaz ile ayni ve ayni gerekceye dayaniyor:
     surece ozel gecici dosya + rename. Ayni olcumde rename ile yapilan 17553
     okumanin hicbiri bos ya da bozuk degildi. Gecici dosya hedefle AYNI
     klasorde; rename'in tek birim icinde kalmasi atomikligin sarti.

     jsonYaz'dan TEK FARKI: burada hata YUTULMUYOR. Orada sessizce vazgecmek
     dogru, cunku statusLine saniyeler sonra yeniden deniyor. Burasi elle
     calistirilan tek seferlik bir komut; sessizce vazgecmek ekrana "kuruldu"
     yazip hicbir sey yazmamak olurdu.

     Windows'ta rename, hedefi acik tutan baska bir surec varken EPERM
     veriyor. Gecici bir durum oldugu icin artan araliklarla birkac kez
     deneniyor; yine de olmuyorsa komut HATA ile duruyor ve ayar dosyasina
     HIC dokunulmamis oluyor -- eski koddaki "yarim yazilmis dosya"
     sonucundan kesin olarak daha iyi. */
  const gecici = `${AYAR}.${process.pid}.tmp`;
  let sonHata = null;
  try {
    fs.writeFileSync(gecici, JSON.stringify(obj, null, 2) + '\n', 'utf8');
    for (let deneme = 0; deneme < 10; deneme++) {
      try {
        fs.renameSync(gecici, AYAR);
        return yedek;
      } catch (e) {
        sonHata = e;
        if (e.code !== 'EPERM' && e.code !== 'EBUSY' && e.code !== 'EACCES') break;
        bekle(20 * (deneme + 1));
      }
    }
  } catch (e) {
    sonHata = e;
  }

  /* Buraya dusuldugunde ayar dosyasina hic dokunulmamis oluyor; kullaniciya
     soylenmesi gereken asil sey bu. Ciplak yigin izi hem korkutucu hem de
     yanlis yonlendirici -- dosya bozulmus izlenimi veriyor. */
  try { fs.unlinkSync(gecici); } catch (e) { /* zaten yok */ }
  console.error(`settings.json yazilamadi (${(sonHata && sonHata.code) || sonHata})`);
  console.error('  ' + AYAR);
  console.error('Dosyayi acik tutan bir surec olabilir; Claude Code kapaliyken yeniden deneyin.');
  console.error(`AYAR DOSYASINA DOKUNULMADI, onceki hali yerinde duruyor.  Yedek: ${yedek}`);
  process.exit(1);
}

const komut = (process.argv[2] || 'durum').toLowerCase();
const d = oku();

if (komut === 'kur') {
  if (!fs.existsSync(BETIK)) {
    console.error(`durum-yaz.js bulunamadi: ${BETIK}`);
    process.exit(1);
  }
  if (d.statusLine && d.statusLine.command && !bizimStatusLineMi(d.statusLine)) {
    console.error('DIKKAT: Zaten baska bir statusLine tanimli:');
    console.error('  ' + d.statusLine.command);
    console.error('Uzerine yazmadim. Once mevcut olani kaldirin veya elle birlestirin.');
    process.exit(1);
  }
  d.statusLine = { type: 'command', command: `node "${BETIK}"`, refreshInterval: YENILEME_SN };
  hookKur(d);
  const yedek = yaz(d);
  console.log('statusLine + hook\'lar kuruldu.');
  console.log('  statusLine : ' + d.statusLine.command);
  console.log('  yenileme   : ' + YENILEME_SN + ' sn (olaylara ek zamanlayici)');
  console.log('  Stop       : ' + d.hooks.Stop.slice(-1)[0].hooks[0].command);
  console.log('  Notification: ' + d.hooks.Notification.slice(-1)[0].hooks[0].command);
  console.log('  yedek      : ' + yedek);
  console.log('Yeni Claude Code oturumunda etkinlesir.');
} else if (komut === 'kaldir') {
  if (d.statusLine && d.statusLine.command && !bizimStatusLineMi(d.statusLine)) {
    console.error('Tanimli statusLine bize ait degil, dokunmadim:');
    console.error('  ' + d.statusLine.command);
    process.exit(1);
  }
  if (d.statusLine) delete d.statusLine;
  hookKaldir(d);
  const yedek = yaz(d);
  console.log('statusLine ve hook\'lar kaldirildi.  yedek: ' + yedek);
} else {
  const hookSay = ['Stop', 'Notification'].filter(
    (o) => d.hooks && Array.isArray(d.hooks[o]) && d.hooks[o].some(bizimHookMu)).length;
  console.log('settings.json : ' + AYAR);
  console.log('statusLine    : ' + (d.statusLine ? JSON.stringify(d.statusLine) : '(tanimli degil)'));
  console.log('hook\'lar      : ' + hookSay + '/2 kurulu (Stop, Notification)');
  console.log('');
  console.log('Kullanim: node statusline.js kur | kaldir | durum');
}
