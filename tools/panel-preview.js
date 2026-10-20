// tools/panel-preview.js - render ui/panel.html without Windows (Node + Playwright), with a mocked WebView2 bridge.
// Also runs the web engine's message extractor ($msgJs in ClaudeTray.ps1) on a fake claude.ai page.
//   npm i playwright && node tools/panel-preview.js      -> logs/panel-list.png, logs/panel-chat.png (+ errors on stdout)
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
const root = path.join(__dirname, '..'); const out = path.join(root, 'logs'); fs.mkdirSync(out, { recursive: true });
const ps = fs.readFileSync(path.join(root, 'ClaudeTray.ps1'), 'utf8');
const grab = (v) => ps.slice(ps.indexOf(v + " = @'\n") + v.length + 6, ps.indexOf("\n'@", ps.indexOf(v + " = @'\n")));
const msgJs = grab('$msgJs').replace('__FILES__', '(' + grab('$fileJs') + ')');
const fake = `<div data-testid="user-message"><span class="sr-only">You said:</span><p>can you fix the panel?</p><span>2 min ago</span></div>
<div data-testid="assistant-message"><p>Sure. The plan:</p><ol><li><strong>Phase 1</strong>: host in <code>WebView2</code></li><li>Phase 2: action cards</li></ol>
<pre><code>$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2</code></pre><button>Copy</button><svg></svg>
<p>Unsafe <a href="javascript:alert(1)" onclick="alert(2)">link</a> <img src=x onerror="alert(3)"></p></div>
<div data-testid="user-message"><p>check</p></div><div data-testid="assistant-message"><p>Here is the file.</p><a href="/api/files/abc" download="report.csv"><span>report.csv</span></a></div>`;
(async () => {
  const b = await chromium.launch(); const errs = [];
  const src = await b.newPage(); await src.setContent(fake);
  const msgs = JSON.parse(await src.evaluate(msgJs.replace('__N__', '20')));
  const p = await b.newPage({ viewport: { width: 340, height: 500 } });
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.addInitScript(() => { window.__posts = []; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
  await p.goto('file://' + path.join(root, 'ui', 'panel.html'));
  const theme = { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757', act: '#6296d6', pur: '#7e6bc4', ok: '#6fa876', field: '#30302e', bub: '#1a1a18' };
  const usage = [{ label: 'Session', used: 18, at: '03:39', left: '3h20' }, { label: 'Week', used: 77, at: 'Mon 18:00', left: '6d 17h' }];
  const chats = [{ id: 'code/session_A', title: 'Tray widget', st: 'act', working: false, bell: true, age: '2m', preview: 'Run the 3 steps, then check.', web: true },
                 { id: 'chat/b', title: 'Another chat', st: 'done', working: true, bell: false, age: '1h', preview: 'Found 4 listings', web: true }];
  const state = (o) => Object.assign({ type: 'state', theme, nc: false, docked: false, maxH: 430, expanded: [], sideOn: true, sides: { l: false, r: false, roomL: true, roomR: true }, mainW: 340, err: '', usage, hiddenAll: true, chats }, o);
  await p.evaluate(s => window.__h({ data: s }), state({})); await p.waitForTimeout(100);
  await p.setViewportSize({ width: 340, height: (await p.evaluate(() => window.__posts.filter(m => m.type === 'size').pop().h)) });
  await p.screenshot({ path: path.join(out, 'panel-list.png') });
  const open = JSON.parse(JSON.stringify(chats)); Object.assign(open[0], { msgs, working: true, lastSent: 'check', steps: [
    { n: 1, kind: 'ps', label: 'Restart the tray', cmd: 'ClaudeTray.ps1 -Restart', status: 'done', exit: 0 },
    { n: 2, kind: 'observe', label: 'Does it scroll like Claude?', status: 'done', answer: 'yes, smooth' },
    { n: 3, kind: 'manual', label: 'Send a message from the panel', status: 'pending' }] });
  await p.evaluate(s => window.__h({ data: s }), state({ chats: open }));
  await p.waitForTimeout(100);   // a chat with new steps opens by itself (full)
  await p.waitForTimeout(100);
  await p.setViewportSize({ width: 340, height: Math.min(700, (await p.evaluate(() => window.__posts.filter(m => m.type === 'size').pop().h))) });
  await p.waitForTimeout(100); await p.screenshot({ path: path.join(out, 'panel-chat.png') });
  // reading column (separate window in the tray): hover a long reply -> the panel posts 'col' -> render ui/side.html with it
  const longMsg = msgs.find(m => m.r === 'a');
  longMsg.t = 'Long reply. '.repeat(60); longMsg.h = '<p>' + 'Long reply paragraph for the side column. '.repeat(12) + '</p><ul><li>a</li><li>b</li></ul><pre><code>Get-Thing</code></pre>';
  await p.evaluate(s => window.__h({ data: s }), state({ chats: open })); await p.waitForTimeout(100);
  await p.hover('.m.a .pv'); await p.waitForTimeout(700);
  const col = (await p.evaluate(() => window.__posts)).filter(m => m.type === 'col').pop();
  console.log('hover -> col message:', col ? col.x + ' open=' + col.open + ' ' + col.html.length + ' chars' : 'NONE');
  const sp = await b.newPage({ viewport: { width: 360, height: 420 } });
  sp.on('pageerror', e => errs.push('side: ' + e.message));
  await sp.addInitScript(() => { window.__posts = []; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
  await sp.goto('file://' + path.join(root, 'ui', 'side.html'));
  await sp.evaluate(m => window.__h({ data: m }), { type: 'theme', theme: { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757' } });
  if (col) await sp.evaluate(m => window.__h({ data: Object.assign({}, m, { type: 'show' }) }), col);
  await sp.waitForTimeout(100); await sp.screenshot({ path: path.join(out, 'panel-side.png') });
  console.log('files found by the extractor:', JSON.stringify(msgs.filter(m => m.f).map(m => ({ x: m.x, f: m.f }))));
  await p.locator('.card input[type=file]').first().setInputFiles({ name: 'shot.png', mimeType: 'image/png', buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64') });
  await p.waitForTimeout(200); await p.screenshot({ path: path.join(out, 'panel-attach.png') });
  await p.click('.card .send'); await p.waitForTimeout(100);
  const snd = (await p.evaluate(() => window.__posts)).filter(m => m.type === 'send').pop();
  console.log('send with files:', snd ? snd.files.map(f => f.name + ' ' + f.b64.length + 'b64') : 'NONE');
  await p.click('.fch [data-mode=copy]'); console.log('dl msg:', JSON.stringify((await p.evaluate(() => window.__posts)).filter(m => m.type === 'dl').pop()));
  // new chat form
  await p.click('#plus'); await p.click('#pmenu .pmi >> text=New chat'); await p.evaluate(s => window.__h({ data: s }), state({ chats: open, catalog: { projects: [{ id: 'p1', name: 'Work' }, { id: 'p2', name: 'Home' }] } }));
  await p.selectOption('#nfProj', 'p1'); await p.fill('#nfName', 'Tray test'); await p.selectOption('#nfModel', 'Sonnet'); await p.fill('#nfMsg', 'test chat');
  await p.waitForTimeout(100); await p.screenshot({ path: path.join(out, 'panel-new.png') });
  await p.press('#nfMsg', 'Enter');
  console.log('newchat msg:', JSON.stringify((await p.evaluate(() => window.__posts)).filter(m => m.type === 'newchat' || m.type === 'catalog')));
  const unsafe = await p.evaluate(() => document.querySelectorAll('#msgs [onclick],#msgs [onerror],#msgs a,#msgs img').length);
  console.log('page messages:', JSON.stringify(await p.evaluate(() => window.__posts)));
  console.log('unsafe nodes in the conversation:', unsafe, '| page errors:', errs.length ? errs : 'none');
  await b.close(); process.exit(unsafe || errs.length ? 1 : 0);
})();
