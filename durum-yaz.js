#!/usr/bin/env node
/*
 * Claude Code statusLine betigi.
 *
 *   1. Oturum verisini %APPDATA%\ClaudeKullanim\durum.json'a yazar
 *      (limitler, oturum istatistikleri, tuketim hizi, haftalik gecmis).
 *   2. Terminale tek satirlik durum yazar.
 *
 * Ne zaman calisir: her RENDER'da degil, OLAYA bagli — yeni asistan mesaji,
 * /compact, izin modu degisimi, limit penceresinin sifirlanmasi... Buna ek
 * olarak settings.json'daki refreshInterval (30 sn) zamanlayicisi calistirir;
 * tek bir uzun arac cagrisi sirasinda olay gelmedigi icin bu sart.
 *
 * Sik calisiyor; hizli ve sessiz olmak zorunda:
 *   - Ag erisimi ASLA satir icinde yapilmaz. Surum kontrolu 6 saatte bir
 *     ayri, kopuk (detached) bir surecte doner; burada yalnizca onbellek okunur.
 *   - Gecmis ornegi 60 saniyede bir yazilir, her cagrida degil.
 *   - Hata durumunda bos satir basip cikar.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const KLASOR = path.join(process.env.APPDATA || os.homedir(), 'ClaudeKullanim');
const DOSYA = path.join(KLASOR, 'durum.json');
const GECMIS = path.join(KLASOR, 'gecmis.json');
const SURUM = path.join(KLASOR, 'surum.json');

const ORNEK_ARALIK_MS = 60 * 1000;        // gecmis ornekleme sikligi
const SURUM_TAZELIK_MS = 6 * 60 * 60 * 1000;
const HIZ_PENCERE_DK = 45;                // tuketim hizi bu kadar geriye bakar
const EN_FAZLA_ORNEK = 300;
const EN_FAZLA_GUN = 30;
const ALARM_ESIGI = 90;

/* Dil: sistem yereline gore otomatik (yalnizca tr / en).
   Node'da Windows GORUNTU dilini okumanin dogrudan yolu yok; bolgesel yerel
   kullaniliyor. Ikisi farkliysa CLAUDE_KULLANIM_DIL=tr|en ile zorlanabilir. */
const DIL = (process.env.CLAUDE_KULLANIM_DIL ||
  (Intl.DateTimeFormat().resolvedOptions().locale || 'en')).toLowerCase().startsWith('tr') ? 'tr' : 'en';

const METIN = {
  tr: { BES: '5sa', HAFTA: 'hafta', CTX: 'ctx', THINK: 'think', FAST: 'fast',
        GUNCELLEME_HATA: 'guncelleme basarisiz', SURUM_VAR: 'v{0} var',
        DK: '{0} dk', SADK: '{0} sa {1} dk' },
  en: { BES: '5h', HAFTA: 'week', CTX: 'ctx', THINK: 'think', FAST: 'fast',
        GUNCELLEME_HATA: 'update failed', SURUM_VAR: 'v{0} available',
        DK: '{0} min', SADK: '{0} h {1} min' },
}[DIL];

function T(anahtar, ...arg) {
  return METIN[anahtar].replace(/\{(\d)\}/g, (_, i) => arg[i]);
}

// ANSI
const R = '\x1b[0m';
const KALIN = '\x1b[1m';
const SOLUK = '\x1b[90m';
const MAVI = '\x1b[36m';
const YESIL = '\x1b[32m';
const SARI = '\x1b[33m';
const KIRMIZI = '\x1b[31m';

// ─────────────────────────────────────────────────────────────────────────────
// Yardimcilar
// ─────────────────────────────────────────────────────────────────────────────
function jsonOku(p, varsayilan) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { return varsayilan; }
}

/* BU KAYIT HANGI HESABA AIT?

   Bir makinede birden fazla Claude hesabi olabilir: Claude Code bir hesaba,
   masaustu uygulamasi baskasina bagli olabilir. Widget uc kaynagi birlestirdigi
   icin, hesap damgasi olmadan iki hesabin yuzdeleri ayni barda karisiyor --
   uretimde tam olarak bu oldu: masaustu %81 derken API %4 diyordu ve bar
   ikisi arasinda gidip geliyordu.

   Kimlik olarak ORGANIZASYON kimligi kullaniliyor; masaustu uygulamasinin
   kendi gecmis dosyasinda ortak olarak bulunan tek alan o (`samples[].org`).
   E-posta yalnizca kullaniciya gosterilmek icin tasiniyor.

   ~/.claude.json buyuk olabilir (proje gecmisi de orada). Her render'da
   MB'lik bir JSON ayristirmamak icin ham metinde isaretlenen yerden kucuk bir
   dilim alinip orada aranir. */
