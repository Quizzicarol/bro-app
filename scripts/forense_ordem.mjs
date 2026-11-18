// Forense genérica de ordem: node forense_ordem.mjs <orderId>
// Puxa 30078/30079/30080/30081 por #d (variantes) + #r + #orderId em todos os
// relays da app, ordena cronologicamente e mostra payload-chave de cada evento.
import WebSocket from 'ws';
const orderId = process.argv[2];
if (!orderId) { console.error('uso: node forense_ordem.mjs <orderId>'); process.exit(1); }
const relays = [
  'wss://apexcord.duckdns.org',
  'wss://bro-relay2.fly.dev',
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.nostr.band',
  'wss://nostr.mom',
];
function query(relay, filter, t = 15000) {
  return new Promise((res) => {
    const ws = new WebSocket(relay); const r = []; const s = 'q' + Math.random().toString(36).slice(2, 8);
    const to = setTimeout(() => { try { ws.close(); } catch {} res(r); }, t);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', s, filter])));
    ws.on('message', (d) => { try { const m = JSON.parse(d.toString()); if (m[0] === 'EVENT' && m[1] === s) r.push(m[2]); else if (m[0] === 'EOSE' && m[1] === s) { clearTimeout(to); try { ws.close(); } catch {} res(r); } } catch {} });
    ws.on('error', () => { clearTimeout(to); res(r); });
  });
}
const dTags = [orderId, `${orderId}_accept`, `${orderId}_complete`, `${orderId}_invoice_refresh`];
const all = [];
for (const r of relays) {
  for (const d of dTags) {
    const evs = await query(r, { kinds: [30078, 30079, 30080, 30081], '#d': [d], limit: 50 });
    for (const e of evs) all.push({ ...e, _relay: r, _d: d });
  }
  for (const e of await query(r, { '#r': [orderId, orderId.slice(0, 8)], limit: 50 })) all.push({ ...e, _relay: r, _d: 'r-tag' });
  for (const e of await query(r, { '#orderId': [orderId], limit: 50 })) all.push({ ...e, _relay: r, _d: 'orderId-tag' });
}
// updates com d-tag por autor ({id}_{author8}_update / _billcode / _republish)
const seen = new Set();
// FILTRO CLIENT-SIDE ESTRITO (apexcord as vezes devolve eventos fora do filtro):
// só aceita evento cujo content.orderId == alvo OU com tag d/r/orderId exata.
function belongs(e) {
  const tags = e.tags || [];
  const d = tags.find(t => t[0] === 'd')?.[1] || '';
  if (d === orderId || d.startsWith(orderId + '_')) return true;
  if (tags.some(t => (t[0] === 'r' || t[0] === 'orderId') && t[1] === orderId)) return true;
  try { const c = JSON.parse(e.content); if (c.orderId === orderId) return true; } catch {}
  return false;
}
const u = all.filter((e) => { if (!belongs(e)) return false; if (seen.has(e.id)) return false; seen.add(e.id); return true; });
// ampla: tudo que menciona o orderId no #d de 30080
for (const r of relays.slice(0, 2)) {
  const evs = await query(r, { kinds: [30080], since: Math.floor(Date.now() / 1000) - 7 * 86400, limit: 500 });
  for (const e of evs) {
    const d = e.tags.find(t => t[0] === 'd')?.[1] || '';
    if (d.startsWith(orderId) && !seen.has(e.id)) { seen.add(e.id); u.push({ ...e, _relay: r, _d: d }); }
  }
}
u.sort((a, b) => a.created_at - b.created_at);
console.log(`Found ${u.length} unique events touching ${orderId}:\n`);
for (const ev of u) {
  let p = null; try { p = JSON.parse(ev.content); } catch {}
  const pTag = ev.tags.find(t => t[0] === 'p')?.[1];
  console.log(
    new Date(ev.created_at * 1000).toISOString(),
    'k=' + ev.kind,
    'len=' + ev.content.length,
    'type=' + (p?.type || (p ? '?' : 'ENC')),
    'status=' + (p?.status || ev.tags.find(t => t[0] === 'status')?.[1] || '?'),
    'from=' + ev.pubkey.slice(0, 8),
    '#p=' + (pTag ? pTag.slice(0, 8) : 'EMPTY'),
    p?.providerId ? 'prov=' + p.providerId.slice(0, 8) : '',
    p?.userPubkey ? 'user=' + p.userPubkey.slice(0, 8) : '',
    p?.appVersion ? 'v=' + p.appVersion : '',
    p?.providerInvoice ? '[INV]' : '',
    (p?.proofImage || p?.paymentProof || p?.proofImage_nip44) ? '[PROOF]' : '',
    p?.preimage ? '[PREIMAGE]' : '',
    'on=' + ev._relay.replace('wss://', ''),
  );
}
process.exit(0);
