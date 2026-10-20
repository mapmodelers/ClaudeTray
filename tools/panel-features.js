const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
// tools/panel-features.js - chat features end to end without Windows: the tab scripts ($msgJs, $js) on a fake claude.ai page, then the panel.
//   npm i playwright && node tools/panel-features.js   -> logs/full-*.png + extracted data on stdout
const root = path.join(__dirname, '..'), out = path.join(root, 'logs'); fs.mkdirSync(out, { recursive: true });
const ps = fs.readFileSync(path.join(root, 'ClaudeTray.ps1'), 'utf8');
const grab = v => ps.slice(ps.indexOf(v + " = @'\n") + v.length + 6, ps.indexOf("\n'@", ps.indexOf(v + " = @'\n")));
const fileJs = grab('$fileJs'), msgJs = grab('$msgJs').replace('__FILES__', '(' + fileJs + ')'), stJs = grab('    $js');
const fake = `<div data-testid="user-message"><p>first question</p></div>
<div data-testid="assistant-message"><div role="button" aria-expanded="false">Lu un fichier, exécuté 8 commandes, et 3 étapes supplémentaires</div><p>Answer one with a <a href="https://example.com/doc?x=1">doc link</a> and <a href="javascript:alert(1)">bad</a>.</p><pre><code>Get-ChildItem C:\\</code></pre></div>
<div data-testid="user-message"><p>check</p></div>
<div data-testid="assistant-message"><div class="group/status flex"><span>Designing the panel</span><button>v</button></div><p>Short final answer.</p><div role="button" aria-expanded="false">Running a command</div>
<div><button>Allow once</button><button>Deny</button><button data-testid="action-bar-retry">r</button></div></div>
<button data-testid="model-selector-dropdown">Opus 5.5 Élevé</button><button aria-label="Stop">s</button>
<div class="ProseMirror" contenteditable="true"></div>`;
(async () => {
  const b = await chromium.launch(); const errs = [];
  const src = await b.newPage(); await src.setContent(fake);
  const msgs = JSON.parse(await src.evaluate(msgJs.replace('__N__', '20')));
  const st = JSON.parse(await src.evaluate(stJs));
  console.log('MSGS', JSON.stringify(msgs, null, 0));
  if (JSON.stringify(msgs).includes('Designing the panel')) console.log('FAIL: turn heading leaked into the reply');
  console.log('STATE act=%j prompts=%j model=%j retry=%j stop=%j', st.act, st.prompts, st.model, st.retry, st.stop);
  const p = await b.newPage({ viewport: { width: 340, height: 520 } });
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.addInitScript(() => { window.__posts = []; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
  await p.goto('file://' + path.join(root, 'ui', 'panel.html'));
  const theme = { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757', act: '#6296d6', pur: '#7e6bc4', ok: '#6fa876', field: '#30302e', bub: '#1a1a18' };
  const hash = t => { let h = 5381; const s0 = String(t || '').slice(0, 300); for (let i = 0; i < s0.length; i++) h = ((h << 5) + h + s0.charCodeAt(i)) | 0; return (h >>> 0).toString(36); };
  const chat = { id: 'code/s1', title: 'Tray widget', st: 'done', working: true, bell: true, age: '2m', preview: 'x', web: true, msgs, act: st.act, prompts: st.prompts, model: st.model, retry: false, readKey: hash(msgs[1].t), unread: true, steps: [] };
  const other = { id: 'chat/b', title: 'Another chat', st: 'done', working: false, bell: true, age: '1h', preview: 'Found 4 listings', web: true, unread: true };
  const state = o => Object.assign({ type: 'state', theme, nc: false, docked: false, maxH: 430, expanded: ['code/s1'], big: ['code/s1'], err: '', usage: [{ label: 'Session', used: 18, at: '03:39', left: '3h' }], hiddenAll: true, sides: { roomL: true, roomR: true }, mainW: 340, shown: true, chats: [chat, other] }, o);
  await p.evaluate(s => window.__h({ data: s }), state({})); await p.waitForTimeout(150);
  await p.screenshot({ path: path.join(out, 'full-1.png') });
  // finished: retry visible, prompts gone; reading marks it read after 1.5 s at the bottom
  chat.working = false; chat.prompts = []; chat.retry = true; chat.act = '';
  await p.evaluate(s => window.__h({ data: s }), state({})); await p.waitForTimeout(2300);
  await p.screenshot({ path: path.join(out, 'full-2.png') });
  await p.click('.m.a .pv'); await p.waitForTimeout(150); await p.screenshot({ path: path.join(out, 'full-3.png') });
  await p.hover('.prew'); await p.click('.prew .cpc').catch(e => errs.push('cpc ' + e.message));
  await p.click('a[data-href]').catch(e => errs.push('link ' + e.message));
  await p.click('.ask button').catch(() => {});
  const posts = await p.evaluate(() => window.__posts);
  console.log('POSTS', JSON.stringify(posts.filter(m => ['read', 'copy', 'openurl', 'press', 'retry'].includes(m.type))));
  const bad = await p.evaluate(() => [...document.querySelectorAll('.conv a')].map(a => a.getAttribute('data-href') || '(none)'));
  console.log('LINKS', JSON.stringify(bad), 'ERRORS', errs.length ? errs : 'none');
  await b.close();
})();
