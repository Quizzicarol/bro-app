// v823c: CERTIFICAÇÃO DE ENTREGA ponta-a-ponta — node verify_delivery.mjs <orderId>
//
// Responde "as duas pontas receberam?" sem perguntar a ninguém:
//  A) invoice do provedor (evento complete) → payment_hash esperado
//  B) update completed do COMPRADOR com paymentProof=<preimage 64-hex>
//     → sha256(preimage) == payment_hash? (prova criptográfica de pagamento)
//  C) update do PROVEDOR com receiptOf=provider_payment (paymentProof='received:<hash>')
//     → a ponta recebedora confirmou com a própria chave
//
// Veredicto: DELIVERED (B+C) | PAID_PROOF_ONLY (só B) | RECEIPT_ONLY (só C) | NO_PROOF
// Funciona só pra ordens com o mecanismo v823 (build 823+). Ordens antigas
// (paymentProof sempre null) saem como NO_PROOF mesmo quando pagas — esperado.
import WebSocket from 'ws';
import { createHash } from 'crypto';
import { decode } from 'file:///C:/Users/produ/Documents/GitHub/bro_app/backend/node_modules/light-bolt11-decoder/bolt11.js';

const orderId = process.argv[2];
if (!orderId) { console.error('uso: node verify_delivery.mjs <orderId>'); process.exit(1); }

const relays = ['wss://apexcord.duckdns.org', 'wss://bro-relay2.fly.dev', 'wss://relay.primal.net'];
function query(relay, filter, t = 10000) {
  return new Promise((res) => {
    const ws = new WebSocket(relay); const r = []; const s = 'q' + Math.random().toString(36).slice(2, 8);
    const to = setTimeout(() => { try { ws.close(); } catch {} res(r); }, t);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', s, filter])));
    ws.on('message', (d) => { try { const m = JSON.parse(d.toString()); if (m[0] === 'EVENT' && m[1] === s) r.push(m[2]); else if (m[0] === 'EOSE' && m[1] === s) { clearTimeout(to); try { ws.close(); } catch {} res(r); } } catch {} });
    ws.on('error', () => { clearTimeout(to); res(r); });
  });
}
const parse = (e) => { try { return JSON.parse(e.content); } catch { return null; } };

// A) invoice do provedor
let invoiceHash = null, invoiceSats = null, providerId = null, invoiceBolt11 = null;
for (const r of relays) {
  const evs = await query(r, { kinds: [30081], '#d': [`${orderId}_complete`], limit: 5 });
  for (const ev of evs) {
    const c = parse(ev);
    if (c?.type === 'bro_complete' && c.orderId === orderId && c.providerInvoice) {
      invoiceBolt11 = c.providerInvoice;
      providerId = c.providerId ?? ev.pubkey;
      try {
        const dec = decode(invoiceBolt11);
        invoiceHash = dec.sections.find(s => s.name === 'payment_hash')?.value;
        invoiceSats = (Number(dec.sections.find(s => s.name === 'amount')?.value) || 0) / 1000;
      } catch {}
      break;
    }
  }
  if (invoiceHash) break;
}

// B+C) todos os updates da ordem
const updates = [];
for (const r of relays) {
  for (const e of await query(r, { kinds: [30080], '#r': [orderId], limit: 100 })) {
    const c = parse(e);
    if (c && c.orderId === orderId) updates.push({ ev: e, c });
  }
}
const seen = new Set();
const uniq = updates.filter(u => seen.add(u.ev.id));

// B) preimage do comprador
let payerProof = null;
for (const u of uniq) {
  const pp = u.c.paymentProof;
  if (typeof pp === 'string' && /^[0-9a-f]{64}$/i.test(pp) && u.c.status === 'completed') {
    payerProof = { preimage: pp, author: u.ev.pubkey, at: u.ev.created_at };
  }
}
// C) recibo do provedor
let receipt = null;
for (const u of uniq) {
  if (u.c.receiptOf === 'provider_payment' ||
      (typeof u.c.paymentProof === 'string' && u.c.paymentProof.startsWith('received:'))) {
    receipt = { hash: (u.c.paymentProof || '').replace('received:', ''), author: u.ev.pubkey, at: u.ev.created_at, sats: u.c.receivedSats };
  }
}

console.log('=== VERIFICAÇÃO DE ENTREGA —', orderId, '===\n');
console.log('A) invoice do provedor:', invoiceHash ? `hash ${invoiceHash.slice(0, 16)}… (${invoiceSats} sats, provider ${providerId?.slice(0, 8)})` : 'NÃO ENCONTRADA');

let hashOk = null;
if (payerProof && invoiceHash) {
  hashOk = createHash('sha256').update(Buffer.from(payerProof.preimage, 'hex')).digest('hex') === invoiceHash;
}
console.log('B) prova do comprador (preimage):', payerProof
  ? `presente (${new Date(payerProof.at * 1000).toISOString()}) — sha256==hash da invoice? ${hashOk === null ? 'sem invoice p/ comparar' : hashOk ? 'SIM ✓ (pagamento PROVADO)' : 'NÃO ✗ (prova inválida!)'}`
  : 'ausente');
console.log('C) recibo do provedor:', receipt
  ? `presente (${new Date(receipt.at * 1000).toISOString()}, ${receipt.sats ?? '?'} sats, hash casa com a invoice? ${invoiceHash ? (receipt.hash === invoiceHash ? 'SIM ✓' : 'NÃO ✗') : 'sem invoice p/ comparar'})`
  : 'ausente');

console.log('');
const delivered = (hashOk === true) && receipt != null;
const paidProof = hashOk === true && receipt == null;
console.log('VEREDICTO:', delivered
  ? '✅ DELIVERED — pagamento provado + recebimento confirmado pelas DUAS pontas'
  : paidProof
    ? '🟡 PAID_PROOF_ONLY — pagamento provado criptograficamente; recibo do provedor ainda não chegou ao relay'
    : receipt != null
      ? '🟡 RECEIPT_ONLY — provedor confirmou recebimento; prova do comprador ainda não veio'
      : '⚪ NO_PROOF — sem atestados no relay (ordem antiga ou pagamento não liquidado)');
process.exit(0);
