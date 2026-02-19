const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const cron = require('node-cron');
const rateLimit = require('express-rate-limit');

// Middleware de autenticação Nostr (NIP-98)
const { requireAuth, optionalAuth } = require('./middleware/verifyNip98Auth');

// Rotas
const ordersRoutes = require('./routes/orders');
const collateralRoutes = require('./routes/collateral');
const escrowRoutes = require('./routes/escrow');

// Serviços
const { checkExpiredOrders } = require('./services/orderExpirationService');

const app = express();
const PORT = process.env.PORT || 3002;

// ============================================
// CORS — restringir origens em produção
// ============================================
const allowedOrigins = process.env.ALLOWED_ORIGINS 
  ? process.env.ALLOWED_ORIGINS.split(',') 
  : ['*']; // Em dev permite tudo; em prod configurar via env

app.use(cors({
  origin: allowedOrigins.includes('*') ? true : allowedOrigins,
  methods: ['GET', 'POST', 'PUT', 'DELETE'],
  allowedHeaders: [
    'Content-Type', 
    'Authorization', 
    'X-Nostr-Pubkey', 
    'X-Nostr-Signature',
  ],
}));

// ============================================
// Rate Limiting
// ============================================
const generalLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutos
  max: 200, // máximo 200 requests por IP por janela
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Muitas requisições. Tente novamente em 15 minutos.' },
});

const createLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 minuto
  max: 5, // máximo 5 criações por minuto por IP
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Limite de criação atingido. Tente novamente em 1 minuto.' },
});

app.use(generalLimiter);

// ============================================
// Body Parsers
// ============================================
app.use(bodyParser.json({ limit: '5mb' })); // Limitar tamanho do body
app.use(bodyParser.urlencoded({ extended: true }));

// Log de requisições
app.use((req, res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  next();
});

// ============================================
// Rotas públicas (sem auth)
// ============================================

// Health check — NÃO requer auth
app.get('/health', (req, res) => {
  res.json({ 
    status: 'ok', 
    timestamp: new Date().toISOString(),
    uptime: process.uptime()
  });
});

// ============================================
// Rotas protegidas (com auth NIP-98)
// ============================================

// Aplicar authenticação NIP-98 em todas as rotas de negócio
app.use('/orders', requireAuth, ordersRoutes);
app.use('/collateral', requireAuth, collateralRoutes);
app.use('/escrow', requireAuth, escrowRoutes);

// Rate limiting mais restritivo para criação
app.use('/orders/create', createLimiter);
app.use('/collateral/deposit', createLimiter);
app.use('/escrow/create', createLimiter);

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
