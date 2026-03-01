// Query Nostr relays for dispute resolution and marketplace offers
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
        // Send subscription for each filter
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

async function main() {
  const orderId = '3499a980';
  
  console.log('=== QUERY 1: Dispute Resolution for order ' + orderId + ' ===\n');
  
  // Query 1: Kind 1 with bro-resolucao tag referencing order 3499a980
  const disputeFilters = [
    { kinds: [1], '#t': ['bro-resolucao'], limit: 50 },
  ];
  
  const disputeResults = await Promise.all(
    RELAYS.map(r => queryRelay(r, disputeFilters, 'dispute'))
  );
  
  let foundDispute = false;
  for (const res of disputeResults) {
    console.log(`Relay: ${res.relay} - ${res.events.length} bro-resolucao events ${res.error ? '('+res.error+')' : ''}`);
    for (const ev of res.events) {
      try {
        const content = JSON.parse(ev.content);
        // Check if this resolution references our order
        const rTags = ev.tags.filter(t => t[0] === 'r');
        const hasOrderRef = rTags.some(t => t[1] && t[1].includes(orderId));
        const contentHasOrder = ev.content.includes(orderId);
        
        if (hasOrderRef || contentHasOrder) {
          foundDispute = true;
          console.log('\n*** FOUND DISPUTE RESOLUTION ***');
          console.log('Event ID:', ev.id);
          console.log('Created:', new Date(ev.created_at * 1000).toISOString());
          console.log('Author (pubkey):', ev.pubkey);
          console.log('Tags:', JSON.stringify(ev.tags, null, 2));
          console.log('Content:', JSON.stringify(content, null, 2));
          console.log('Resolution:', content.resolution);
          console.log('Notes:', content.notes);
          console.log('Loser Pubkey:', content.loserPubkey);
          console.log('Loser Role:', content.loserRole);
          console.log('Resolved At:', content.resolvedAt);
          console.log('');
        }
      } catch(e) {}
    }
  }
  
  if (!foundDispute) {
    console.log('\nNo dispute resolution found for order ' + orderId);
    console.log('Checking ALL bro-resolucao events for partial match...\n');
    for (const res of disputeResults) {
      for (const ev of res.events) {
        try {
          const content = JSON.parse(ev.content);
          if (content.orderId) {
            console.log(`  Order: ${content.orderId} -> ${content.resolution} (${content.resolvedAt})`);
          }
        } catch(e) {}
      }
    }
  }
  
  // Query 2: Kind 30080 audit events  
  console.log('\n=== QUERY 2: Audit events (kind 30080) ===\n');
  const auditFilters = [
    { kinds: [30080], '#t': ['bro-resolucao'], limit: 50 },
  ];
  
  const auditResults = await Promise.all(
    RELAYS.map(r => queryRelay(r, auditFilters, 'audit'))
  );
  
  for (const res of auditResults) {
    console.log(`Relay: ${res.relay} - ${res.events.length} audit events ${res.error ? '('+res.error+')' : ''}`);
    for (const ev of res.events) {
      try {
        const content = JSON.parse(ev.content);
        if (ev.content.includes(orderId) || (content.orderId && content.orderId.includes(orderId))) {
          console.log('\n*** FOUND AUDIT EVENT ***');
          console.log('Event ID:', ev.id);
          console.log('Content:', JSON.stringify(content, null, 2));
        }
      } catch(e) {}
    }
  }
  
  // Query 3: Order events (kind 30078) for order 3499a980
  console.log('\n=== QUERY 3: Order events (kind 30078) for ' + orderId + ' ===\n');
  const orderFilters = [
    { kinds: [30078], '#d': [orderId], limit: 10 },
  ];
  // Also try partial match with broader filter
  const orderFilters2 = [
    { kinds: [30078], limit: 100 },
  ];
  
  const orderResults = await Promise.all(
    RELAYS.map(r => queryRelay(r, orderFilters, 'order-exact'))
  );
  
  let foundOrder = false;
  for (const res of orderResults) {
    console.log(`Relay: ${res.relay} - ${res.events.length} exact order events ${res.error ? '('+res.error+')' : ''}`);
    for (const ev of res.events) {
      foundOrder = true;
      try {
        const content = JSON.parse(ev.content);
        console.log('\n*** FOUND ORDER ***');
        console.log('Event ID:', ev.id);
        console.log('Created:', new Date(ev.created_at * 1000).toISOString());
        console.log('D-tag:', ev.tags.find(t => t[0] === 'd')?.[1]);
        console.log('Status:', content.status);
        console.log('Amount:', content.amount, 'BRL');
        console.log('BTC Amount:', content.btcAmount);
        console.log('Payment Hash:', content.paymentHash);
        console.log('Full content:', JSON.stringify(content, null, 2));
      } catch(e) {}
    }
  }
  
  if (!foundOrder) {
    // Try broader search
    console.log('\nNo exact match. Searching broader...');
    const broadResults = await Promise.all(
      RELAYS.slice(0, 1).map(r => queryRelay(r, orderFilters2, 'order-broad'))
    );
    for (const res of broadResults) {
      for (const ev of res.events) {
        try {
          const dTag = ev.tags.find(t => t[0] === 'd')?.[1] || '';
          if (dTag.includes(orderId)) {
            console.log(`Found order with d-tag: ${dTag}`);
            const content = JSON.parse(ev.content);
            console.log('Status:', content.status);
            console.log('Amount:', content.amount);
          }
        } catch(e) {}
      }
    }
  }

  // Query 4: Kind 30079 (accept) for order 3499a980
  console.log('\n=== QUERY 4: Accept events (kind 30079) ===\n');
  const acceptResults = await Promise.all(
    RELAYS.map(r => queryRelay(r, [{ kinds: [30079], '#d': [orderId], limit: 10 }], 'accept'))
  );
  for (const res of acceptResults) {
    console.log(`Relay: ${res.relay} - ${res.events.length} accept events`);
    for (const ev of res.events) {
      try {
        const content = JSON.parse(ev.content);
        console.log('Accept event:', JSON.stringify(content, null, 2));
      } catch(e) {}
    }
  }

  console.log('\n=== DONE ===');
}

main().catch(console.error);
