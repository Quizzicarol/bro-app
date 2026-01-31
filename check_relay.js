const WebSocket = require('ws');

const ws = new WebSocket('wss://relay.damus.io');

ws.on('open', () => {
  console.log('Conectado ao relay');
  // Buscar por kinds BRO mais recentes
  ws.send(JSON.stringify(['REQ', 'q1', {
    kinds: [30078, 30079, 30080, 30081],
    '#t': ['bro-app'],
    limit: 50
  }]));
});

ws.on('message', (data) => {
  const msg = JSON.parse(data);
  if (msg[0] === 'EVENT') {
    const e = msg[2];
    let c = {};
    try { c = JSON.parse(e.content); } catch(x) {}
    const orderId = c.orderId ? c.orderId.substring(0,8) : 'N/A';
    const time = new Date(e.created_at * 1000).toLocaleTimeString();
    console.log('K:', e.kind, '| T:', time, '| O:', orderId, '| S:', c.status, '| Type:', c.type);
  }
  if (msg[0] === 'EOSE') {
    console.log('Fim da busca');
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
