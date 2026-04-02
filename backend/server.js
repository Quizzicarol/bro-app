const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const bodyParser = require('body-parser');
const cron = require('node-cron');
const rateLimit = require('express-rate-limit');

// Middleware de autenticação Nostr (NIP-98)
const { requireAuth, optionalAuth } = require('./middleware/verifyNip98Auth');

// Rotas
const ordersRoutes = require('./routes/orders');
const collateralRoutes = require('./routes/collateral');
const escrowRoutes = require('./routes/escrow');
const agentRoutes = require('./routes/agent');
const pushRoutes = require('./routes/push');

// Serviços
const { checkExpiredOrders } = require('./services/orderExpirationService');
const disputeAgent = require('./services/disputeAgentService');
const pushService = require('./services/pushService');

const app = express();
const PORT = process.env.PORT || 3002;

// ============================================
// Security Headers (helmet)
// ============================================
app.use(helmet({
  contentSecurityPolicy: false, // API não serve HTML
  crossOriginEmbedderPolicy: false,
}));

// ============================================
// CORS — restringir origens em produção
// ============================================
const allowedOrigins = process.env.ALLOWED_ORIGINS 
  ? process.env.ALLOWED_ORIGINS.split(',').map(s => s.trim()).filter(Boolean)
  : (process.env.NODE_ENV === 'production' 
    ? (() => { throw new Error('ALLOWED_ORIGINS must be set in production'); })()
    : ['*']); // Em dev permite tudo; em prod exige configuração

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

// SECURITY v446: Trust first proxy for correct client IP in rate limiting
if (process.env.NODE_ENV === 'production') {
  app.set('trust proxy', 1);
}

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
app.use(bodyParser.json({ limit: '500kb' })); // Limitar tamanho do body
app.use(bodyParser.urlencoded({ extended: true }));

// Log de requisições (sanitizado — sem IDs/tokens)
app.use((req, res, next) => {
  const safePath = req.url.split('?')[0].replace(/\/[a-f0-9]{64}/g, '/:id').replace(/\/[a-f0-9-]{36}/g, '/:uuid');
  console.log(`[${new Date().toISOString()}] ${req.method} ${safePath}`);
  next();
});

// ============================================
// Rotas públicas (sem auth)
// ============================================

// Health check — NÃO requer auth (rate limited)
app.get('/health', generalLimiter, (req, res) => {
  res.json({ 
    status: 'ok', 
    timestamp: new Date().toISOString(),
    uptime: process.uptime()
  });
});

// Push status — NÃO requer auth (rate limited)
app.get('/push/status', generalLimiter, (req, res) => {
  const pushService = require('./services/pushService');
  res.json({
    enabled: pushService.isEnabled(),
    tokens_registered: pushService.getTokenCount(),
  });
});

// ============================================
// Rotas protegidas (com auth NIP-98)
// ============================================

// Rate limiting mais restritivo para criação (ANTES das rotas)
app.use('/orders/create', createLimiter);
app.use('/collateral/deposit', createLimiter);
app.use('/escrow/create', createLimiter);

// Aplicar authenticação NIP-98 em todas as rotas de negócio
app.use('/orders', requireAuth, ordersRoutes);
app.use('/collateral', requireAuth, collateralRoutes);
app.use('/escrow', requireAuth, escrowRoutes);
app.use('/agent', requireAuth, agentRoutes);
app.use('/push', requireAuth, pushRoutes);

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
    error: 'Erro interno do servidor'
  });
});

// Iniciar servidor
app.listen(PORT, () => {
  console.log(`\n🚀 Servidor rodando na porta ${PORT}`);
  console.log(`📡 Health check: http://localhost:${PORT}/health`);
  console.log(`⏰ Job de expiração de ordens ativo (a cada 5 minutos)`);
  
  // Iniciar agente de disputas (Nostr listener + análise AI)
  disputeAgent.init();
  console.log(`🤖 Agente de disputas ativo (Nostr listener + análise)`);
  
  // Inicializar serviço de push notifications
  pushService.init();
  console.log('');

});
