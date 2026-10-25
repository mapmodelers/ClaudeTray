// tools/readme-shots.js - the README images, from the real panel page with made-up chats (no real data).
//   npm i playwright && node tools/readme-shots.js   -> docs/hero.png, docs/question.png, docs/compact.png
const { chromium } = require('playwright'); const path = require('path');
const root = path.join(__dirname, '..'), docs = path.join(root, 'docs');
const DARK = { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757', act: '#6296d6', pur: '#7e6bc4', ok: '#6fa876', field: '#30302e', bub: '#1a1a18' };
const LIGHT = { bg: '#faf9f5', card: '#ffffff', tx: '#141413', mu: '#7d7a72', ln: '#e6e3da', acc: '#c9633f', act: '#3a76b8', pur: '#7e6bc4', ok: '#3f8a4a', field: '#ffffff', bub: '#f0eee6' };
const usage = [{ label: 'Session', used: 34, at: '16:10', left: '2h10' }, { label: 'Week', used: 41, at: 'Mon 09:00', left: '4d 18h' }];
const P = s => '<p>' + s + '</p>';
const ago = m => new Date(Date.now() - m * 60000).toISOString();
// made-up chats: a few everyday uses (code, shopping research, ops, writing, finance, contracts)
const dev = { id: 'code/session_dev', title: 'api-gateway: flaky CI', st: 'act', preview: 'Push the fix branch, then check CI.', web: true, skill: true, age: '2m', bell: true, model: 'Opus 5.5', effort: 'high',
  msgs: [{ r: 'u', t: 'CI fails one run in five on the rate-limit tests. Find why and fix it.', x: 0 },
         { r: 'a', t: 'Found it.', x: 1, h: P('Found it: the rate-limit tests share one Redis key, so parallel runs reset each other.') +
           P('Fixed with a per-test key prefix in <code>tests/conftest.py</code>. Your turn:') }],
  steps: [{ n: 1, kind: 'ps', label: 'Run the rate-limit tests 20×', cmd: 'for ($i=0;$i -lt 20;$i++) { pytest tests/test_rate_limit.py -q }', status: 'done', exit: 0 },
          { n: 2, kind: 'ps', label: 'Push the fix branch', cmd: 'git push -u origin fix/rate-limit-keys' },
          { n: 3, kind: 'observe', label: 'CI green on the PR?', options: ['Yes', 'No'] }] };
const ebay = { id: 'chat/ebay', title: 'eBay: used ThinkPad X1 under €450', st: 'working', working: true, act: 'Comparing battery health across listings', web: true, age: 'now', bell: true, preview: '41 listings checked, 7 match so far' };
const perm = { id: 'code/session_perm', title: 'Nightly backup script', st: 'done', web: true, skill: true, age: '4m', bell: true, prompts: ['Allow once', 'Deny'], preview: '' };
const rel = { id: 'code/session_rel', title: 'Release notes v2.4', st: 'done', web: true, skill: true, age: '1m', bell: true, preview: 'Which style for the changelog?', model: 'Sonnet 5.5',
  msgs: [{ r: 'u', t: 'Draft the v2.4 release notes from the merged PRs.', x: 0 }, { r: 'a', t: '38 PRs since v2.3.', x: 1, h: P('38 PRs merged since v2.3: 21 features, 14 fixes, 3 docs. One choice first.') }],
  q: { t: 'Which style for the changelog?', step: 1, steps: 2, next: true, prev: false, skip: 'Skip', multi: false, card: true,
       o: [{ l: 'Grouped by area', d: 'Features / Fixes / Docs' }, { l: 'One line per change', d: 'Flat list, newest first' }, { l: 'Customer-facing', d: 'Plain language, no internals' }] } };
const invoices = { id: 'chat/inv', title: 'Q4 supplier invoices', st: 'done', unread: true, web: true, age: '9m', bell: true, preview: '3 invoices over budget, summary sheet ready.' };
const contract = { id: 'chat/contract', title: 'Freelance contract review', st: 'done', web: true, age: '1h', bell: false, preview: 'Two clauses to renegotiate: payment terms and IP.' };
const catalog = { recent: [{ id: '00000000-0000-0000-0000-00000000a001', name: 'Pitch deck: outline v2', at: ago(1) }, { id: '00000000-0000-0000-0000-00000000a002', name: 'Blender add-on: UV packing bug', at: ago(55) },
                           { id: '00000000-0000-0000-0000-00000000a003', name: 'Laptop dock: USB-C compatibility', at: ago(130) }],
                  projects: [{ id: 'p1', name: 'Client work' }, { id: 'p2', name: 'Internal tools' }, { id: 'p3', name: 'Hardware research' }] };

(async () => {
  const b = await chromium.launch(); const errs = [];
  const panel = async (theme, chats, o, w) => {
    const p = await b.newPage({ viewport: { width: w || 340, height: 700 }, deviceScaleFactor: 2 });
    p.on('pageerror', e => errs.push(e.message));
    await p.addInitScript(() => { window.__posts = []; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
    await p.goto('file://' + path.join(root, 'ui', 'panel.html'));
    const st = Object.assign({ type: 'state', theme, maxH: 640, shown: true, docked: true, usage, sides: {}, settings: { version: '0.3' }, expanded: [], chats, hidden: [], catalog }, o);
    for (let i = 0; i < 2; i++) { await p.evaluate(s => window.__h({ data: s }), st); await p.waitForTimeout(150); }
    const fit = async () => { const h = await p.evaluate(() => window.__posts.filter(m => m.type === 'size').pop().h); await p.setViewportSize({ width: w || 340, height: Math.min(700, h) }); await p.waitForTimeout(150); };
    await fit(); p.fit = fit;
    return p;
  };
  // 1. a question from Claude, answered in the tray (dark)
  let p = await panel(DARK, [rel, invoices, contract], { expanded: [rel.id], big: [rel.id] });
  await p.screenshot({ path: path.join(docs, 'question.png') }); await p.close();
  // 2. light theme: BROWSE open (search, recents, projects) under the chats
  p = await panel(LIGHT, [ebay, invoices, contract], { layout: { v: 1, sec: [], browse: true, brh: 210 } });
  await p.fit(); await p.screenshot({ path: path.join(docs, 'compact.png') }); await p.close();
  // 3. hero: the panel in context, above the clock - a dev session open, a shopping research running, a permission waiting, recent chats greyed
  p = await panel(DARK, [perm, dev, ebay, invoices, contract], { expanded: [dev.id], big: [dev.id], layout: { v: 1, sec: [], recent: true } }, 360);
  await p.click('.card[data-id="' + dev.id + '"] .head'); await p.waitForTimeout(500);                         // collapsed: all rows + the recent ones show
  await p.click('.card[data-id="' + dev.id + '"] .mdot'); await p.waitForTimeout(300);       // the dev session open again (recent rows: only active ones)
  // the user is writing back, with two screenshots of the bug attached (made-up images drawn here)
  await p.evaluate(id => {
    const shot = (lines, bad) => { const c = document.createElement('canvas'); c.width = 320; c.height = 200; const g = c.getContext('2d');
      g.fillStyle = '#1b1b1d'; g.fillRect(0, 0, 320, 200); g.fillStyle = '#2b2b2e'; g.fillRect(0, 0, 320, 22); ['#e5534b', '#d4a72c', '#57ab5a'].forEach((col, i) => { g.fillStyle = col; g.beginPath(); g.arc(14 + i * 14, 11, 4, 0, 7); g.fill(); });
      g.font = '12px monospace'; lines.forEach((t, i) => { g.fillStyle = bad.includes(i) ? '#ff6b6b' : '#b9b9b9'; g.fillText(t, 10, 44 + i * 18); }); return c.toDataURL('image/png'); };
    const a = shot(['$ pytest tests/test_rate_limit.py', 'collected 12 items', 'test_burst ........ ok', 'test_window_reset FAILED', 'AssertionError: 429 != 200', 'redis key: rl:global', '1 failed, 11 passed'], [3, 4, 6]);
    const b = shot(['CI  api-gateway  #4812', 'job: rate-limit (3/4)', 'status: failed  02:41', 'retry #2 ......... failed', 'TimeoutError: lock held', 'by test_window_reset'], [2, 3, 4]);
    const cd = cards.get(id); cd.files.push({ name: 'ci-run-4812.png', type: 'image/png', size: 48000, b64: '', thumb: b }, { name: 'pytest-local.png', type: 'image/png', size: 41000, b64: '', thumb: a }); drawAtts(cd);
    const ta = document.querySelector('.card[data-id="' + id + '"] textarea[placeholder^="Reply"]'); ta.value = 'Still flaky on CI after the push, two runs attached'; ta.dispatchEvent(new Event('input', { bubbles: true }));
  }, dev.id);
  await p.waitForTimeout(300); await p.fit();
  const pb = await p.screenshot({ type: 'png' }); const ph = p.viewportSize().height; await p.close();
  const HW = 600, HH = ph + 110;
  const hero = await b.newPage({ viewport: { width: HW, height: HH }, deviceScaleFactor: 2 });
  const ring = (u) => { const r = 9, c = 2 * Math.PI * r; return `<svg width="24" height="24" viewBox="0 0 24 24"><circle cx="12" cy="12" r="${r}" fill="none" stroke="#5a5a58" stroke-width="2.6"/><circle cx="12" cy="12" r="${r}" fill="none" stroke="#f2f2f2" stroke-width="2.6" stroke-linecap="round" stroke-dasharray="${c * u / 100} ${c}" transform="rotate(-90 12 12)"/><text x="12" y="15.2" text-anchor="middle" font-family="Segoe UI,Arial" font-weight="700" font-size="8.5" fill="#f2f2f2">${u}</text></svg>`; };     // the usual icon: usage ring + number
  const glyph = (d, c) => `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="${c || '#e8e8e8'}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
  await hero.setContent(`<html><body style="margin:0;width:${HW}px;height:${HH}px;overflow:hidden;font-family:'Segoe UI',system-ui,sans-serif;background:#7b7b7b">
    <img src="data:image/png;base64,${pb.toString('base64')}" style="position:absolute;right:16px;bottom:56px;width:360px;border-radius:9px;box-shadow:0 14px 44px rgba(0,0,0,.6),0 0 0 1px rgba(255,255,255,.07)">
    <div style="position:absolute;left:0;right:0;bottom:0;height:44px;background:rgba(28,28,30,.97);border-top:1px solid #333;display:flex;align-items:center;justify-content:flex-end;gap:14px;padding-right:16px;color:#eee;font-size:11.5px">
      <span style="color:#ccc">^</span>${ring(34)}${glyph('<path d="M5 12a10 10 0 0 1 14 0M8.5 15.5a5 5 0 0 1 7 0M12 19h.01"/>')}${glyph('<path d="M4 9v6h4l5 4V5L8 9H4zM16 9a4 4 0 0 1 0 6"/>')}
      <div style="text-align:right;line-height:1.25"><div>14:32</div><div>25/10/2026</div></div></div></body></html>`);
  await hero.waitForTimeout(200); await hero.screenshot({ path: path.join(docs, 'hero.png') }); await hero.close();
  await b.close();
  console.log(errs.length ? 'page errors: ' + errs.join(' | ') : 'ok: docs/hero.png question.png compact.png');
  process.exit(errs.length ? 1 : 0);
})();
