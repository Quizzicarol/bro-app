// Forense: ordem 27c916e7-887d-44fa-a90d-670287cb1a4b — usuario atualizou o app,
// recebeu Pix + notificacao do comprovante, mas o app nao mostra o comprovante
// e trava na etapa 2 ("aguardando comprovante do parceiro").
// Hipoteses: (1) evento 30081 complete substituido por write posterior sem prova
// (replaceable!), (2) prova corrompida na origem (build iOS antigo, 24-32 bytes),
// (3) #p vazio e app sem fix v813/v815 (ele disse que atualizou), (4) retenção do relay.
import WebSocket from 'ws';
const orderId = '27c916e7-887d-44fa-a90d-670287cb1a4b';
const relays = [
  'wss://apexcord.duckdns.org',
  'wss://bro-relay2.fly.dev',
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
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
}
const seen = new Set();
const u = all.filter((e) => { if (seen.has(e.id)) return false; seen.add(e.id); return true; });
u.sort((a, b) => a.created_at - b.created_at);
console.log(`Found ${u.length} unique events touching this order:\n`);
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
    p?.providerInvoice ? '[INV]' : '',
    (p?.proofImage || p?.paymentProof) ? '[PROOF]' : '',
    'matched=' + ev._d,
    'on=' + ev._relay.replace('wss://', ''),
  );
}
// Detalhe do complete (se houver): tamanho do conteudo diz se a prova veio integra
const completes = u.filter(e => e.kind === 30081 && e._d === `${orderId}_complete`);
for (const c of completes) {
  console.log('\n=== COMPLETE event ' + c.id.slice(0, 16) + ' on ' + c._relay + ' ===');
  console.log('created_at:', new Date(c.created_at * 1000).toISOString(), 'pubkey:', c.pubkey.slice(0, 16));
  console.log('content.length:', c.content.length);
  console.log('content[:120]:', c.content.slice(0, 120));
  console.log('tags:', JSON.stringify(c.tags));
}
process.exit(0);
