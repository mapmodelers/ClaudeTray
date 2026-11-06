// tools/demo-gif.js - the README demo (docs/demo.gif), from the real panel page with made-up chats (no real data).
//   npm i playwright && node tools/demo-gif.js      (needs ffmpeg on the PATH)
// Story: Claude finishes in a dev session, you run its step from the tray, then reply - while a shopping research keeps working.
const { chromium } = require('playwright'); const path = require('path'); const fs = require('fs'); const os = require('os'); const { execFileSync } = require('child_process');
const root = path.join(__dirname, '..'), out = path.join(root, 'docs', 'demo.gif');
const DARK = { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757', act: '#6296d6', pur: '#7e6bc4', ok: '#6fa876', field: '#30302e', bub: '#1a1a18' };
const usage = [{ label: 'Session', used: 34, at: '16:10', left: '2h10' }, { label: 'Week', used: 41, at: 'Mon 09:00', left: '4d 18h' }];
const P = s => '<p>' + s + '</p>';
const W = 360, H = 560, FPS = 10;
const ask = 'CI fails one run in five on the rate-limit tests. Find why and fix it.';
const answer = P('Found it: the rate-limit tests share one Redis key, so parallel runs reset each other.') + P('Fixed with a per-test key prefix. Run the tests, then push:');
const steps = (s1, s2) => [{ n: 1, kind: 'ps', label: 'Run the rate-limit tests 20×', cmd: 'pytest tests/test_rate_limit.py -q --count 20', ...s1 },
                           { n: 2, kind: 'ps', label: 'Push the fix branch', cmd: 'git push -u origin fix/rate-limit-keys', ...s2 }];
const ebay = { id: 'chat/ebay', title: 'eBay: used ThinkPad X1 under €450', st: 'working', working: true, act: 'Comparing battery health across listings', web: true, age: 'now', bell: true, preview: '41 listings checked' };
const notes = { id: 'chat/notes', title: 'Release notes v2.4', st: 'done', web: true, age: '6m', bell: true, preview: 'Draft ready: 21 features, 14 fixes.' };
const devBase = { id: 'code/session_dev', title: 'api-gateway: flaky CI', web: true, skill: true, bell: true, model: 'Opus 5.5', effort: 'high' };

(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ctgif-')); let n = 0; const errs = [];
  const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1.5 });
  p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(() => { window.__posts = []; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
  await p.goto('file://' + path.join(root, 'ui', 'panel.html'));
  const state = (dev, extra) => Object.assign({ type: 'state', theme: DARK, maxH: H - 20, shown: true, docked: true, usage, sides: {}, settings: { version: '0.3' }, expanded: [devBase.id], big: [devBase.id], hidden: [], chats: [dev, ebay, notes] }, extra);
  const push = async (s) => { await p.evaluate(x => window.__h({ data: x }), s); await p.waitForTimeout(60); };
  const shot = async (secs) => { for (let i = 0; i < Math.round(secs * FPS); i++) { await p.screenshot({ path: path.join(tmp, String(n++).padStart(4, '0') + '.png') }); await p.waitForTimeout(1000 / FPS / 2); } };
  // a pointer drawn over the page (the panel has none of its own)
  const cursor = async (sel, click) => { await p.evaluate(([s, c]) => { let k = document.getElementById('__cur'); if (!k) { k = document.createElement('div'); k.id = '__cur';
      k.style.cssText = 'position:fixed;z-index:99999;width:18px;height:24px;pointer-events:none;transition:left .35s ease,top .35s ease';
      k.innerHTML = '<svg viewBox="0 0 18 24" width="18" height="24"><path d="M1 1v19l5-5 3.5 7 3-1.5L9 13.5h7z" fill="#fff" stroke="#111" stroke-width="1.2"/></svg>'; document.body.appendChild(k); }
      const e = document.querySelector(s); if (!e) return; const r = e.getBoundingClientRect(); k.style.left = (r.left + r.width / 2 - 2) + 'px'; k.style.top = (r.top + r.height / 2 - 2) + 'px';
      k.style.transform = c ? 'scale(.85)' : ''; }, [sel, !!click]); };
  // 1. Claude is working in the dev session and in the shopping research
  const working = Object.assign({}, devBase, { st: 'working', working: true, act: 'Running the rate-limit tests', age: 'now', msgs: [{ r: 'u', t: ask, x: 0 }] });
  // size the frame to the tallest scene (the panel reports its height), then play the story
  const done0 = Object.assign({}, devBase, { st: 'act', msgs: [{ r: 'u', t: ask, x: 0 }, { r: 'a', t: 'Found it.', h: answer, x: 1 }, { r: 'u', t: 'Pushed. Watch CI and tell me when it is green.', x: 2 }], steps: steps({}, {}) });
  for (let i = 0; i < 2; i++) await push(state(done0));
  await p.waitForTimeout(300); const hh = await p.evaluate(() => Math.max(...window.__posts.filter(m => m.type === 'size').map(m => m.h)));
  await p.setViewportSize({ width: W, height: Math.min(H, hh + 24) }); await p.waitForTimeout(200);
  for (let i = 0; i < 2; i++) await push(state(working));
  await shot(1.8);
  // 2. the answer arrives, with two steps
  const done = Object.assign({}, devBase, { st: 'act', age: 'now', unread: true, preview: 'Run the tests, then push.', msgs: [{ r: 'u', t: ask, x: 0 }, { r: 'a', t: 'Found it.', h: answer, x: 1 }], steps: steps({}, {}) });
  await push(state(done)); await shot(2.0);
  // 3. run step 1 from the tray: running, then done
  await cursor('.card[data-id="code/session_dev"] [data-a="run"][data-n="1"]'); await shot(0.6);
  await cursor('.card[data-id="code/session_dev"] [data-a="run"][data-n="1"]', true); await shot(0.2);
  await push(state(Object.assign({}, done, { unread: false, steps: steps({ status: 'running', running: true }, {}) }))); await shot(1.4);
  await push(state(Object.assign({}, done, { unread: false, steps: steps({ status: 'done', exit: 0 }, {}) }))); await shot(0.8);
  // 4. then step 2
  await cursor('.card[data-id="code/session_dev"] [data-a="run"][data-n="2"]'); await shot(0.5);
  await push(state(Object.assign({}, done, { unread: false, steps: steps({ status: 'done', exit: 0 }, { status: 'running', running: true }) }))); await shot(1.0);
  const allDone = Object.assign({}, done, { unread: false, allDone: true, steps: steps({ status: 'done', exit: 0 }, { status: 'done', exit: 0 }) });
  await push(state(allDone)); await shot(1.0);
  // 5. reply from the tray
  const box = '.card[data-id="code/session_dev"] textarea[placeholder^="Reply"]';
  await cursor(box); await shot(0.4);
  const reply = 'Pushed. Watch CI and tell me when it is green.';
  for (let i = 4; i <= reply.length; i += 4) { await p.evaluate(([s, v]) => { const t = document.querySelector(s); if (t) { t.value = v; t.dispatchEvent(new Event('input', { bubbles: true })); } }, [box, reply.slice(0, i)]); await shot(0.1); }
  await p.evaluate(([s, v]) => { const t = document.querySelector(s); if (t) { t.value = v; t.dispatchEvent(new Event('input', { bubbles: true })); } }, [box, reply]); await shot(0.6);
  await p.evaluate(s => { const t = document.querySelector(s); if (t) { t.value = ''; t.dispatchEvent(new Event('input', { bubbles: true })); } }, box);
  await push(state(Object.assign({}, allDone, { st: 'working', working: true, act: 'Watching the CI run', sending: reply }))); await shot(1.0);
  await push(state(Object.assign({}, allDone, { st: 'working', working: true, act: 'Watching the CI run', steps: [], msgs: [{ r: 'u', t: ask, x: 0 }, { r: 'a', t: 'Found it.', h: answer, x: 1 }, { r: 'u', t: reply, x: 2 }] }))); await shot(2.2);
  await b.close();
  if (errs.length) { console.log('page errors: ' + errs.join(' | ')); process.exit(1); }
  // frames -> gif (one palette for all frames: small and clean)
  const pal = path.join(tmp, 'pal.png');
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(FPS), '-i', path.join(tmp, '%04d.png'), '-vf', 'scale=' + Math.round(W * 1.5) + ':-2:flags=lanczos,palettegen=max_colors=128:stats_mode=diff', pal]);
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(FPS), '-i', path.join(tmp, '%04d.png'), '-i', pal, '-lavfi', 'scale=' + Math.round(W * 1.5) + ':-2:flags=lanczos[x];[x][1:v]paletteuse=dither=none:diff_mode=rectangle', '-loop', '0', out]);
  console.log('ok: docs/demo.gif (' + n + ' frames, ' + Math.round(fs.statSync(out).size / 1024) + ' KB)');
})();
