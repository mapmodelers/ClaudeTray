const { chromium } = require('playwright'); const path = require('path');
// tools/panel-icons.js - icons that show only while the pointer is there, without Windows:
//   a chat's line shows its icons on hover, and then all of them; the window buttons (minimize / switch / close) show while the pointer is over the panel.
//   node tools/panel-icons.js [screenshot.png]
const root = path.join(__dirname, '..');
let fails = 0; const ok = (c, m) => { console.log((c ? 'ok   ' : 'FAIL ') + m); if (!c) fails++; };
(async () => {
  const b = await chromium.launch(); const errs = [];
  const p = await b.newPage({ viewport: { width: 380, height: 420 }, deviceScaleFactor: process.argv[2] ? 2 : 1 });
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.addInitScript(() => { window.__posts = []; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
  await p.goto('file://' + path.join(root, 'ui', 'panel.html'));
  const theme = { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757', act: '#6296d6', pur: '#7e6bc4', ok: '#6fa876', field: '#30302e', bub: '#1a1a18' };
  const mk = (id, title, o) => Object.assign({ id, title, st: 'done', working: false, bell: true, age: '5m', preview: 'a fairly long last line from Claude that fills the field', web: true, msgs: [{ r: 'u', t: 'hello' }, { r: 'a', t: 'answer' }], steps: [] }, o);
  const chats = [mk('chat/a', 'Alpha'), mk('chat/b', 'Bravo', { bell: false, pin: true }), mk('chat/c', 'Charlie', { working: true })];
  let dictSt = 'on';
  const state = o => Object.assign({ type: 'state', theme, nc: false, docked: false, maxH: 420, expanded: [], big: [], err: '', usage: [], hiddenAll: true, sides: { roomL: true, roomR: true }, mainW: 380, shown: true, chats, settings: { version: 'test', dict: dictSt } }, o);
  const push = async o => { await p.evaluate(s => window.__h({ data: s }), state(o)); await p.waitForTimeout(130); };
  await push(); await push();
  const row = id => p.evaluate(id => { const c = document.querySelector('.card[data-id="' + id + '"]'), vis = e => { const r = e.getBoundingClientRect(), s = getComputedStyle(e); return r.width > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
    const all = [...c.querySelectorAll('.mini .mt .ib, .mini .mtl .ib')].filter(vis), stop = c.querySelector('.mini .stop'), tl = c.querySelector('.mtl'), fl = c.querySelector('.mfld').getBoundingClientRect();
    return { icons: all.map(e => e.dataset.a), fieldW: Math.round(fl.width), tlRight: vis(tl) ? Math.round(tl.getBoundingClientRect().right) : null, tlLeft: vis(tl) ? Math.round(tl.getBoundingClientRect().left) : null, fieldL: Math.round(fl.left), stopL: stop && vis(stop) ? Math.round(stop.getBoundingClientRect().left) : null, age: vis(c.querySelector('.mt .age')) }; }, id);
  await p.mouse.move(190, 400); await p.waitForTimeout(100);
  let a = await row('chat/a'), bb = await row('chat/b'), c = await row('chat/c');
  ok(a.icons.length === 0 && a.age, 'pointer elsewhere: a chat line shows no icon, only its age (' + JSON.stringify(a.icons) + ')');
  ok(JSON.stringify(bb.icons) === '["bell","pinc"]', 'a muted, pinned chat keeps those two marks in view (' + JSON.stringify(bb.icons) + ')');
  const w0 = a.fieldW;
  await p.hover('.card[data-id="chat/a"] .mph', { force: true }).catch(() => p.hover('.card[data-id="chat/a"] .mini')); await p.waitForTimeout(120);
  a = await row('chat/a');
  ok(JSON.stringify(a.icons) === '["open","web","mv","hide","bell","focus","pinc"]', 'pointer on the line: all seven icons, like on an open chat (' + JSON.stringify(a.icons) + ')');
  ok(a.fieldW === w0 && a.age && a.tlLeft >= a.fieldL, 'nothing moves: the field keeps its width, the age stays, the icons sit over the end of the field (' + w0 + ' -> ' + a.fieldW + ', icons from ' + a.tlLeft + ')');
  if (process.argv[2]) await p.screenshot({ path: process.argv[2], clip: { x: 0, y: 0, width: 380, height: 110 } });
  await p.hover('.card[data-id="chat/b"] .mini'); await p.waitForTimeout(120); bb = await row('chat/b');
  ok(JSON.stringify(bb.icons.slice().sort()) === '["bell","focus","hide","mv","open","pinc","web"]' && bb.icons.length === 7, 'the muted, pinned chat on hover: seven icons, none twice (' + JSON.stringify(bb.icons) + ')');
  await p.hover('.card[data-id="chat/c"] .mini'); await p.waitForTimeout(120); c = await row('chat/c');
  ok(c.stopL !== null && c.tlRight !== null && c.tlRight <= c.stopL + 1, 'a working chat: the icons stop before the Stop button, which stays where it was (icons end ' + c.tlRight + ', stop at ' + c.stopL + ')');
  const n0 = await p.evaluate(() => window.__posts.length); await p.click('.card[data-id="chat/c"] .mtl [data-a=bell]'); await p.waitForTimeout(100);
  ok((await p.evaluate(n => window.__posts.slice(n).filter(m => m.type === 'bell' && m.id === 'chat/c').length, n0)) === 1, 'an icon shown on hover works (bell)');
  await p.click('.card[data-id="chat/a"] .mi'); await p.waitForTimeout(120); a = await row('chat/a');
  ok(a.icons.length === 0, 'while you type in the one-line box, the icons stay away (' + JSON.stringify(a.icons) + ')');
  await p.evaluate(() => document.activeElement.blur());
  // microphone: in the full reply box always, in the one-line box once the cursor is in it
  await p.click('.card[data-id="chat/a"] .mi'); await p.waitForTimeout(120);
  ok((await p.evaluate(() => { const m = document.querySelector('.card[data-id="chat/a"] .mfld [data-a=mic]'); return !!m && m.offsetParent !== null; })), 'one-line box with the cursor in it: the microphone is there');
  ok((await p.evaluate(() => { const f = document.querySelector('.card[data-id="chat/a"] .mfld'), m = f.querySelector('[data-a=mic]').getBoundingClientRect(), i = f.querySelector('.mi').getBoundingClientRect(), r = f.getBoundingClientRect(); return m.left - r.left < 6 && m.right <= i.left + 1; })), 'it is the first thing in the box, at the far left, before the text');
  { const n2 = await p.evaluate(() => window.__posts.length); await p.click('.card[data-id="chat/a"] .mfld [data-a=mic]'); await p.waitForTimeout(100);
    const r = await p.evaluate(n => ({ mic: window.__posts.slice(n).filter(m => m.type === 'mic' && m.id === 'chat/a' && m.box === 'mi').length, foc: document.activeElement.className.split(' ')[0] }), n2);
    ok(r.mic === 1 && r.foc === 'mi', 'a click on it asks the tray to listen for this box and leaves the cursor in the box (' + JSON.stringify(r) + ')'); }
  const say = async m => { await p.evaluate(m => window.__h({ data: m }), m); await p.waitForTimeout(100); };
  await say({ type: 'dict', st: 'rec', id: 'chat/a', box: 'mi' }); await p.evaluate(() => document.activeElement.blur()); await p.mouse.move(190, 400); await p.waitForTimeout(100);
  ok((await p.evaluate(() => { const m = document.querySelector('.card[data-id="chat/a"] .mfld .micb'); return m.classList.contains('rec') && m.offsetParent !== null && /Listening/.test(document.getElementById('toast').textContent); })), 'while it listens the microphone is red and stays in view, even with the cursor elsewhere');
  await p.click('.card[data-id="chat/a"] .mi'); { const n4 = await p.evaluate(() => window.__posts.length); await p.keyboard.press('Escape'); await p.waitForTimeout(80);
    ok((await p.evaluate(n => window.__posts.slice(n).filter(m => m.type === 'mic' && m.cancel === true).length, n4)) === 1, 'Esc while it listens tells the tray to drop the recording'); }
  await say({ type: 'dict', st: 'run', id: 'chat/a', box: 'mi' }); ok((await p.evaluate(() => document.querySelector('.card[data-id="chat/a"] .mfld .micb').classList.contains('run'))), 'then it shows that it is writing it down');
  await p.evaluate(() => { const i = document.querySelector('.card[data-id="chat/a"] .mi'); i.value = 'Note:'; i.focus(); i.setSelectionRange(5, 5); });
  await say({ type: 'dict', st: 'text', id: 'chat/a', box: 'mi', t: 'bonjour and hello' });
  ok((await p.evaluate(() => { const i = document.querySelector('.card[data-id="chat/a"] .mi'), m = document.querySelector('.card[data-id="chat/a"] .mfld .micb'); return i.value === 'Note: bonjour and hello' && document.activeElement === i && !m.classList.contains('rec') && !m.classList.contains('run'); })), 'the text lands at the cursor, after what was there, and the microphone is back to normal');
  await say({ type: 'dict', st: 'msg', t: 'Speech model: 40 %' }); ok((await p.evaluate(() => { const e = document.getElementById('toast'); return e.textContent === 'Speech model: 40 %' && e.classList.contains('on'); })), 'a note from the tray is shown');
  await p.evaluate(() => { const i = document.querySelector('.card[data-id="chat/a"] .mi'); i.value = ''; i.dispatchEvent(new Event('input', { bubbles: true })); });
  await p.evaluate(() => document.activeElement.blur()); await p.mouse.move(190, 400); await p.waitForTimeout(100);
  ok((await p.evaluate(() => { const m = document.querySelector('.card[data-id="chat/a"] .mfld [data-a=mic]'); return m.offsetParent === null; })), 'cursor elsewhere: no microphone on the line');
  await p.click('.card[data-id="chat/a"] .mdot'); await p.waitForTimeout(250);
  { const n3 = await p.evaluate(() => window.__posts.length); await p.click('.card[data-id="chat/a"] .cbox [data-a=mic]'); await p.waitForTimeout(100);
    const r = await p.evaluate(n => ({ mic: window.__posts.slice(n).filter(m => m.type === 'mic' && m.box === 'ta').length, foc: document.activeElement.tagName }), n3);
    ok(r.mic === 1 && r.foc === 'TEXTAREA', 'open chat: the microphone in the reply box does the same, cursor in the reply box (' + JSON.stringify(r) + ')'); }
  ok((await p.evaluate(() => { const f = document.querySelector('.card[data-id="chat/a"] .cbox'), m = f.querySelector('[data-a=mic]').getBoundingClientRect(), i = f.querySelector('textarea').getBoundingClientRect(), r = f.getBoundingClientRect(); return m.left - r.left < 7 && m.right <= i.left + 1; })), 'open chat: the microphone is at the far left of the reply box');
  if (process.argv[3]) await p.screenshot({ path: process.argv[3], clip: { x: 0, y: 0, width: 380, height: 200 } });
  await p.click('.card[data-id="chat/a"] .head'); await p.waitForTimeout(250); await p.evaluate(() => document.activeElement.blur());
  dictSt = 'off'; await push(); await p.click('.card[data-id="chat/b"] .mi'); await p.waitForTimeout(120);
  ok((await p.evaluate(() => document.activeElement.classList.contains('mi') && [...document.querySelectorAll('.micb')].every(m => m.offsetParent === null))), 'dictation off (the default): no microphone anywhere, even with the cursor in a box');
  dictSt = 'on'; await push(); ok((await p.evaluate(() => document.querySelector('.card[data-id="chat/b"] .mfld .micb').offsetParent !== null)), 'dictation on: the microphone is there');
  await p.evaluate(() => document.activeElement.blur());
  // window buttons
  const wb = () => p.evaluate(() => { const e = document.getElementById('wb'), r = e.getBoundingClientRect(), s = getComputedStyle(e); return { seen: s.display !== 'none' && +s.opacity > 0.9, n: e.querySelectorAll('button').length, top: document.getElementById('top').offsetHeight, right: Math.round(innerWidth - r.right), bottom: Math.round(r.bottom) }; });
  await p.mouse.move(190, 200); await p.waitForTimeout(250);
  let w = await wb(); ok(w.seen && w.n === 3 && w.top === 10 && w.right <= 4 && w.bottom <= 14, 'small panel, pointer over it: three window buttons at the top right, and the top strip is still 10 px (' + JSON.stringify(w) + ')');
  for (const act of ['min', 'frame', 'close']) { const n1 = await p.evaluate(() => window.__posts.length); await p.click('#wb button[data-wb=' + act + ']'); await p.waitForTimeout(60);
    const ps = await p.evaluate(n => window.__posts.slice(n).filter(m => m.type === 'win' || m.type === 'drag' || m.type === 'rsz'), n1); ok(ps.length === 1 && ps[0].type === 'win' && ps[0].a === act, 'the ' + act + ' button tells the tray, and does not start a move (' + JSON.stringify(ps) + ')'); }
  await push({ docked: true }); await p.mouse.move(190, 200); await p.waitForTimeout(250); w = await wb(); ok(w.seen && w.top === 10, 'pinned: the same (' + JSON.stringify(w) + ')');
  ok(errs.length === 0, 'no page errors ' + JSON.stringify(errs.slice(0, 3)));
  await b.close(); console.log(fails ? fails + ' FAILED' : 'ALL OK'); process.exit(fails ? 1 : 0);
})();