function hesapOku() {
  let ham;
  try {
    ham = fs.readFileSync(path.join(os.homedir(), '.claude.json'), 'utf8');
  } catch (e) {
    return null;
  }
  const i = ham.indexOf('"oauthAccount"');
  if (i === -1) return null;
  const dilim = ham.slice(i, i + 2048);
  const org = /"organizationUuid"\s*:\s*"([^"]+)"/.exec(dilim);
  if (!org) return null;
  const posta = /"emailAddress"\s*:\s*"([^"]+)"/.exec(dilim);
  return { org: org[1], posta: posta ? posta[1] : null };
}

/* Atomik yazma. Iki nokta onemli:

   1) Gecici dosya adi SURECE OZEL. Sabit bir '.tmp' adini butun oturumlar
      paylasiyordu: A yazar, B ustune yazar, A B'nin baytlarini yerine tasir,
      B'nin rename'i ENOENT ile duser. PID ile ayirmak bunu bitiriyor.
   2) Basarisizlikta CANLI DOSYAYA YAZILMAZ. Eski surum duz writeFileSync'e
      dusuyordu; o da rename'in tam olarak onledigi yarim-okuma penceresini
      geri getiriyordu (widget saniyede bir okuyor). Yazamiyorsak yazmayiz --
      okuyucu bir onceki saglam surumu gormeye devam eder, bir sonraki tur
      zaten yeniden dener.

   Gecici dosya hedefle AYNI klasorde: rename'in ayni birim icinde kalmasi
   (Windows'ta MoveFileEx replace) atomikligin sarti. */
