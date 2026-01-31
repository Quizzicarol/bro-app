const WebSocket = require('ws');

const ws = new WebSocket('wss://relay.damus.io');

ws.on('open', () => {
  console.log('Conectado ao relay');
  // Buscar todas as ordens Bro mais recentes
  ws.send(JSON.stringify(['REQ', 'orders', {
    kinds: [30078, 30079, 30080, 30081],
    '#t': ['bro-app'],
    limit: 50
  }]));
});

ws.on('message', (data) => {
  const msg = JSON.parse(data);
  if (msg[0] === 'EVENT') {
    const event = msg[2];
    let content = {};
    try { content = JSON.parse(event.content); } catch(e) {}
    
    const orderId = content.orderId || content.id || 'N/A';
    const time = new Date(event.created_at * 1000).toLocaleTimeString();
    const date = new Date(event.created_at * 1000).toLocaleDateString();
    
    console.log(`Kind: ${event.kind} | ${date} ${time} | Order: ${orderId.substring(0,8)} | Status: ${content.status || content.type || '-'} | Pubkey: ${event.pubkey.substring(0,8)}...`);
  }
  if (msg[0] === 'EOSE') {
    console.log('\n--- Fim dos eventos ---');
    ws.close();
    process.exit(0);
  }
});

ws.on('error', (err) => {
  console.error('Erro:', err.message);
});

setTimeout(() => {
  console.log('Timeout');
  process.exit(0);
}, 8000);
