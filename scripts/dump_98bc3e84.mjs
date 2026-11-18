// Dump detalhado da ordem 98bc3e84: 30078 (estado), complete do vencedor,
// e TODAS as invoices (complete + refreshes) pra rastrear pra onde foram os sats.
import WebSocket from 'ws';
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
const belongs = (e) => {
  const d = e.tags.find(t => t[0] === 'd')?.[1] || '';
  if (d === orderId || d.startsWith(orderId + '_')) return true;
  if (e.tags.some(t => (t[0] === 'r' || t[0] === 'orderId') && t[1] === orderId)) return true;
  try { return JSON.parse(e.content).orderId === orderId; } catch { return false; }
};
const relays = ['wss://apexcord.duckdns.org', 'wss://bro-relay2.fly.dev', 'wss://relay.primal.net'];
const all = [];
for (const r of relays) {
  for (const d of [orderId, `${orderId}_accept`, `${orderId}_complete`, `${orderId}_invoice_refresh`]) {
    for (const e of await query(r, { kinds: [30078, 30079, 30080, 30081], '#d': [d], limit: 20 })) all.push({ ...e, _relay: r });
  }
  for (const e of await query(r, { '#r': [orderId], limit: 20 })) all.push({ ...e, _relay: r });
}
const seen = new Set();
const evs = all.filter(e => belongs(e) && !seen.has(e.id) && seen.add(e.id));
evs.sort((a, b) => a.created_at - b.created_at);

for (const ev of evs) {
  const c = (() => { try { return JSON.parse(ev.content); } catch { return null; } })();
  console.log('===', new Date(ev.created_at * 1000).toISOString(), 'k=' + ev.kind, 'author=' + ev.pubkey.slice(0, 8), c?.type || 'ENC', '===');
  if (!c) { console.log('  (conteudo cifrado, len=' + ev.content.length + ')'); continue; }
  for (const [k, v] of Object.entries(c)) {
    const s = String(v ?? '');
    if (k === 'proofImage' || k === 'proofImage_nip44' || k === 'billCode_nip44') {
      console.log(`  ${k}: <${s.length} chars>`);
    } else if (k === 'providerInvoice' || k === 'invoice') {
      console.log(`  ${k}: ${s.slice(0, 60)}... (len=${s.length})`);
    } else if (s.length <= 110) {
      console.log(`  ${k}: ${s}`);
    } else {
      console.log(`  ${k}: <len=${s.length}>`);
    }
  }
}
process.exit(0);
