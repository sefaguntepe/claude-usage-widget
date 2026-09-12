#!/usr/bin/env node
/*
 * OPSIYONEL — VARSAYILAN OLARAK KAPALI. Bu betik, widget'in "canli yoklama"
 * secenegi acilmadikca HIC CALISTIRILMAZ.
 *
 * ============================================================================
 *  ACMADAN ONCE OKUYUN
 * ============================================================================
 * Bu betik Claude Code'un OAuth ERISIM JETONUNU okur ve resmi kullanim ucuna
 * (api.anthropic.com/api/oauth/usage) salt-okur bir istek atar. O jeton DAR
 * YETKILI DEGILDIR: kapsamlari arasinda `user:inference` vardir, yani jetonu
 * ele geciren sizin adiniza cikarim calistirabilir ve kotanizi harcayabilir.
 * Istenebilecek "yalnizca kullanimi oku" diye bir kapsam yoktur.
 *
 * Widget'in VARSAYILAN calisma bicimi bu DEGILDIR. Varsayilanda widget yalnizca
 * Claude'un zaten diske yazdigi iki dosyayi okur, hicbir kimlik bilgisine
 * dokunmaz, aga cikmaz. Bu betik o kurali kullanicinin acik tercihiyle gevsetir;
 * kazanc, masaustu oturumlarinda ~15 dakikalik gecikmenin ~60 saniyeye inmesidir.
 *
 * Kurumsal / is bilgisayarinda ONERILMEZ: kimlik bilgisi tutup duzenli
 * araliklarla dis API'ye cikan arka plan sureci, uc nokta koruma
 * yazilimlarinin isaretledigi bir desendir.
 *
 * ---------------------------------------------------------------------------
 *  TASARIM KARARLARI — hepsi riski kucultmek icin
 * ---------------------------------------------------------------------------
 * 1. WIDGET JETONU HIC GORMEZ. Yokla-yaz isi bu ayri surecte olur; widget
 *    sonucu kota.json'dan okur, tipki diger iki kaynak gibi. Sir tasiyan kod
 *    yuzeyi tek dosyaya hapsedilmistir.
 *
 * 2. YENILEME JETONU HIC OKUNMAZ. Yalnizca kisa omurlu erisim jetonu (~24 dk)
 *    kullanilir; suresi dolmussa istek atilmaz, sessizce cikilir. Boylece bu
 *    betik bir kimlik YENILEME ajanina donusmez -- eldeki en buyuk risk
 *    azaltmasi budur. Claude Code (terminal ya da masaustu) kullanildikca
 *    jetonu zaten tazeler; biz yalnizca o tazeligin uzerine bineriz. Bedeli:
 *    Claude hic kullanilmayan saatlerde yoklama durur. O saatlerde kota da
 *    degismedigi icin kaybedilen sey neredeyse degersizdir.
 *
 * 3. JETON ASLA GUNLUGE, HATA MESAJINA VEYA CIKTIYA YAZILMAZ. Tek bir
 *    fonksiyondan okunur, tek bir yerde kullanilir, hicbir yere donmez.
 *    Hata yollarinda YALNIZCA HTTP durum kodu tutulur -- govde ve basliklar
 *    asla kaydedilmez, cunku bir yanit govdesi jetonu yankilayabilir ve
 *    kota.json'u widget okuyor.
 *
 * 4. YALNIZCA api.anthropic.com. claude.ai cerez yolu bilerek kullanilmaz:
 *    o yol tam bir web oturumu cerezi ister ve Cloudflare TLS parmak izi
 *    (JA3) kontrolune takilir; onu asmak bot tespitini atlatmak demektir.
 *
 * 5. YAZMA ATOMIKTIR, surece ozel gecici ad kullanir, basarisizlikta canli
 *    dosyaya dokunmaz (durum-yaz.js'teki jsonYaz ile ayni gerekce).
 *
 * Cikti  : %APPDATA%\ClaudeKullanim\kota.json   (widget ucuncu kaynak sayar)
 * Kullanim: node kota-yokla.js                  (bir kez yoklar, yazar, cikar)
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const KLASOR = path.join(process.env.APPDATA || os.homedir(), 'ClaudeKullanim');
const DOSYA = path.join(KLASOR, 'kota.json');
const KIMLIK = path.join(os.homedir(), '.claude', '.credentials.json');

const UC = 'https://api.anthropic.com/api/oauth/usage';
const ZAMAN_ASIMI_MS = 15000;

/* Jetonu okuyan TEK yer.

   Suresi dolmus jeton kullanilmaz: yenileme jetonuna hic dokunmadigimiz icin
   (tasarim karari 2) dolmus jetonla istek atmanin tek sonucu 401 olurdu.
   Sessizce cikmak dogrusu -- widget zaten dosya kaynaklarini gosteriyor. */
