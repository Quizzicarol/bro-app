// Query Nostr relays for order details and marketplace offer
const WebSocket = require('ws');

const RELAYS = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
];

function queryRelay(relayUrl, filters, label) {
  return new Promise((resolve) => {
    const events = [];
    const subId = 'q_' + Math.random().toString(36).substr(2, 8);
    
    try {
      const ws = new WebSocket(relayUrl);
      const timeout = setTimeout(() => {
        try { ws.close(); } catch(e) {}
        resolve({ relay: relayUrl, label, events, error: 'timeout' });
      }, 10000);

      ws.on('open', () => {
        for (const filter of filters) {
          ws.send(JSON.stringify(['REQ', subId, filter]));
        }
      });

      ws.on('message', (data) => {
        try {
          const msg = JSON.parse(data.toString());
          if (msg[0] === 'EVENT' && msg[1] === subId) {
            events.push(msg[2]);
          } else if (msg[0] === 'EOSE') {
            clearTimeout(timeout);
            ws.close();
            resolve({ relay: relayUrl, label, events });
          }
        } catch(e) {}
      });

      ws.on('error', (err) => {
        clearTimeout(timeout);
        resolve({ relay: relayUrl, label, events, error: err.message });
      });
    } catch(e) {
      resolve({ relay: relayUrl, label, events, error: e.message });
    }
  });
}

// Replicate the _generateShortId logic from Dart 
function generateShortId(offerId) {
  if (!offerId) return '000000';
  let hash = 0;
  for (let i = 0; i < offerId.length; i++) {
    hash = (hash * 31 + offerId.charCodeAt(i)) & 0x7FFFFFFF;
  }
  return ((hash % 999999) + 1).toString().padStart(6, '0');
}

async function main() {
  // Query 1: Full UUID order
  const fullOrderId = '3499a980-0f51-4fb7-80b5-13fcd6a944c5';
  console.log('=== ORDER ' + fullOrderId + ' ===\n');
  
  const orderResults = await Promise.all(
    RELAYS.map(r => queryRelay(r, [{ kinds: [30078], '#d': [fullOrderId], limit: 5 }], 'order'))
  );
  
  for (const res of orderResults) {
    console.log(`Relay: ${res.relay} - ${res.events.length} events ${res.error || ''}`);
    for (const ev of res.events) {
      try {
        const content = JSON.parse(ev.content);
        console.log('\n  Order found!');
        console.log('  Status:', content.status);
        console.log('  Amount:', content.amount, 'BRL');
        console.log('  BTC Price:', content.btcPrice);
        console.log('  Sats:', content.btcAmount);
        console.log('  Bill Type:', content.billType);
        console.log('  Payment Hash:', content.paymentHash || 'N/A');
        console.log('  Created:', new Date(ev.created_at * 1000).toISOString());
        console.log('  Author:', ev.pubkey);
      } catch(e) { console.log('  Parse error:', e.message); }
    }
  }

  // Query 2: Accept events for this order  
  console.log('\n=== ACCEPT (kind 30079) for order ===\n');
  const acceptResults = await Promise.all(
    RELAYS.map(r => queryRelay(r, [{ kinds: [30079], '#d': [fullOrderId], limit: 5 }], 'accept'))
  );
  for (const res of acceptResults) {
    console.log(`Relay: ${res.relay} - ${res.events.length} events ${res.error || ''}`);
    for (const ev of res.events) {
      try {
        const content = JSON.parse(ev.content);
        console.log('  Accept:', JSON.stringify(content, null, 2));
      } catch(e) {}
    }
  }

  // Query 3: Payment proof (kind 30080) for order
  console.log('\n=== PAYMENT PROOF (kind 30080) ===\n');
  const proofResults = await Promise.all(
    RELAYS.map(r => queryRelay(r, [{ kinds: [30080], '#d': [fullOrderId], limit: 5 }], 'proof'))
  );
  for (const res of proofResults) {
    console.log(`Relay: ${res.relay} - ${res.events.length} events ${res.error || ''}`);
    for (const ev of res.events) {
      try {
        const content = JSON.parse(ev.content);
        console.log('  Type:', content.type);
        console.log('  Status:', content.status);
        console.log('  Content:', JSON.stringify(content, null, 2).substring(0, 500));
      } catch(e) {}
    }
  }
  
  // Query 4: Marketplace offers (kind 30019)
  console.log('\n=== MARKETPLACE OFFERS (kind 30019) ===\n');
  
  const mktResults = await Promise.all(
    RELAYS.map(r => queryRelay(r, [{ kinds: [30019], limit: 50 }], 'marketplace'))
  );
  
  const seenOffers = new Set();
  for (const res of mktResults) {
    console.log(`Relay: ${res.relay} - ${res.events.length} offers ${res.error || ''}`);
    for (const ev of res.events) {
      if (seenOffers.has(ev.id)) continue;
      seenOffers.add(ev.id);
      try {
        const content = JSON.parse(ev.content);
        const dTag = ev.tags.find(t => t[0] === 'd')?.[1] || '';
        const shortId = generateShortId(dTag);
        console.log(`\n  Offer #${shortId} (d=${dTag.substring(0,8)}...)`);
        console.log('  Title:', content.title);
        console.log('  Quantity:', content.quantity, '| Sold:', content.sold);
        console.log('  Price:', content.priceSats, 'sats');
        console.log('  Author:', ev.pubkey.substring(0, 16) + '...');
        console.log('  Created:', new Date(ev.created_at * 1000).toISOString());
        
        if (shortId === '160084') {
          console.log('\n  *** THIS IS THE TARGET OFFER #160084 ***');
          console.log('  Full content:', JSON.stringify(content, null, 2));
          console.log('  Full d-tag:', dTag);
        }
      } catch(e) {}
    }
  }
  
  console.log('\n=== DONE ===');
}

main().catch(console.error);
