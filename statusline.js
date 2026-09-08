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
  return !!(giris && giris.hooks && giris.hooks.some(
    (h) => typeof h.command === 'string' && h.command.includes('olay-yaz.js')));
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

function oku() {
  if (!fs.existsSync(AYAR)) return {};
  return JSON.parse(fs.readFileSync(AYAR, 'utf8'));
}

function yaz(obj) {
  const damga = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const yedek = `${AYAR}.yedek-${damga}`;
  if (fs.existsSync(AYAR)) fs.copyFileSync(AYAR, yedek);
  fs.writeFileSync(AYAR, JSON.stringify(obj, null, 2) + '\n', 'utf8');
  return yedek;
}

const komut = (process.argv[2] || 'durum').toLowerCase();
const d = oku();

if (komut === 'kur') {
  if (!fs.existsSync(BETIK)) {
    console.error(`durum-yaz.js bulunamadi: ${BETIK}`);
    process.exit(1);
  }
  if (d.statusLine && d.statusLine.command && !d.statusLine.command.includes('durum-yaz.js')) {
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
  if (d.statusLine && d.statusLine.command && !d.statusLine.command.includes('durum-yaz.js')) {
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
