const { chromium } = require('playwright'); const path = require('path');
// tools/panel-keys.js - keyboard and placements in the panel, without Windows:
//   Ctrl+1..9 / Ctrl+Tab switch chats (also in focus and on the status line), 'next chat that waits for you', number badges, the Shortcuts menu.
//   node tools/panel-keys.js
const root = path.join(__dirname, '..');
let fails = 0; const ok = (c, m) => { console.log((c ? 'ok   ' : 'FAIL ') + m); if (!c) fails++; };
(async () => {
  const b = await chromium.launch(); const errs = [];
  const p = await b.newPage({ viewport: { width: 380, height: 560 } });
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.addInitScript(() => { window.__posts = []; window.prompt = (t, d) => { window.__prompt = t; return window.__answer; }; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
  await p.goto('file://' + path.join(root, 'ui', 'panel.html'));
  const theme = { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757', act: '#6296d6', pur: '#7e6bc4', ok: '#6fa876', field: '#30302e', bub: '#1a1a18' };
  const msgs = [{ r: 'u', t: 'hello' }, { r: 'a', t: 'answer' }];
  const mk = (id, title, o) => Object.assign({ id, title, st: 'done', working: false, bell: true, age: '1h', preview: 'p', web: true, msgs, steps: [] }, o);
  const chats = [mk('chat/a', 'Alpha'), mk('chat/b', 'Bravo', { unread: true }), mk('chat/c', 'Charlie', { working: true }), mk('chat/d', 'Delta', { st: 'act', steps: [{ n: 1, kind: 'manual', label: 'Do it' }] }), mk('chat/e', 'Echo')];
  const settings = { hot: { toggle: { keys: 'Ctrl+Alt+Space', st: 'ok' }, place: { keys: 'Ctrl+Alt+P', st: 'taken' }, home: { keys: '', st: 'off' }, next: { keys: 'Ctrl+Alt+N', st: 'ok' } }, places: ['500 x 457', '340 x auto'], place: 1, version: 'test' };
  const state = () => ({ type: 'state', theme, nc: false, docked: true, maxH: 520, expanded: [], big: [], err: '', usage: [], hiddenAll: true, sides: { roomL: true, roomR: true }, mainW: 380, shown: true, chats, settings });
  const push = async () => { await p.evaluate(s => window.__h({ data: s }), state()); await p.waitForTimeout(120); };
  const send = async m => { await p.evaluate(s => window.__h({ data: s }), m); await p.waitForTimeout(150); };
  const open = () => p.evaluate(() => [...document.querySelectorAll('.card.open')].filter(c => c.offsetParent !== null).map(c => c.dataset.id));
  const foc = () => p.evaluate(() => { const a = document.activeElement, c = a && a.closest && a.closest('.card'); return (c ? c.dataset.id : '-') + ':' + (a ? a.tagName : ''); });
  await push(); await push();
  await p.click('body', { position: { x: 5, y: 5 } }).catch(() => { });
  await p.keyboard.press('Control+Digit2'); await p.waitForTimeout(200);
  ok(JSON.stringify(await open()) === '["chat/b"]' && (await foc()) === 'chat/b:TEXTAREA', 'Ctrl+2 opens the second chat, cursor in its reply box (' + JSON.stringify(await open()) + ' ' + (await foc()) + ')');
  await p.keyboard.press('Control+Digit2'); await p.waitForTimeout(200);
  ok(JSON.stringify(await open()) === '["chat/b"]', 'Ctrl+2 again keeps it open');
  await p.keyboard.type('draft'); await p.keyboard.press('Control+Tab'); await p.waitForTimeout(200);
  ok(JSON.stringify(await open()) === '["chat/c"]' && (await foc()) === 'chat/c:TEXTAREA', 'Ctrl+Tab goes to the next chat, even from a reply box (' + JSON.stringify(await open()) + ')');
  await p.keyboard.press('Control+Shift+Tab'); await p.keyboard.press('Control+Shift+Tab'); await p.waitForTimeout(250);
  ok(JSON.stringify(await open()) === '["chat/a"]', 'Ctrl+Shift+Tab twice goes back two (' + JSON.stringify(await open()) + ')');
  await p.keyboard.press('Control+Shift+Tab'); await p.waitForTimeout(200);
  ok(JSON.stringify(await open()) === '["chat/e"]', 'and wraps round to the last one');
  await p.keyboard.press('Control+Digit9'); await p.waitForTimeout(150);
  ok(JSON.stringify(await open()) === '["chat/e"]', 'Ctrl+9 with five chats does nothing');
  const draft = await p.evaluate(() => { const c = document.querySelector('.card[data-id="chat/b"] textarea'); return c ? c.value : null; });
  ok(draft === 'draft', 'the text typed in chat 2 is still there (' + JSON.stringify(draft) + ')');
  // digits alone still type
  await p.keyboard.press('Control+Digit1'); await p.waitForTimeout(150); await p.keyboard.type('12'); 
  ok((await p.evaluate(() => document.activeElement.value)) === '12', 'plain digits are typed into the reply box');
  // ...and outside a text box, 1-9 alone switch chats
  await p.evaluate(() => { document.activeElement.blur(); }); await p.keyboard.press('Digit3'); await p.waitForTimeout(250);
  ok(JSON.stringify(await open()) === '["chat/c"]' && (await foc()) === 'chat/c:TEXTAREA', 'with the cursor in no box, 3 alone opens the third chat (' + JSON.stringify(await open()) + ' ' + (await foc()) + ')');
  await p.keyboard.press('Digit1'); await p.waitForTimeout(200);
  ok(JSON.stringify(await open()) === '["chat/c"]' && (await p.evaluate(() => document.activeElement.value)) === '1', 'once the cursor is in a reply box, 1 is typed, the chat does not change');
  await p.evaluate(() => { document.activeElement.value = ''; }); await p.keyboard.press('Control+Digit1'); await p.waitForTimeout(200); await p.evaluate(() => { document.activeElement.value = '12'; });
  // next chat that waits for you: b (new reply) and d (steps); c is working, a / e idle
  await send({ type: 'key', k: 'next' }); ok(JSON.stringify(await open()) === '["chat/b"]', "'next that waits' from chat 1 -> the unread one (" + JSON.stringify(await open()) + ')');
  await send({ type: 'key', k: 'next' }); ok(JSON.stringify(await open()) === '["chat/d"]', 'again -> the one with steps');
  await send({ type: 'key', k: 'next' }); ok(JSON.stringify(await open()) === '["chat/b"]', 'again -> wraps to the first that waits');
  chats[1].unread = false; chats[3].st = 'done'; chats[3].steps = []; await push();
  await send({ type: 'key', k: 'next' }); ok((await p.evaluate(() => { const t = document.getElementById('toast'); return t && t.classList.contains('on') ? t.textContent : ''; })) === 'Nothing waits for you', 'nothing waits: says so');
  // each line carries its number, faint, always
  const kn = () => p.evaluate(() => [...document.querySelectorAll('#pins .card, #list .card')].map(c => { const e = [...c.querySelectorAll('.mdot, .head')].find(x => x.offsetParent !== null); const cs = e ? getComputedStyle(e, '::before') : null; return (e ? e.getAttribute('data-kn') : '-') + (cs && cs.content.replace(/"/g, '') === e.getAttribute('data-kn') && +cs.opacity < 0.7 && parseFloat(cs.fontSize) < 9 ? '' : '!'); }).join(''));
  ok((await kn()) === '12345', 'every chat line shows its number, small and faint, open or closed (' + (await kn()) + ')');
  await p.screenshot({ path: path.join(root, 'logs', 'keys-numbers.png') }).catch(() => { });
  const w0 = await p.evaluate(() => { const c = document.querySelector('.card:not(.open) .mini'); const r = c.getBoundingClientRect(); return Math.round(r.left) + ',' + Math.round(r.width); });
  ok(w0 === '5,370', 'and takes no room from the line (' + w0 + ')');
  chats.unshift(chats.pop()); await push(); await p.evaluate(() => { dirtyView = true; render(); }).catch(() => { }); 
  const ord = await p.evaluate(() => [...document.querySelectorAll('#pins .card, #list .card')].map(c => c.dataset.id.slice(-1) + ([...c.querySelectorAll('.mdot, .head')].find(x => x.offsetParent !== null) || { getAttribute: () => '' }).getAttribute('data-kn')).join(' '));
  ok(/^\w1 \w2 \w3 \w4 \w5$/.test(ord), 'numbers follow the order on screen (' + ord + ')');
  chats.push(chats.shift()); await push(); await p.evaluate(() => { dirtyView = true; render(); }).catch(() => { });
  const back = await p.evaluate(() => [...document.querySelectorAll('#pins .card, #list .card')].map(c => c.dataset.id.slice(-1)).join(''));
  // focus mode: Ctrl+3 moves the focus
  await p.evaluate(() => setFocus('chat/a')); await p.waitForTimeout(200);
  await p.keyboard.press('Control+Digit3'); await p.waitForTimeout(250);
  ok((await p.evaluate(() => focusId)) === 'chat/c' && JSON.stringify(await open()) === '["chat/c"]', 'in focus mode Ctrl+3 focuses the third chat');
  await p.keyboard.press('Control+Tab'); await p.waitForTimeout(250);
  ok((await p.evaluate(() => focusId)) === 'chat/d', 'and Ctrl+Tab the next');
  await p.evaluate(() => setFocus(focusId)); await p.waitForTimeout(150);
  // status line: Ctrl+1 comes back to the panel on that chat
  await p.evaluate(() => setStrip(true)); await p.waitForTimeout(200);
  await p.keyboard.press('Control+Digit1'); await p.waitForTimeout(300);
  ok((await p.evaluate(() => stripOn)) === false && JSON.stringify(await open()) === '["chat/a"]', 'on the status line Ctrl+1 brings the panel back on the first chat');
  // the Shortcuts and placements menu
  await p.evaluate(() => keysMenu(10, 10, false)); await p.waitForTimeout(150);
  const items = await p.evaluate(() => [...document.querySelectorAll('#pmenu .pmi')].map(e => e.textContent));
  console.log('   menu: ' + JSON.stringify(items));
  ok(items[0] === 'Show / hide the panel: Ctrl+Alt+Space' && items[1] === 'Next placement: Ctrl+Alt+P (taken by another app)' && items[2] === 'Default placement (near the tray): off', 'the menu lists each shortcut with its keys and state');
  ok(items.includes('✓ Placement 1 (500 x 457)') && items.includes('Placement 2 (340 x auto)') && items.includes('Default (near the tray)') && items.includes('+ New placement where the panel is now') && items.includes('Forget placement 1'), 'and the placements, the one in use ticked');
  const clickItem = async t => { await p.evaluate(() => keysMenu(10, 10, false)); await p.waitForTimeout(100); await p.evaluate(tx => { const e = [...document.querySelectorAll('#pmenu .pmi')].find(x => x.textContent.replace('✓ ', '') === tx); e.dispatchEvent(new MouseEvent('mousedown', { bubbles: true })); e.dispatchEvent(new MouseEvent('mouseup', { bubbles: true })); e.click(); }, t); await p.waitForTimeout(150); };
  const lastAct = () => p.evaluate(() => window.__posts.filter(m => m.type === 'menuact').pop());
  await clickItem('Placement 2 (340 x auto)'); let la = await lastAct(); ok(la && la.k === 'place' && la.v === 2, 'click a placement -> the tray is asked to go there (' + JSON.stringify(la) + ')');
  await clickItem('Default (near the tray)'); la = await lastAct(); ok(la && la.k === 'place' && la.v === 0, 'default -> place 0');
  await clickItem('+ New placement where the panel is now'); la = await lastAct(); ok(la && la.k === 'placenew', 'new placement');
  await clickItem('Forget placement 1'); la = await lastAct(); ok(la && la.k === 'placedel' && la.v === 1, 'forget the one in use');
  await p.evaluate(() => { window.__answer = ' win+shift+c '; }); await clickItem('Show / hide the panel: Ctrl+Alt+Space'); la = await lastAct();
  ok(la && la.k === 'hotkey' && la.v === 'toggle' && la.t === 'win+shift+c', 'changing a shortcut sends the new keys (' + JSON.stringify(la) + ')');
  const n0 = await p.evaluate(() => window.__posts.filter(m => m.type === 'menuact').length);
  await p.evaluate(() => { window.__answer = null; }); await clickItem('Next chat that waits for you: Ctrl+Alt+N');
  ok((await p.evaluate(() => window.__posts.filter(m => m.type === 'menuact').length)) === n0, 'cancelling the box changes nothing');
  await send({ type: 'key', k: 'toast', t: 'Placement 2 of 3' });
  ok((await p.evaluate(() => document.getElementById('toast').textContent)) === 'Placement 2 of 3', 'the tray can show a short note');
  ok(errs.length === 0, 'no page errors ' + JSON.stringify(errs.slice(0, 3)));
  await b.close(); console.log(fails ? fails + ' FAILED' : 'ALL OK'); process.exit(fails ? 1 : 0);
})();
