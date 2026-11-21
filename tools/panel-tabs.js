const { chromium } = require('playwright'); const path = require('path');
// tools/panel-tabs.js - the Tabs layout (Settings > Layout: tabs), without Windows:
//   a row of tabs, one chat selected and shown below, switching by click and keys, down to the row of tabs and back, BROWSE, back to the list.
//   node tools/panel-tabs.js [screenshot.png]
const root = path.join(__dirname, '..');
let fails = 0; const ok = (c, m) => { console.log((c ? 'ok   ' : 'FAIL ') + m); if (!c) fails++; };
(async () => {
  const b = await chromium.launch(); const errs = [];
  const p = await b.newPage({ viewport: { width: 420, height: 520 }, deviceScaleFactor: process.argv[2] ? 2 : 1 });
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.addInitScript(() => { window.__posts = []; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
  await p.goto('file://' + path.join(root, 'ui', 'panel.html'));
  const theme = { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757', act: '#6296d6', pur: '#7e6bc4', ok: '#6fa876', field: '#30302e', bub: '#1a1a18' };
  const mk = (id, title, o) => Object.assign({ id, title, st: 'done', working: false, bell: true, age: '5m', preview: 'last line', web: true, msgs: [{ r: 'u', t: 'hello' }, { r: 'a', t: 'answer from ' + title }], steps: [] }, o);
  let chats = [mk('chat/a', 'Alpha'), mk('chat/b', 'Bravo'), mk('chat/c', 'Charlie', { working: true }), mk('chat/d', 'Delta', { st: 'act', steps: [{ n: 1, kind: 'manual', label: 'Do it' }] }), mk('chat/e', 'Echo')];
  const state = () => ({ type: 'state', theme, nc: false, docked: true, maxH: 520, expanded: [], big: [], err: '', usage: [], hiddenAll: true, sides: { roomL: true, roomR: true }, mainW: 420, shown: true, chats, settings: { version: 'test' } });
  const push = async () => { await p.evaluate(s => window.__h({ data: s }), state()); await p.waitForTimeout(130); };
  const view = () => p.evaluate(() => { const vis = e => e && e.offsetParent !== null; const t = [...document.querySelectorAll('#tabs .tab')];
    return { tabs: vis(document.getElementById('tabs')) ? t.map(x => x.querySelector('b').textContent) : null, on: t.filter(x => x.classList.contains('on')).map(x => x.dataset.tid), cards: [...document.querySelectorAll('.card')].filter(vis).map(c => c.dataset.id), open: [...document.querySelectorAll('.card.open')].filter(vis).map(c => c.dataset.id), back: [...document.querySelectorAll('.fback')].filter(vis).length, strip: document.body.classList.contains('strip'), fit: t.every(x => x.getBoundingClientRect().right <= innerWidth + 1) }; });
  const item = async t => { await p.click('#gear'); await p.waitForTimeout(120); await p.evaluate(t => { const i = [...document.querySelectorAll('#pmenu *')].filter(e => e.children.length === 0 && e.textContent.trim().replace(/^✓\s*/, '') === t)[0]; if (!i) throw new Error('no menu item ' + t); i.click(); }, t); await p.waitForTimeout(200); };
  await push(); await push();
  let v = await view(); ok(v.tabs === null && v.cards.length === 5, 'list layout (default): no tabs, five lines (' + JSON.stringify(v.cards) + ')');
  await item('Layout: tabs'); await push(); v = await view();
  ok(JSON.stringify(v.tabs) === '["Alpha","Bravo","Charlie","Delta","Echo"]' && v.fit, 'Layout: tabs - one tab per chat, in the list\'s order (' + JSON.stringify(v.tabs) + ')');
  ok(JSON.stringify(v.on) === '["chat/d"]' && JSON.stringify(v.cards) === '["chat/d"]' && JSON.stringify(v.open) === '["chat/d"]' && v.back === 0, 'the chat that waits for you is selected and shown alone, open, with no back arrow (' + JSON.stringify(v) + ')');
  await p.waitForTimeout(500);
  ok((await p.evaluate(() => { const l = window.__posts.filter(m => m.type === 'layout').slice(-1)[0]; return l && l.layout.tabs === true; })), 'the choice is kept by the tray (layout.tabs)');
  const tt = () => p.evaluate(() => { const vis = e => e && e.offsetParent !== null; return { heads: [...document.querySelectorAll('.card .head')].filter(vis).length, icons: [...document.querySelectorAll('#tabs .ttools .ib')].filter(vis).map(e => e.dataset.a), age: (document.querySelector('#tabs .ttools .age') || {}).textContent || '', op: +getComputedStyle(document.querySelector('#tabs .ttools .ib')).opacity, fit: document.querySelector('#tabs .ttools').getBoundingClientRect().right <= innerWidth }; });
  let ti = await tt(); ok(ti.heads === 0 && JSON.stringify(ti.icons) === '["open","web","mv","hide","bell","pinc"]' && ti.age === '5m' && ti.op === 0.5 && ti.fit, 'the title is not repeated under the tabs; the chat\'s icons and age are at the end of the row, faint, without hover (' + JSON.stringify(ti) + ')');
  { const n0 = await p.evaluate(() => window.__posts.length); await p.click('#tabs .ttools [data-a=bell]'); await p.waitForTimeout(100);
    ok((await p.evaluate(n => window.__posts.slice(n).filter(m => m.type === 'bell' && m.id === 'chat/d').length, n0)) === 1, 'an icon on the row acts on the selected chat (bell -> chat/d)'); }
  if (process.argv[2]) await p.screenshot({ path: process.argv[2], clip: { x: 0, y: 0, width: 420, height: 200 } });
  await p.click('#tabs .tab[data-tid="chat/b"]'); await p.waitForTimeout(200); v = await view();
  ok(JSON.stringify(v.on) === '["chat/b"]' && JSON.stringify(v.open) === '["chat/b"]', 'a click on a tab shows that chat (' + JSON.stringify(v.on) + ')');
  await p.keyboard.press('Control+Tab'); await p.waitForTimeout(200); v = await view(); ok(JSON.stringify(v.on) === '["chat/c"]', 'Ctrl+Tab: the next tab (' + JSON.stringify(v.on) + ')');
  await p.keyboard.press('Control+Digit5'); await p.waitForTimeout(200); v = await view(); ok(JSON.stringify(v.on) === '["chat/e"]', 'Ctrl+5: the fifth tab (' + JSON.stringify(v.on) + ')');
  await push(); v = await view(); ok(JSON.stringify(v.on) === '["chat/e"]' && JSON.stringify(v.open) === '["chat/e"]', 'a refresh from the tray keeps your tab (' + JSON.stringify(v.on) + ')');
  await p.click('#rctb'); await p.waitForTimeout(250); v = await view();
  ok(v.cards.length === 5 && v.on.length === 0 && (await p.evaluate(() => !document.querySelector('#tabs .ttools'))), 'the "recent chats" button shows the list (no tab selected) (' + v.cards.length + ' lines)');
  await p.click('#tabs .tab[data-tid="chat/e"]'); await p.waitForTimeout(250); v = await view(); ok(JSON.stringify(v.on) === '["chat/e"]' && v.cards.length === 1, 'and a tab brings its chat back (' + JSON.stringify(v.on) + ')');
  await p.click('#rctb').catch(() => { }); await p.waitForTimeout(150); await p.click('#tabs .tab[data-tid="chat/e"]'); await p.waitForTimeout(200);
  // the grip: down to the row of tabs, and back
  await p.evaluate(() => foldAll()); await p.waitForTimeout(200); v = await view();
  ok(v.strip && v.tabs && v.tabs.length === 5 && v.cards.length === 0 && v.on.length === 0, 'collapse: only the row of tabs is left (' + JSON.stringify({ strip: v.strip, tabs: v.tabs && v.tabs.length, cards: v.cards }) + ')');
  await p.click('#tabs .tab[data-tid="chat/a"]'); await p.waitForTimeout(250); v = await view();
  ok(!v.strip && JSON.stringify(v.on) === '["chat/a"]' && JSON.stringify(v.open) === '["chat/a"]', 'a tab brings the panel back on that chat (' + JSON.stringify(v.on) + ' ' + JSON.stringify(v.open) + ')');
  // the selected chat leaves the tray
  chats = chats.filter(c => c.id !== 'chat/a'); await push(); await push(); v = await view();
  ok(v.tabs.length === 4 && v.on.length === 1 && v.open.length === 1 && v.on[0] === v.open[0], 'the selected chat leaves the tray: another one is selected (' + JSON.stringify(v.on) + ')');
  // many chats: the titles shrink, the tabs stay inside the panel
  const few = chats; chats = chats.concat(Array.from({ length: 11 }, (x, i) => mk('chat/x' + i, 'Extra chat number ' + i))); await push(); await push(); v = await view();
  ok(v.tabs.length === 15 && v.fit, '15 chats: all tabs stay inside the panel (' + v.tabs.length + ', fit ' + v.fit + ')');
  chats = few; await push(); await push();
  // back to the list
  await item('Layout: list'); await push(); v = await view();
  ok(v.tabs === null && v.cards.length === 4, 'Layout: list - the list is back, no tabs (' + JSON.stringify(v.cards) + ')');
  await p.click('.card[data-id="chat/b"] .mdot'); await p.waitForTimeout(250);
  ok((await p.evaluate(() => { const h = document.querySelector('.card[data-id="chat/b"] .head'); return !!h && h.offsetParent !== null && h.textContent.includes('Bravo'); })), 'list layout: an open chat has its title line as before');
  ok(errs.length === 0, 'no page errors ' + JSON.stringify(errs.slice(0, 3)));
  await b.close(); console.log(fails ? fails + ' FAILED' : 'ALL OK'); process.exit(fails ? 1 : 0);
})();
