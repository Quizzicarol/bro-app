// Verifica a assinatura Schnorr do bro_complete da ordem 27c916e7
// e testa se os OUTROS relays da app tambem servem o evento (fanout).
import { createRequire } from 'module';
const require = createRequire('c:/Users/produ/Documents/GitHub/bro_app/backend/package.json');
const { verifyEvent } = require('nostr-tools/pure');
const WebSocket = require('ws');

const orderId = '27c916e7-887d-44fa-a90d-670287cb1a4b';
function query(relay, filter, t = 12000) {
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
  let sigOk = false;
  try { sigOk = verifyEvent(ev); } catch (e) { console.log('verify error:', e.message); }
  console.log('complete', ev.id.slice(0, 16), 'sigOk=' + sigOk, 'created', new Date(ev.created_at * 1000).toISOString());
}
// fanout: o evento existe em outros relays da app?
const appRelays = ['wss://apexcord.duckdns.org', 'wss://bro-relay2.fly.dev', 'wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net'];
for (const r of appRelays) {
  const got = await query(r, { kinds: [30081], '#d': [`${orderId}_complete`], limit: 5 });
  console.log(r, '->', got.length, 'complete(s)');
}
process.exit(0);
