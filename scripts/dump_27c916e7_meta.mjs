// Dump do 30078 (republish do usuario) e 30080 (billcode) — procurar metadados
// de versao/plataforma do app do USUARIO e o estado que o app dele acha que esta.
import WebSocket from 'ws';
const orderId = '27c916e7-887d-44fa-a90d-670287cb1a4b';
function query(relay, filter, t = 15000) {
  return new Promise((res) => {
    const ws = new WebSocket(relay); const r = []; const s = 'q' + Math.random().toString(36).slice(2, 8);
    const to = setTimeout(() => { try { ws.close(); } catch {} res(r); }, t);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', s, filter])));
    ws.on('message', (d) => { try { const m = JSON.parse(d.toString()); if (m[0] === 'EVENT' && m[1] === s) r.push(m[2]); else if (m[0] === 'EOSE' && m[1] === s) { clearTimeout(to); try { ws.close(); } catch {} res(r); } } catch {} });
    ws.on('error', () => { clearTimeout(to); res(r); });
  });
}
const order = await query('wss://apexcord.duckdns.org', { kinds: [30078], '#d': [orderId], limit: 5 });
for (const ev of order) {
  console.log('=== 30078 order (author', ev.pubkey.slice(0, 8) + ') created', new Date(ev.created_at * 1000).toISOString(), '===');
  try { console.log(JSON.stringify(JSON.parse(ev.content), null, 2)); } catch { console.log(ev.content.slice(0, 400)); }
}
const upd = await query('wss://apexcord.duckdns.org', { kinds: [30080], '#r': [orderId], limit: 10 });
for (const ev of upd) {
  console.log('\n=== 30080 (author', ev.pubkey.slice(0, 8) + ') created', new Date(ev.created_at * 1000).toISOString(), '===');
  const c = (() => { try { return JSON.parse(ev.content); } catch { return null; } })();
  if (c) { for (const [k, v] of Object.entries(c)) { const s = String(v); console.log(`  ${k}: ${s.length > 100 ? s.slice(0, 100) + '…(len=' + s.length + ')' : s}`); } }
  else console.log('ENC len=' + ev.content.length);
  console.log('  tags:', JSON.stringify(ev.tags));
}
// updates com d-tag por autor (caminho normal dos 30080)
for (const sfx of ['_update']) {
  const evs = await query('wss://apexcord.duckdns.org', { kinds: [30080], limit: 200, since: Math.floor(Date.now() / 1000) - 86400 });
  const mine = evs.filter(e => (e.tags.find(t => t[0] === 'd')?.[1] || '').startsWith(orderId));
  console.log('\n30080 com #d={orderId}_*_update nas ultimas 24h:', mine.length);
  for (const e of mine) console.log(' ', new Date(e.created_at * 1000).toISOString(), e.tags.find(t => t[0] === 'd')?.[1], 'author', e.pubkey.slice(0, 8));
}
process.exit(0);
