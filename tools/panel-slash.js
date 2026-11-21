const { chromium } = require('playwright'); const path = require('path');
// tools/panel-slash.js - the "/" list of commands and skills in a reply box, without Windows:
//   it keeps its place while the panel is refreshed, the selected line stays in view, a skill is found by any part of its name.
//   node tools/panel-slash.js [screenshot.png]
const root = path.join(__dirname, '..');
let fails = 0; const ok = (c, m) => { console.log((c ? 'ok   ' : 'FAIL ') + m); if (!c) fails++; };
(async () => {
  const b = await chromium.launch(); const errs = [];
  const p = await b.newPage({ viewport: { width: 1371, height: 711 } });     // a panel that fills a 1920x1040 screen at 140%
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.addInitScript(() => { window.__posts = []; window.chrome = { webview: { postMessage: m => window.__posts.push(m), addEventListener: (t, f) => { window.__h = f; } } }; });
  await p.goto('file://' + path.join(root, 'ui', 'panel.html'));
  const theme = { bg: '#262624', card: '#30302e', tx: '#eeece2', mu: '#9a978d', ln: '#3b3a37', acc: '#d97757', act: '#6296d6', pur: '#7e6bc4', ok: '#6fa876', field: '#30302e', bub: '#1a1a18' };
  const msgs = [{ r: 'u', t: 'hello' }, { r: 'a', t: 'answer' }];
  const mk = (id, title, o) => Object.assign({ id, title, st: 'done', working: false, bell: true, age: '1h', preview: 'p', web: true, msgs, steps: [] }, o);
  const chats = [mk('chat/a', 'Alpha', { working: true }), mk('chat/b', 'Bravo')];
  const names = ['clear', 'compact', 'context', 'cost', 'help', 'init', 'model', 'review', 'security-review', 'skills', 'anthropic-skills:docx', 'anthropic-skills:pdf', 'anthropic-skills:tray', 'anthropic-skills:pc-runner', 'anthropic-skills:xlsx', 'usage'];
  let slash = null;
  const state = () => ({ type: 'state', theme, nc: false, docked: true, maxH: 700, expanded: ['chat/a'], big: ['chat/a'], err: '', usage: [], hiddenAll: true, sides: { roomL: true, roomR: true }, mainW: 1371, shown: true, chats, settings: { version: 'test' }, slash });
  const push = async () => { await p.evaluate(s => window.__h({ data: s }), state()); await p.waitForTimeout(120); };
  const lst = () => p.evaluate(() => { const e = document.getElementById('slp'); if (!e) return null; const on = e.querySelector('.si.on'), r = e.getBoundingClientRect(), o = on && on.getBoundingClientRect(); return { n: e.querySelectorAll('.si').length, top: e.scrollTop, on: on ? on.querySelector('b').textContent : '', seen: !!o && o.top >= r.top - 1 && o.bottom <= r.bottom + 1, h: Math.round(r.height), inView: r.top >= 0 && r.bottom <= innerHeight, names: [...e.querySelectorAll('.si b')].map(x => x.textContent) }; });
  await push(); await push();
  await p.evaluate(() => { const c = document.querySelector('.card[data-id="chat/a"]'); if (!c.classList.contains('open')) c.querySelector('.head').click(); }); await p.waitForTimeout(200);
  await p.click('.card[data-id="chat/a"] textarea'); await p.keyboard.type('/'); await p.waitForTimeout(150);
  ok((await p.evaluate(() => window.__posts.filter(m => m.type === 'slash').length)) >= 1 && (await p.evaluate(() => (document.getElementById('slp') || {}).textContent || '')).includes('loading'), 'typing "/" asks the tray for the commands and says it is loading');
  slash = { items: names.map(n => ({ n: '/' + n, d: 'What ' + n + ' does, in one line that can be fairly long when it is a skill of yours' })), err: '' }; await push();
  let l = await lst(); ok(l && l.n === 16 && l.inView, 'the 16 commands are listed, the list is inside the panel (' + JSON.stringify(l && { n: l.n, h: l.h, inView: l.inView }) + ')');
  for (let i = 0; i < 13; i++) await p.keyboard.press('ArrowDown'); await p.waitForTimeout(100);
  l = await lst(); ok(l.on === '/anthropic-skills:pc-runner' && l.seen, 'arrow down 13 times: the selected line is ' + l.on + ' and it is in view (' + l.seen + ', scrolled ' + l.top + ')');
  const top0 = l.top; await push(); await push(); l = await lst();
  ok(l.top === top0 && l.on === '/anthropic-skills:pc-runner' && l.seen, 'the panel refreshes (a chat is working): the list stays where it was (' + top0 + ' -> ' + l.top + ')');
  if (process.argv[2]) await p.screenshot({ path: process.argv[2] });
  await p.evaluate(() => { const e = document.getElementById('slp'); e.scrollTop = 0; e.dispatchEvent(new Event('scroll')); }); await push(); l = await lst();
  ok(l.top === 0, 'you scroll the list with the wheel: a refresh does not pull it back to the selected line (' + l.top + ')');
  await p.keyboard.press('Escape'); await p.evaluate(() => { const t = document.querySelector('.card[data-id="chat/a"] textarea'); t.value = ''; }); await p.keyboard.type('/pc-run'); await p.waitForTimeout(150);
  l = await lst(); ok(l && l.n === 1 && l.on === '/anthropic-skills:pc-runner', 'typing /pc-run finds the skill by the part after the colon (' + JSON.stringify(l && l.names) + ')');
  await p.evaluate(() => { const t = document.querySelector('.card[data-id="chat/a"] textarea'); t.value = ''; }); await p.keyboard.type('/skill'); await p.waitForTimeout(150);
  l = await lst(); ok(l && l.names[0] === '/skills' && l.n === 6, 'typing /skill lists /skills first, then the five skills (' + JSON.stringify(l && l.names) + ')');
  await p.evaluate(() => { const t = document.querySelector('.card[data-id="chat/a"] textarea'); t.value = ''; }); await p.keyboard.type('/pc'); await p.keyboard.press('Enter'); await p.waitForTimeout(150);
  ok((await p.evaluate(() => document.querySelector('.card[data-id="chat/a"] textarea').value)) === '/anthropic-skills:pc-runner ' && !(await lst()), 'Enter puts the full name in the box and closes the list');
  ok((await p.evaluate(() => window.__posts.filter(m => m.type === 'send').length)) === 0, 'and nothing is sent yet');
  // the read on the claude.ai page (the script the tray runs there): each row is "/" + an icon on its own line, then the name, then "," and a description
  const ps = require('fs').readFileSync(path.join(root, 'ClaudeTray.ps1'), 'utf8'), mx = /expression = "(\(\(\) => \{ const vis = [^\n]*?\}\)\(\))"; returnByValue/.exec(ps);
  ok(!!mx, 'the page script is found in ClaudeTray.ps1');
  if (mx) {
    const row = t => ({ offsetParent: {}, innerText: t }), rows = [row('/\nAjouter des fichiers'), row('/​\nUtilisation\n,\nAfficher l’utilisation du forfait'), row('/📄\npc-runner'), row('/⌘ deep-research\nResearch a topic'), row('/clear\nClear the conversation'), row('morning')];
    const read = JSON.parse(new Function('document', 'return ' + mx[1].replace(/""/g, '"'))({ querySelectorAll: () => rows })).items;
    ok(JSON.stringify(read.map(o => o.n)) === '["Ajouter des fichiers","Utilisation","pc-runner","/deep-research","/clear","morning"]', 'names are read without the "/" marker line or its icon (' + JSON.stringify(read.map(o => o.n)) + ')');
    ok(read[1].d === 'Afficher l’utilisation du forfait' && read[2].d === '' && read[3].d === 'Research a topic', 'descriptions come without the lone comma (' + JSON.stringify(read.map(o => o.d)) + ')');
  }
  ok(errs.length === 0, 'no page errors ' + JSON.stringify(errs.slice(0, 3)));
  await b.close(); console.log(fails ? fails + ' FAILED' : 'ALL OK'); process.exit(fails ? 1 : 0);
})();
