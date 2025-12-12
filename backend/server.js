const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const cron = require('node-cron');

// Rotas
const ordersRoutes = require('./routes/orders');
const collateralRoutes = require('./routes/collateral');
const escrowRoutes = require('./routes/escrow');

// Serviços
const { checkExpiredOrders } = require('./services/orderExpirationService');

const app = express();
const PORT = process.env.PORT || 3002;

// Middlewares
app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// Log de requisições
app.use((req, res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  next();
});

// Rotas
app.use('/orders', ordersRoutes);
app.use('/collateral', collateralRoutes);
app.use('/escrow', escrowRoutes);

// Rota de health check
app.get('/health', (req, res) => {
  res.json({ 
    status: 'ok', 
    timestamp: new Date().toISOString(),
    uptime: process.uptime()
  });
});

// Job para verificar ordens expiradas (roda a cada 5 minutos)
cron.schedule('*/5 * * * *', async () => {
  console.log('[CRON] Verificando ordens expiradas...');
  try {
    await checkExpiredOrders();
    console.log('[CRON] Verificação de ordens expiradas concluída');
  } catch (error) {
    console.error('[CRON] Erro ao verificar ordens expiradas:', error);
  }
});

// Tratamento de erro 404
app.use((req, res) => {
  res.status(404).json({ error: 'Endpoint não encontrado' });
});

// Tratamento de erros global
app.use((err, req, res, next) => {
  console.error('Erro:', err);
  res.status(500).json({ 
    error: 'Erro interno do servidor', 
    message: err.message 
  });
});

// Iniciar servidor
app.listen(PORT, () => {
  console.log(`\n🚀 Servidor rodando na porta ${PORT}`);
  console.log(`📡 Health check: http://localhost:${PORT}/health`);
  console.log(`⏰ Job de expiração de ordens ativo (a cada 5 minutos)\n`);
});
