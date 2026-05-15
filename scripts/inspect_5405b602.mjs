import WebSocket from 'ws';

const fullId = '5405b602-0233-4307-a77e-658284351a7f';
const relays = ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net'];

async function query(relay, filter) {
  return new Promise((resolve) => {
    const ws = new WebSocket(relay);
    const results = [];
    const subId = 'q' + Math.random().toString(36).slice(2, 10);
    const timeout = setTimeout(() => { try { ws.close(); } catch {} resolve(results); }, 15000);
    ws.on('open', () => { ws.send(JSON.stringify(['REQ', subId, filter])); });
    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg[0] === 'EVENT' && msg[1] === subId) results.push(msg[2]);
        else if (msg[0] === 'EOSE' && msg[1] === subId) {
          clearTimeout(timeout); try { ws.close(); } catch {} resolve(results);
        }
      } catch {}
    });
    ws.on('error', () => { clearTimeout(timeout); resolve(results); });
  });
}

const allEvents = [];
for (const r of relays) {
  for (const k of [30078, 30079, 30080, 30081]) {
    const evs1 = await query(r, { kinds: [k], '#d': [fullId], limit: 100 });
    const evs2 = await query(r, { kinds: [k], '#d': [fullId + '_0b31181f021539d1afcda76e66577d5a7797a9603ac4a7aa46514745c8acfc26_update'], limit: 100 });
    const evs3 = await query(r, { kinds: [k], '#d': [fullId + '_4c020f93_update'], limit: 100 });
    for (const ev of [...evs1, ...evs2, ...evs3]) allEvents.push({ ...ev, _relay: r });
  }
}
// Also fetch all updates by either pubkey filtered by #d substring approach (use #r tag)
for (const r of relays) {
  const evs = await query(r, { kinds: [30078, 30079, 30080, 30081], '#r': [fullId], limit: 100 });
  for (const ev of evs) allEvents.push({ ...ev, _relay: r });
}
const seen = new Set();
const unique = allEvents.filter(e => { if (seen.has(e.id)) return false; seen.add(e.id); return true; });
unique.sort((a, b) => a.created_at - b.created_at);
console.log(`${unique.length} unique events\n`);
for (const ev of unique) {
  let parsed = null;
  try { parsed = JSON.parse(ev.content); } catch {}
  const dTag = ev.tags.find(t => t[0] === 'd')?.[1] || '';
  console.log('==========================================================');
  console.log('time:', new Date(ev.created_at * 1000).toISOString());
  console.log('kind:', ev.kind, ' from:', ev.pubkey.slice(0, 16));
  console.log('d:', dTag);
  console.log('content keys:', parsed ? Object.keys(parsed).join(',') : 'unparsed');
  if (parsed) {
    const dump = { ...parsed };
    // Trim noisy fields
    for (const k of ['proofImage','encryptedBillCode','billCode','providerInvoice']) {
      if (dump[k] && typeof dump[k] === 'string' && dump[k].length > 80) dump[k] = dump[k].slice(0, 80) + '...(' + dump[k].length + ')';
    }
    console.log(JSON.stringify(dump, null, 2));
  }
}
