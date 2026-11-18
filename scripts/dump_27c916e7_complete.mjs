// Dump da ESTRUTURA do bro_complete da ordem 27c916e7 (sem vazar a imagem inteira)
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
const evs = await query('wss://apexcord.duckdns.org', { kinds: [30081], '#d': [`${orderId}_complete`], limit: 5 });
for (const ev of evs) {
  const c = JSON.parse(ev.content);
  console.log('event id:', ev.id, 'created:', new Date(ev.created_at * 1000).toISOString());
  console.log('JSON keys + tamanhos:');
  for (const [k, v] of Object.entries(c)) {
    const len = typeof v === 'string' ? v.length : JSON.stringify(v)?.length;
    let preview = typeof v === 'string' && v.length < 90 ? v : '';
    console.log(`  ${k}: len=${len} ${preview}`);
  }
}
process.exit(0);
