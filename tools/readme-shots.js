// tools/readme-shots.js - the README images, from the real panel page with made-up chats (no real data).
//   npm i playwright && node tools/readme-shots.js   -> docs/hero.png, docs/question.png, docs/compact.png
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
const root = path.join(__dirname, '..'), docs = path.join(root, 'docs');
const DARK = { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757', act: '#6296d6', pur: '#7e6bc4', ok: '#6fa876', field: '#30302e', bub: '#1a1a18' };
const LIGHT = { bg: '#faf9f5', card: '#ffffff', tx: '#141413', mu: '#7d7a72', ln: '#e6e3da', acc: '#c9633f', act: '#3a76b8', pur: '#7e6bc4', ok: '#3f8a4a', field: '#ffffff', bub: '#f0eee6' };
const usage = [{ label: 'Session', used: 34, at: '16:10', left: '2h10' }, { label: 'Week', used: 41, at: 'Mon 09:00', left: '4d 18h' }];
const P = s => '<p>' + s + '</p>';
const dev = { id: 'code/session_dev', title: 'api-gateway: flaky CI', st: 'act', preview: 'Push the fix branch, then check CI.', web: true, skill: true, age: '2m', bell: true, model: 'Opus 5.5',
  msgs: [{ r: 'u', t: 'CI fails one run in five on the rate-limit tests. Find why and fix it.', x: 0 },
         { r: 'a', t: 'Found it.', x: 1, h: P('Found it: the rate-limit tests share one Redis key, so parallel runs reset each other.') +
           P('Fixed with a per-test key prefix in <code>tests/conftest.py</code>. Your turn:') }],
  steps: [{ n: 1, kind: 'ps', label: 'Run the rate-limit tests 20×', cmd: 'for ($i=0;$i -lt 20;$i++) { pytest tests/test_rate_limit.py -q }', status: 'done', exit: 0 },
          { n: 2, kind: 'ps', label: 'Push the fix branch', cmd: 'git push -u origin fix/rate-limit-keys' },
          { n: 3, kind: 'observe', label: 'CI green on the PR?', options: ['Yes', 'No'] }] };
const scrape = { id: 'chat/scrape', title: 'Rental listings → CSV', st: 'working', working: true, web: true, skill: true, age: 'now', bell: true, preview: 'Page 14 of 40 · 312 listings so far' };
const cook = { id: 'chat/cook', title: 'Risotto for six, no wine', st: 'done', unread: true, web: true, age: '9m', bell: true, preview: 'Swap the wine for stock + a squeeze of lemon.' };
const rel = { id: 'code/session_rel', title: 'Release notes v2.4', st: 'done', web: true, skill: true, age: '1m', bell: true, preview: 'Which style for the changelog?',
  msgs: [{ r: 'u', t: 'Draft the v2.4 release notes from the merged PRs.', x: 0 }, { r: 'a', t: '38 PRs since v2.3.', x: 1, h: P('38 PRs merged since v2.3: 21 features, 14 fixes, 3 docs. One choice first.') }],
  q: { t: 'Which style for the changelog?', step: 1, steps: 2, next: true, prev: false, skip: 'Skip', multi: false, card: true,
       o: [{ l: 'Grouped by area', d: 'Features / Fixes / Docs' }, { l: 'One line per change', d: 'Flat list, newest first' }, { l: 'Customer-facing', d: 'Plain language, no internals' }] } };
const budget = { id: 'chat/budget', title: 'Q4 budget sheet', st: 'done', web: true, age: '1h', bell: false, preview: 'Totals updated, rent row fixed.' };
const trip = { id: 'chat/trip', title: 'Lisbon in May: 4 days', st: 'done', web: true, age: '3h', bell: true, preview: 'Day 2: Belém in the morning, LX Factory after.' };
const perm = { id: 'code/session_perm', title: 'Nightly backup script', st: 'done', web: true, skill: true, age: '4m', bell: true, prompts: ['Allow once', 'Deny'], preview: '' };

(async () => {
  const b = await chromium.launch(); const errs = [];
  const panel = async (theme, chats, o, w) => {
    const p = await b.newPage({ viewport: { width: w || 340, height: 700 }, deviceScaleFactor: 2 });
    p.on('pageerror', e => errs.push(e.message));
    await p.addInitScript(() => { window.__posts = []; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
    await p.goto('file://' + path.join(root, 'ui', 'panel.html'));
    await p.addStyleTag({ content: '#brw{display:none!important}' });     // Browse is being reworked: not in the README images for now
    const st = Object.assign({ type: 'state', theme, maxH: 640, shown: true, docked: true, usage, sides: {}, settings: { version: '0.2' }, expanded: [], chats, hidden: [] }, o);
    for (let i = 0; i < 2; i++) { await p.evaluate(s => window.__h({ data: s }), st); await p.waitForTimeout(150); }
    const h = await p.evaluate(() => window.__posts.filter(m => m.type === 'size').pop().h);
    await p.setViewportSize({ width: w || 340, height: Math.min(700, h) }); await p.waitForTimeout(150);
    return p;
  };
  // 1. a question from Claude, answered in the tray (dark)
  let p = await panel(DARK, [rel, cook, trip], { expanded: [rel.id], big: [rel.id] });
  await p.screenshot({ path: path.join(docs, 'question.png') }); await p.close();
  // 3. compact mode (light)
  p = await panel(LIGHT, [perm, scrape, dev, cook, budget, trip], { settings: { compact: true }, expanded: ['-'] });
  await p.click('.card[data-id="' + perm.id + '"] .head'); await p.waitForTimeout(200);
  { const h2 = await p.evaluate(() => window.__posts.filter(m => m.type === 'size').pop().h); await p.setViewportSize({ width: 340, height: Math.min(700, h2) }); await p.waitForTimeout(150); }
  await p.screenshot({ path: path.join(docs, 'compact.png') }); await p.close();
  // 4. hero: the panel in context, above the clock (a plain desktop corner, nothing real)
  p = await panel(DARK, [perm, dev, scrape, cook, budget, trip], { expanded: [dev.id], big: [dev.id], settings: { compact: true } }, 360);
  await p.click('.card[data-id="' + perm.id + '"] .head'); await p.waitForTimeout(200);     // the asking chat opened by itself: show it as its one-line row
  { const h2 = await p.evaluate(() => window.__posts.filter(m => m.type === 'size').pop().h); await p.setViewportSize({ width: 360, height: Math.min(700, h2) }); await p.waitForTimeout(150); }
  const pb = await p.screenshot({ type: 'png' }); const ph = p.viewportSize().height; await p.close();
  const HW = 600, HH = ph + 110;
  const hero = await b.newPage({ viewport: { width: HW, height: HH }, deviceScaleFactor: 2 });
  const ring = (u) => { const r = 9, c = 2 * Math.PI * r; return `<svg width="24" height="24" viewBox="0 0 24 24"><circle cx="12" cy="12" r="${r}" fill="none" stroke="#5a5a58" stroke-width="2.6"/><circle cx="12" cy="12" r="${r}" fill="none" stroke="#f2f2f2" stroke-width="2.6" stroke-linecap="round" stroke-dasharray="${c * u / 100} ${c}" transform="rotate(-90 12 12)"/><text x="12" y="15.2" text-anchor="middle" font-family="Segoe UI,Arial" font-weight="700" font-size="8.5" fill="#f2f2f2">${u}</text><circle cx="19" cy="5" r="5" fill="#1c1c1c"/><circle cx="19" cy="5" r="4" fill="#4e96e6"/><text x="19" y="7.4" text-anchor="middle" font-family="Segoe UI,Arial" font-weight="700" font-size="6.5" fill="#fff">?</text></svg>`; };
  const glyph = (d, c) => `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="${c || '#e8e8e8'}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
  await hero.setContent(`<html><body style="margin:0;width:${HW}px;height:${HH}px;overflow:hidden;font-family:'Segoe UI',system-ui,sans-serif;background:#7b7b7b">     <!-- plain neutral desktop -->
    <img src="data:image/png;base64,${pb.toString('base64')}" style="position:absolute;right:16px;bottom:56px;width:360px;border-radius:9px;box-shadow:0 14px 44px rgba(0,0,0,.6),0 0 0 1px rgba(255,255,255,.07)">
    <div style="position:absolute;left:0;right:0;bottom:0;height:44px;background:rgba(28,28,30,.97);border-top:1px solid #333;display:flex;align-items:center;justify-content:flex-end;gap:14px;padding-right:16px;color:#eee;font-size:11.5px">
      <span style="color:#ccc">^</span>${ring(34)}${glyph('<path d="M5 12a10 10 0 0 1 14 0M8.5 15.5a5 5 0 0 1 7 0M12 19h.01"/>')}${glyph('<path d="M4 9v6h4l5 4V5L8 9H4zM16 9a4 4 0 0 1 0 6"/>')}
      <div style="text-align:right;line-height:1.25"><div>14:32</div><div>20/10/2026</div></div></div></body></html>`);
  await hero.waitForTimeout(200); await hero.screenshot({ path: path.join(docs, 'hero.png') }); await hero.close();
  await b.close();
  console.log(errs.length ? 'page errors: ' + errs.join(' | ') : 'ok: docs/hero.png question.png compact.png');
  process.exit(errs.length ? 1 : 0);
})();