function jsonYaz(p, veri) {
  const tmp = `${p}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(KLASOR, { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(veri), 'utf8');
    fs.renameSync(tmp, p);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (e2) { /* zaten yok */ }
  }
}

function gunAnahtari(ms) {
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/* "2.1.228" vs "2.1.230" -> negatif/0/pozitif */
function surumKarsilastir(a, b) {
  const pa = String(a).split('.').map((x) => parseInt(x, 10) || 0);
  const pb = String(b).split('.').map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const fark = (pa[i] || 0) - (pb[i] || 0);
    if (fark !== 0) return fark;
  }
  return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Surum kontrolu (kopuk surecte calisir)
// ─────────────────────────────────────────────────────────────────────────────
function surumYenile() {
  const https = require('https');
  const istek = https.get('https://registry.npmjs.org/@anthropic-ai/claude-code/latest',
    { timeout: 8000 }, (r) => {
      let s = '';
      r.on('data', (c) => { s += c; });
      r.on('end', () => {
        try {
          const v = JSON.parse(s).version;
          if (v) jsonYaz(SURUM, { kontrol: Date.now(), sonSurum: v });
        } catch (e) { /* sessiz */ }
      });
    });
  istek.on('error', () => { });
  istek.on('timeout', () => istek.destroy());
}

function surumRozeti(kurulu) {
  const onbellek = jsonOku(SURUM, null);
  const simdi = Date.now();

  // Onbellek bayatsa arka planda yenile. Zaman damgasini ONCE yaziyoruz ki
  // pes pese render'lar onlarca surec dogurmasin.
  if (!onbellek || simdi - (onbellek.kontrol || 0) > SURUM_TAZELIK_MS) {
    try {
      jsonYaz(SURUM, { kontrol: simdi, sonSurum: (onbellek && onbellek.sonSurum) || null });
      const { spawn } = require('child_process');
      spawn(process.execPath, [__filename, '--surum-yenile'],
        { detached: true, stdio: 'ignore' }).unref();
    } catch (e) { /* sessiz */ }
  }

  // Otomatik guncelleme basarisiz olduysa bunu bilmek daha onemli.
  const sonuc = jsonOku(path.join(os.homedir(), '.claude', '.last-update-result.json'), null);
  if (sonuc && sonuc.outcome && sonuc.outcome !== 'success') {
    return `${KALIN}${KIRMIZI}${T('GUNCELLEME_HATA')}${R}`;
  }

  if (!kurulu) return null;

  // Onbellek yoksa/bayatsa karsilastirma GUVENILIR DEGIL. Boyle bir durumda
  // rozeti sessizce gizlemek "surumum guncel mi" sorusunu cevapsiz birakir
  // (onbellek eski bir surum derken kurulu daha yeni olabilir). Bu yuzden
  // kurulu surum soluk gosteriliyor: karsilastirma yok ama bilgi var.
  const bayat = !onbellek || !onbellek.sonSurum ||
    (simdi - (onbellek.kontrol || 0) > SURUM_TAZELIK_MS);

  if (!onbellek || !onbellek.sonSurum) return `${SOLUK}v${kurulu}${R}`;

  if (surumKarsilastir(kurulu, onbellek.sonSurum) < 0) {
    return `${SARI}${T('SURUM_VAR', onbellek.sonSurum)}${R}`;
  }

  if (bayat) return `${SOLUK}v${kurulu}${R}`;
  return null;   // onbellek taze ve surum guncel — sessiz kal
}

// ─────────────────────────────────────────────────────────────────────────────
// Gecmis: ornekleme, tuketim hizi, gunluk toplam
// ─────────────────────────────────────────────────────────────────────────────
function gecmisIsle(f5, d7) {
  const g = jsonOku(GECMIS, null) || { ornekler: [], gunler: {} };
  if (!Array.isArray(g.ornekler)) g.ornekler = [];
  if (!g.gunler || typeof g.gunler !== 'object') g.gunler = {};

  const simdi = Date.now();
  const son = g.ornekler[g.ornekler.length - 1];

  if (typeof f5 === 'number' && (!son || simdi - son.t >= ORNEK_ARALIK_MS)) {
    // Gunluk tuketim: 5 saatlik pencerenin ARTISLARINI topluyoruz. Pencere
    // sifirlandiginda (yeni deger eskisinden kucuk) yeni degerin kendisi
    // sifirlamadan beri tuketilen kismidir.
    if (son) {
      const fark = f5 - son.f5;
      const eklenecek = fark >= 0 ? fark : f5;
      if (eklenecek > 0) {
        const anahtar = gunAnahtari(simdi);
        const gun = g.gunler[anahtar] || { tuketim: 0, zirve: 0 };
        gun.tuketim = Math.round((gun.tuketim + eklenecek) * 10) / 10;
        if (typeof d7 === 'number' && d7 > gun.zirve) gun.zirve = Math.round(d7);
        g.gunler[anahtar] = gun;
      }
    }

    g.ornekler.push({ t: simdi, f5: Math.round(f5 * 10) / 10, d7: typeof d7 === 'number' ? Math.round(d7 * 10) / 10 : null });
    if (g.ornekler.length > EN_FAZLA_ORNEK) g.ornekler = g.ornekler.slice(-EN_FAZLA_ORNEK);

    const gunler = Object.keys(g.gunler).sort();
    if (gunler.length > EN_FAZLA_GUN) {
      for (const eski of gunler.slice(0, gunler.length - EN_FAZLA_GUN)) delete g.gunler[eski];
    }

    jsonYaz(GECMIS, g);
  }

  return g;
}

/* Tuketim hizi: son HIZ_PENCERE_DK dakikadaki artistan yuzde/dakika bulur ve
   kalan yuzdenin ne kadar sürede biteceğini tahmin eder. Pencere sifirlanmasi
   (dusen deger) araya girerse hiz hesaplanmaz - yaniltici olur. */
function hizHesapla(g, f5) {
  if (typeof f5 !== 'number' || !g || !Array.isArray(g.ornekler)) return null;

  const simdi = Date.now();
  const pencere = g.ornekler.filter((o) => simdi - o.t <= HIZ_PENCERE_DK * 60 * 1000);
  if (pencere.length < 2) return null;

  for (let i = 1; i < pencere.length; i++) {
    if (pencere[i].f5 < pencere[i - 1].f5) return null;   // arada sifirlanma var
  }

  const ilk = pencere[0];
  const dakika = (simdi - ilk.t) / 60000;
  if (dakika < 5) return null;

  const yuzdeDk = (f5 - ilk.f5) / dakika;
  if (yuzdeDk <= 0.01) return null;

  return { yuzdeDk: Math.round(yuzdeDk * 1000) / 1000, bitisDk: Math.round((100 - f5) / yuzdeDk) };
}

/* rate_limits CANLI BIR SORGU DEGIL: o oturumun son API yanitindan kalma bir
   fotograftir. Claude Code onu onbellekte tutar ve refreshInterval her
   tetiklendiginde AYNI fotografi yeniden gonderir. Iki sonucu var:
     a) Boste bekleyen bir oturum dosyayi tazeler ama degerleri tazelemez —
        widget "canli" derken sayilar donmus olabilir.
     b) Ayni dosyaya birden fazla oturum yazar; boste olan, aktif olanin taze
        degerini kendi eski fotografiyla ezer.

   Ikisini de tek kural cozer: AYNI PENCEREDE YUZDE DUSEMEZ (kota geri gelmez).
   Dusen bir deger eski bir fotograftir ve reddedilir. Yalnizca ileri giden ya
   da yeni pencereden gelen veri kabul edilir; kabul edilince "olcum zamani"
   simdi olarak isaretlenir. */
function pencereBirlestir(eskiP, yeniP) {
  if (!yeniP || typeof yeniP.used_percentage !== 'number') {
    return { p: eskiP || null, degisti: false };
  }
  if (!eskiP || typeof eskiP.used_percentage !== 'number') {
    return { p: yeniP, degisti: true };
  }

  const eskiR = eskiP.resets_at || 0;
  const yeniR = yeniP.resets_at || 0;

  if (yeniR > eskiR) return { p: yeniP, degisti: true };    // yeni pencere
  if (yeniR < eskiR) return { p: eskiP, degisti: false };   // onceki pencerenin fotografi
  if (yeniP.used_percentage > eskiP.used_percentage) return { p: yeniP, degisti: true };
  return { p: eskiP, degisti: false };                      // esit veya dusuk -> eski fotograf
}

function haftalikOzet(g) {
  const liste = [];
  for (let i = 6; i >= 0; i--) {
    const anahtar = gunAnahtari(Date.now() - i * 86400000);
    const gun = (g && g.gunler && g.gunler[anahtar]) || null;
    liste.push({ gun: anahtar, tuketim: gun ? gun.tuketim : 0, zirve: gun ? gun.zirve : 0 });
  }
  return liste;
}

function sureMetni(dk) {
  if (dk < 60) return T('DK', dk);
  return T('SADK', Math.floor(dk / 60), dk % 60);
}

// ─────────────────────────────────────────────────────────────────────────────
// Terminal satiri
// ─────────────────────────────────────────────────────────────────────────────
function limitRengi(y) {
  if (y >= ALARM_ESIGI) return KALIN + KIRMIZI;
  if (y >= 75) return SARI;
  return YESIL;
}

function gorunurUzunluk(s) {
  return s.replace(/\x1b\]8;;[^\x07]*\x07/g, '').replace(/\x1b\[[0-9;]*m/g, '').length;
}

function baglanti(url, metin) {
  if (!url) return metin;
  return `\x1b]8;;${url}\x07${metin}\x1b]8;;\x07`;
}

// ─────────────────────────────────────────────────────────────────────────────
function main() {
  let d;
  try {
    d = JSON.parse(fs.readFileSync(0, 'utf8'));
  } catch (e) {
    process.stdout.write('');
    return;
  }

  const rl = d.rate_limits;

  // Gelen fotografi dosyadakiyle BIRLESTIR; eskiyse reddedilir. Gecmis
  // ornekleme ve hiz hesabi da birlesmis (geriye gitmeyen) degerlerle yapilir,
  // yoksa boste bir oturumun dusuk fotografi gunluk toplami bozardi.
  let f5 = null, d7 = null;

  if (rl && (rl.five_hour || rl.seven_day)) {
    const eski = jsonOku(DOSYA, null);
    const simdi = Date.now();

    const b5 = pencereBirlestir(eski && eski.five_hour, rl.five_hour);
    const b7 = pencereBirlestir(eski && eski.seven_day, rl.seven_day);
    const degisti = b5.degisti || b7.degisti;

    // Olcum zamani: degerlerin en son GERCEKTEN degistigi an — dosyanin
    // yazildigi an degil. Widget tazeligi buna gore hesaplar.
    const olcumZamani = degisti ? simdi
      : ((eski && eski.olcumZamani) || (eski && eski.yazildi) || simdi);

    f5 = b5.p && typeof b5.p.used_percentage === 'number' ? b5.p.used_percentage : null;
    d7 = b7.p && typeof b7.p.used_percentage === 'number' ? b7.p.used_percentage : null;

    let hiz = null;
    let haftalik = [];
    if (f5 !== null) {
      const g = gecmisIsle(f5, d7);
      hiz = hizHesapla(g, f5);
      haftalik = haftalikOzet(g);
    }

    const c = d.cost || {};
    jsonYaz(DOSYA, {
      yazildi: simdi,
      olcumZamani: olcumZamani,
      hesap: hesapOku(),
      five_hour: b5.p,
      seven_day: b7.p,
      hiz: hiz,
      haftalik: haftalik,
      oturum: {
        ad: d.session_name || null,
        dizin: (d.workspace && d.workspace.current_dir) || d.cwd || null,
        satirEkli: c.total_lines_added || 0,
        satirSilinen: c.total_lines_removed || 0,
        sureMs: c.total_duration_ms || 0,
      },
    });
  }

  // ── satir parcalari (oncelik: kucuk sayi once atilir) ────────────────
  const parcalar = [];
  const ekle = (metin, oncelik) => parcalar.push({ metin, oncelik });

  const model = (d.model && d.model.display_name) || '?';
  let modelBlok = `${MAVI}${model}${R}`;
  if (d.effort && d.effort.level) modelBlok += `${SOLUK}·${d.effort.level}${R}`;
  if (d.fast_mode) modelBlok += ` ${SARI}${T('FAST')}${R}`;
  if (d.thinking && d.thinking.enabled) modelBlok += ` ${SOLUK}${T('THINK')}${R}`;
  ekle(modelBlok, 9);

  // aktif ajan (yalnizca --agent ile calisirken gelir)
  if (d.agent && d.agent.name) ekle(`${MAVI}@${d.agent.name}${R}`, 7);

  // output style (varsayilan disindaysa gostermeye deger)
  if (d.output_style && d.output_style.name && d.output_style.name !== 'default') {
    ekle(`${SOLUK}${d.output_style.name}${R}`, 5);
  }

  // surum uyarisi
  const rozet = surumRozeti(d.version);
  if (rozet) ekle(rozet, 8);

  const dizin = (d.workspace && d.workspace.current_dir) || d.cwd || '';
  if (dizin) ekle(path.basename(dizin), 4);

  if (d.pr && d.pr.number) ekle(`${MAVI}${baglanti(d.pr.url, '#' + d.pr.number)}${R}`, 3);
  if (d.session_name) ekle(`${SOLUK}${d.session_name}${R}`, 2);

  const cw = d.context_window;
  if (cw && typeof cw.used_percentage === 'number') {
    ekle(`${SOLUK}${T('CTX')}${R} ${Math.round(cw.used_percentage)}%`, 6);
  }

  let alarm = false;
  if (rl) {
    for (const [anahtar, etiket] of [['five_hour', T('BES')], ['seven_day', T('HAFTA')]]) {
      const p = rl[anahtar];
      if (!p || typeof p.used_percentage !== 'number') continue;
      const y = Math.round(p.used_percentage);
      if (y >= ALARM_ESIGI) alarm = true;
      ekle(`${SOLUK}${etiket}${R} ${limitRengi(y)}${y}%${R}`, 10);
    }
  }

  // Tuketim hizi: yalnizca limit sifirlanmadan ONCE bitecekse uyari anlamli.
  if (hiz && rl && rl.five_hour && rl.five_hour.resets_at) {
    const kalanDk = Math.round((rl.five_hour.resets_at * 1000 - Date.now()) / 60000);
    if (hiz.bitisDk < kalanDk) {
      ekle(`${KALIN}${KIRMIZI}~${sureMetni(hiz.bitisDk)}${R}`, 10);
    }
  }

  if (alarm) parcalar.unshift({ metin: `${KALIN}${KIRMIZI}!${R}`, oncelik: 11 });

  // Goruntu sirasi eklendigi gibi kalir; oncelik yalnizca dar terminalde
  // NEYIN atilacagini belirler.
  const enBoy = parseInt(process.env.COLUMNS, 10) || 0;
  const ayrac = `${SOLUK} · ${R}`;
  const birlestir = (liste) => liste.map((p) => p.metin).join(ayrac);
  const secili = parcalar.slice();

  if (enBoy > 10) {
    while (secili.length > 1 && gorunurUzunluk(birlestir(secili)) > enBoy - 2) {
      let dusuk = 0;
      for (let i = 1; i < secili.length; i++) {
        if (secili[i].oncelik < secili[dusuk].oncelik) dusuk = i;
      }
      secili.splice(dusuk, 1);
    }
  }

  process.stdout.write(birlestir(secili));
}

// Kopuk surum-yenileme modu: stdin okumaz, satir basmaz.
if (process.argv[2] === '--surum-yenile') {
  try { surumYenile(); } catch (e) { /* sessiz */ }
} else {
  try { main(); } catch (e) { process.stdout.write(''); }
}
