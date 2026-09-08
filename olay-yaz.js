#!/usr/bin/env node
/*
 * Claude Code hook betigi — Stop ve Notification olaylarini widget'a bildirir.
 *
 *   node olay-yaz.js bitti     <- Stop hook
 *   node olay-yaz.js bildirim  <- Notification hook
 *
 * %APPDATA%\ClaudeKullanim\olay.json dosyasina son olayi yazar; widget bunu
 * okuyup "Claude bitirdi" / "izin bekliyor" satirini gosterir.
 *
 * ┌── GUVENLIK ────────────────────────────────────────────────────────────┐
 * │ Stop hook'u exit 2 dondugunde Claude DURMAZ, konusmaya devam eder.     │
 * │ Yani buradaki bir hata sonsuz donguye yol acabilir. Bu yuzden butun    │
 * │ govde try/catch icinde ve her yol process.exit(0) ile bitiyor.         │
 * └────────────────────────────────────────────────────────────────────────┘
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const KLASOR = path.join(process.env.APPDATA || os.homedir(), 'ClaudeKullanim');
const DOSYA = path.join(KLASOR, 'olay.json');

function yaz(veri) {
  const tmp = DOSYA + '.tmp';
  try {
    fs.mkdirSync(KLASOR, { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(veri), 'utf8');
    fs.renameSync(tmp, DOSYA);
  } catch (e) {
    try { fs.writeFileSync(DOSYA, JSON.stringify(veri), 'utf8'); } catch (e2) { /* sessiz */ }
  }
}

function main() {
  const tur = (process.argv[2] || 'bitti').toLowerCase();

  let d = {};
  try { d = JSON.parse(fs.readFileSync(0, 'utf8')); } catch (e) { d = {}; }

  // Alt ajanlar (subagent) da olay uretir; her birinde yanip sonmek gurultu
  // olur. agent_id yalnizca alt ajanlarda dolu gelir — onlari atliyoruz.
  if (d.agent_id) return;

  // Bildirimlerin hepsi ilgi cekici degil; yalnizca bizden bir sey
  // bekleyenleri gosteriyoruz.
  const ILGINC = ['permission_prompt', 'idle_prompt', 'agent_needs_input', 'agent_completed'];
  if (tur === 'bildirim' && d.notification_type && !ILGINC.includes(d.notification_type)) return;

  yaz({
    zaman: Date.now(),
    tur: tur,                                   // 'bitti' | 'bildirim'
    tip: d.notification_type || null,
    dizin: d.cwd ? path.basename(d.cwd) : null,
    oturum: d.session_id || null,
  });
}

try { main(); } catch (e) { /* yutuluyor - asla exit 2 dondurme */ }
process.exit(0);
