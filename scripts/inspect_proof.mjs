// Diagnóstico: puxa o evento de comprovante (kind 30081) de uma ordem dos relays
// e disseca o campo proofImage_nip44 (tamanho, validade do payload NIP-44 v2,
// pubkeys carimbadas). NÃO decripta — só valida integridade estrutural.
//
// Uso: node scripts/inspect_proof.mjs 22480acc
import WebSocket from 'ws';

const orderPrefix = process.argv[2] || '22480acc';
const relays = ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net'];
const since = Math.floor(Date.now() / 1000) - 90 * 86400;

function query(relay, filter, t = 20000) {
  return new Promise((res) => {
    const ws = new WebSocket(relay);
    const r = [];
    const s = 'q' + Math.random().toString(36).slice(2, 8);
    const to = setTimeout(() => { try { ws.close(); } catch {} res(r); }, t);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', s, filter])));
    ws.on('message', (d) => {
      try {
        const m = JSON.parse(d.toString());
        if (m[0] === 'EVENT' && m[1] === s) r.push(m[2]);
        else if (m[0] === 'EOSE' && m[1] === s) { clearTimeout(to); try { ws.close(); } catch {} res(r); }
      } catch {}
    });
    ws.on('error', () => { clearTimeout(to); res(r); });
  });
}

// Valida um payload NIP-44 v2 (base64): versão(1) + nonce(32) + ciphertext(>=1) + mac(32)
function inspectNip44(b64) {
  const out = { present: true, b64len: b64.length };
  let raw;
  try { raw = Buffer.from(b64, 'base64'); } catch (e) { out.base64Valid = false; return out; }
  // base64 válido se re-encode bate (ignorando padding)
  out.base64Valid = raw.length > 0;
  out.rawBytes = raw.length;
  out.version = raw[0];
  out.minLenOk = raw.length >= 1 + 32 + 1 + 32; // 66 bytes mínimo
  // Heurística de truncamento: NIP-44 v2 deve ter versão 2
  out.looksValidV2 = raw[0] === 2 && out.minLenOk;
  return out;
}

const all = [];
for (const relay of relays) {
  // busca ampla por kinds da Bro no período; filtramos por orderId no conteúdo
  const evs = await query(relay, { kinds: [30078, 30079, 30080, 30081], since, limit: 800 });
  let matched = 0;
  for (const e of evs) {
    let p = null; try { p = JSON.parse(e.content); } catch {}
    const oid = p?.orderId || '';
    if (oid.startsWith(orderPrefix)) { all.push({ ...e, _relay: relay, _p: p }); matched++; }
  }
  console.log(`${relay}: ${evs.length} eventos, ${matched} da ordem ${orderPrefix}`);
}

console.log(`\n===== ANÁLISE ordem ${orderPrefix}* =====\n`);
const seen = new Set();
const uniq = all.filter((e) => { if (seen.has(e.id)) return false; seen.add(e.id); return true; });
uniq.sort((a, b) => a.created_at - b.created_at);

for (const e of uniq) {
  const p = e._p || {};
  console.log(`─ kind=${e.kind} type=${p.type || '?'} id=${e.id.slice(0, 12)} at=${new Date(e.created_at * 1000).toISOString()}`);
  console.log(`   from(pubkey)=${e.pubkey.slice(0, 12)}  relays=${uniq.filter(x => x.id === e.id).map(x => x._relay).join(',')}`);
  console.log(`   orderId=${p.orderId}`);
  if (p.userPubkey || p.recipientPubkey) console.log(`   userPubkey=${(p.userPubkey || '').slice(0, 12)}  recipient=${(p.recipientPubkey || '').slice(0, 12)}`);
  if (p.providerId) console.log(`   providerId=${p.providerId.slice(0, 12)}`);
  if (p.proofImage_senderPubkey) console.log(`   proofImage_senderPubkey=${p.proofImage_senderPubkey.slice(0, 12)}`);
  if (p.encryption) console.log(`   encryption=${p.encryption}`);
  if (p.proofImage !== undefined) {
    const v = String(p.proofImage);
    console.log(`   proofImage(plaintext)= "${v.slice(0, 40)}${v.length > 40 ? '…' : ''}" (len=${v.length})`);
  }
  if (p.proofImage_nip44 !== undefined) {
    const info = inspectNip44(String(p.proofImage_nip44));
    console.log(`   proofImage_nip44: ${JSON.stringify(info)}`);
  }
  if (p.proofImage_nip44_admin !== undefined) {
    const info = inspectNip44(String(p.proofImage_nip44_admin));
    console.log(`   proofImage_nip44_admin: ${JSON.stringify(info)}`);
  }
  // tamanho total do evento (aprox) — relays têm limite
  const evSize = JSON.stringify(e).length;
  console.log(`   >>> tamanho total do evento: ${(evSize / 1024).toFixed(1)} KB\n`);
}

if (uniq.length === 0) console.log('Nenhum evento encontrado para essa ordem nos relays consultados.');
process.exit(0);