function jetonOku() {
  const ortam = process.env.CLAUDE_CODE_OAUTH_TOKEN;
  if (ortam && ortam.trim()) return { jeton: ortam.trim() };

  let ham;
  try {
    ham = JSON.parse(fs.readFileSync(KIMLIK, 'utf8'));
  } catch (e) {
    return { hata: 'kimlik-yok' };
  }

  const o = ham && ham.claudeAiOauth;
  if (!o || typeof o.accessToken !== 'string' || !o.accessToken) {
    return { hata: 'jeton-yok' };
  }
  if (typeof o.expiresAt === 'number' && o.expiresAt <= Date.now()) {
    return { hata: 'jeton-suresi-dolmus' };
  }
  return { jeton: o.accessToken };
}

/* Atomik yazma: gecici ad surece ozel (sabit '.tmp' adini butun yazicilar
   paylasiyordu), basarisizlikta canli dosyaya YAZILMAZ -- widget saniyede bir
   okuyor, yarim dosya gostermektense bir tur beklemek dogru. */
function jsonYaz(veri) {
  const tmp = `${DOSYA}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(KLASOR, { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(veri), 'utf8');
    fs.renameSync(tmp, DOSYA);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (e2) { /* zaten yok */ }
  }
}

/* YALNIZCA durum kodu. Govde ve basliklar kaydedilmez (tasarim karari 3). */
function durumYaz(hata, kod) {
  jsonYaz({ yazildi: Date.now(), hata: hata, http: kod === undefined ? null : kod });
}

/* Yanittaki bir pencereyi widget'in bekledigi bicime cevirir. Uc, yuzdeyi
   `utilization` adiyla veriyor; resets_at sayi ya da ISO metin olabiliyor. */
function pencere(p) {
  if (!p || typeof p !== 'object') return null;

  const y = typeof p.utilization === 'number' ? p.utilization
          : typeof p.used_percentage === 'number' ? p.used_percentage : null;
  if (y === null || !isFinite(y)) return null;

  let sifir = null;
  if (typeof p.resets_at === 'number' && isFinite(p.resets_at)) {
    sifir = Math.round(p.resets_at);
  } else if (typeof p.resets_at === 'string') {
    const t = Date.parse(p.resets_at);
    if (!isNaN(t)) sifir = Math.round(t / 1000);
  }
  return { used_percentage: y, resets_at: sifir };
}

async function main() {
  const k = jetonOku();
  if (k.hata) { durumYaz(k.hata); return; }

  const iptal = new AbortController();
  const sayac = setTimeout(() => iptal.abort(), ZAMAN_ASIMI_MS);

  let yanit;
  try {
    yanit = await fetch(UC, {
      method: 'GET',
      signal: iptal.signal,
      headers: {
        // Jeton YALNIZCA burada kullanilir, hicbir yere kopyalanmaz.
        'Authorization': `Bearer ${k.jeton}`,
        'anthropic-beta': 'oauth-2025-04-20',
        'Accept': 'application/json',
      },
    });
  } catch (e) {
    // Hata nesnesi kaydedilmiyor; yalnizca siniflandiriliyor.
    durumYaz(e && e.name === 'AbortError' ? 'zaman-asimi' : 'ag-hatasi');
    return;
  } finally {
    clearTimeout(sayac);
  }

  if (!yanit.ok) {
    /* 429'da sunucunun soyledigi sureye UYULUR. Ucun ucuncu-parti yoklamayi
       sinirladigi olculdu; geri cekilmeden 60 sn'de bir vurmak hem ise
       yaramiyor hem de kaba. Retry-After saniye ya da HTTP-tarih olabilir. */
    let bekle = null;
    if (yanit.status === 429) {
      const ham = yanit.headers.get('retry-after');
      if (ham) {
        const sn = Number(ham);
        if (Number.isFinite(sn) && sn > 0) bekle = Math.round(sn);
        else {
          const t = Date.parse(ham);
          if (!isNaN(t)) bekle = Math.max(0, Math.round((t - Date.now()) / 1000));
        }
      }
    }
    jsonYaz({ yazildi: Date.now(), hata: 'http', http: yanit.status, tekrarSn: bekle });
    return;
  }

  let d;
  try { d = await yanit.json(); } catch (e) { durumYaz('bozuk-yanit'); return; }

  const bes = pencere(d && d.five_hour);
  const haf = pencere(d && d.seven_day);
  if (!bes && !haf) { durumYaz('alan-yok'); return; }

  const simdi = Date.now();
  jsonYaz({
    yazildi: simdi,
    olcumZamani: simdi,   // ucun yaniti taze: olcum ani = simdi
    five_hour: bes,
    seven_day: haf,
    kaynak: 'api',
  });
}

main().catch(() => durumYaz('beklenmeyen'));
