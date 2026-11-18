// O app manda #d em LOTES de 15 valores. Se o apexcord (relay custom) trata
// mal filtro #d multi-valor (ou corta resposta grande), o complete de 60KB
// nunca chega no lote — mas chega sozinho. Testar o formato EXATO da query.
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
// Simula um usuario com 15 ordens ativas: 14 ficticias + a real no MEIO do lote
const fake = Array.from({ length: 14 }, (_, i) => `00000000-0000-0000-0000-${String(i).padStart(12, '0')}_complete`);
const batch = [...fake.slice(0, 7), `${orderId}_complete`, ...fake.slice(7)];
const batchAccept = batch.map(d => d.replace('_complete', '_accept'));

for (const relay of ['wss://apexcord.duckdns.org', 'wss://bro-relay2.fly.dev']) {
  const gotC = await query(relay, { kinds: [30081], '#d': batch, limit: 50 });
  const gotA = await query(relay, { kinds: [30079], '#d': batchAccept, limit: 50 });
  console.log(relay);
  console.log('  lote #d 15x _complete ->', gotC.length, 'evento(s); contém o real:', gotC.some(e => e.tags.some(t => t[0] === 'd' && t[1] === `${orderId}_complete`)));
  console.log('  lote #d 15x _accept   ->', gotA.length, 'evento(s); contém o real:', gotA.some(e => e.tags.some(t => t[0] === 'd' && t[1] === `${orderId}_accept`)));
}
process.exit(0);
