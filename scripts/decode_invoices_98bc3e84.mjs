// Decodifica as 3 invoices da ordem 98bc3e84: A (complete 19:40), B (refresh
// do vencedor 21:11), C (refresh do PERDEDOR 21:20) — pra onde iam os sats?
import WebSocket from 'ws';
import { decode } from 'file:///C:/Users/produ/Documents/GitHub/bro_app/backend/node_modules/light-bolt11-decoder/bolt11.js';
const orderId = '98bc3e84-d01f-44c2-b215-31fbd09d7508';
function query(relay, filter, t = 15000) {
  return new Promise((res) => {
    const ws = new WebSocket(relay); const r = []; const s = 'q' + Math.random().toString(36).slice(2, 8);
    const to = setTimeout(() => { try { ws.close(); } catch {} res(r); }, t);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', s, filter])));
    ws.on('message', (d) => { try { const m = JSON.parse(d.toString()); if (m[0] === 'EVENT' && m[1] === s) r.push(m[2]); else if (m[0] === 'EOSE' && m[1] === s) { clearTimeout(to); try { ws.close(); } catch {} res(r); } } catch {} });
    ws.on('error', () => { clearTimeout(to); res(r); });
  });
}
const evs = [
  ...(await query('wss://apexcord.duckdns.org', { kinds: [30081], '#d': [`${orderId}_complete`], limit: 5 })),
  ...(await query('wss://apexcord.duckdns.org', { kinds: [30081], '#d': [`${orderId}_invoice_refresh`], limit: 10 })),
];
const seen = new Set();
for (const ev of evs) {
  if (seen.has(ev.id)) continue; seen.add(ev.id);
  const c = JSON.parse(ev.content);
  const inv = c.providerInvoice;
  if (!inv) continue;
  console.log('---', c.type, 'por', ev.pubkey.slice(0, 8), 'às', new Date(ev.created_at * 1000).toISOString(), '---');
  try {
    const dec = decode(inv);
    const ts = dec.sections.find(s => s.name === 'timestamp')?.value;
    const expiry = dec.sections.find(s => s.name === 'expiry')?.value ?? 3600;
    const amount = dec.sections.find(s => s.name === 'amount')?.value;
    const ph = dec.sections.find(s => s.name === 'payment_hash')?.value;
    const dest = dec.sections.find(s => s.name === 'destination')?.value;
    const desc = dec.sections.find(s => s.name === 'description')?.value;
    console.log('  sats:', amount ? Number(amount) / 1000 : '?', '| desc:', desc || '(sem)');
    console.log('  criada:', new Date(ts * 1000).toISOString(), '| expira:', new Date((ts + expiry) * 1000).toISOString(), `(${expiry}s)`);
    console.log('  payment_hash:', ph);
    console.log('  destination:', dest);
  } catch (e) { console.log('  decode FAIL:', e.message); }
}
process.exit(0);
