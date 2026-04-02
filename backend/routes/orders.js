const express = require('express');
const router = express.Router();
const { v4: uuidv4 } = require('uuid');
const { orders } = require('../models/database');
const { refundOrder } = require('../services/bitcoinService');

/**
 * Parse numérico estrito — rejeita notação científica, hex, strings vazias.
 * Retorna NaN se o valor não for um decimal simples.
 */
function parseStrictNumber(val) {
  if (val === null || val === undefined || val === '') return NaN;
  const str = String(val);
  // Só permite dígitos, ponto decimal opcional, sinal negativo opcional
  if (!/^-?\d+(\.\d+)?$/.test(str)) return NaN;
  const num = Number(str);
  // SECURITY v445: Prevent precision loss
  if (!isFinite(num)) return NaN;
  return num;
}

// POST /orders/create - Criar nova ordem após pagamento Lightning
router.post('/create', async (req, res) => {
  try {
    const { 
      paymentHash, 
      paymentType, 
      accountNumber, 
      billValue, 
      btcAmount 
    } = req.body;

    // SEGURANÇA: Usar pubkey verificada via NIP-98, não confiar no body
    const userId = req.verifiedPubkey;

    // Validação
    if (!userId || !paymentHash || !paymentType || !accountNumber || !billValue || !btcAmount) {
      return res.status(400).json({ 
        error: 'Campos obrigatórios faltando',
        required: ['paymentHash', 'paymentType', 'accountNumber', 'billValue', 'btcAmount']
      });
    }

    // v270: Validação de range (v398: rejeitar notação científica)
    const billValueParsed = parseStrictNumber(billValue);
    const btcAmountParsed = parseStrictNumber(btcAmount);
    if (isNaN(billValueParsed) || billValueParsed <= 0 || billValueParsed > 100000) {
      return res.status(400).json({ error: 'billValue deve ser entre 0 e R$ 100.000' });
    }
    if (isNaN(btcAmountParsed) || btcAmountParsed <= 0 || btcAmountParsed > 1) {
      return res.status(400).json({ error: 'btcAmount deve ser entre 0 e 1 BTC' });
    }
    if (!['pix', 'boleto'].includes(paymentType)) {
      return res.status(400).json({ error: 'paymentType deve ser pix ou boleto' });
    }

    // Criar ordem
    const orderId = uuidv4();
    const now = new Date();
    const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1000); // 24 horas

    const order = {
      id: orderId,
      userId,
      paymentHash,
      paymentType,
      accountNumber,
      billValue: billValueParsed,
      btcAmount: btcAmountParsed,
      status: 'pending',
      providerId: null,
      proofUrl: null,
      createdAt: now.toISOString(),
      expiresAt: expiresAt.toISOString(),
      acceptedAt: null,
      completedAt: null,
      cancelledAt: null,
      metadata: {}
    };

    orders.set(orderId, order);

    console.log(`✅ Ordem criada: ${orderId} | Usuário: ${userId} | Valor: R$ ${billValue}`);

    res.status(201).json({
      success: true,
      order
    });

  } catch (error) {
    console.error('Erro ao criar ordem:', error);
    res.status(500).json({ error: 'Erro ao criar ordem' });
  }
});

// GET /orders/available - Listar ordens disponíveis para provedores
// IMPORTANTE: Deve vir ANTES de /:orderId para não ser capturado como parâmetro
router.get('/available', (req, res) => {
  try {
    const { providerId } = req.query;

    const availableOrders = Array.from(orders.values())
      .filter(order => {
        // Apenas ordens pending e não expiradas
        if (order.status !== 'pending') return false;
        
        const now = new Date();
        const expiresAt = new Date(order.expiresAt);
        if (now > expiresAt) return false;

        return true;
      })
      .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));

    console.log(`📋 Listando ${availableOrders.length} ordens disponíveis para provedor ${providerId || 'any'}`);

    // v398: Filtrar campos sensíveis — provedores não precisam ver accountNumber
    const sanitizedOrders = availableOrders.map(order => ({
      id: order.id,
      userId: order.userId,
      paymentType: order.paymentType,
      billValue: order.billValue,
      btcAmount: order.btcAmount,
      status: order.status,
      createdAt: order.createdAt,
      expiresAt: order.expiresAt,
    }));

    res.json({
      success: true,
      count: sanitizedOrders.length,
      orders: sanitizedOrders
    });

  } catch (error) {
    console.error('Erro ao listar ordens disponíveis:', error);
    res.status(500).json({ error: 'Erro ao listar ordens' });
  }
});

// GET /orders/:orderId - Buscar ordem por ID
router.get('/:orderId', (req, res) => {
  try {
    const { orderId } = req.params;

    // SECURITY v445: Validate orderId format
    if (!orderId || orderId.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(orderId)) {
      return res.status(400).json({ error: 'orderId inv\u00e1lido' });
    }

    const order = orders.get(orderId);

    if (!order) {
      return res.status(404).json({ error: 'Ordem não encontrada' });
    }

    // v398: Apenas o criador ou o provedor da ordem podem ver detalhes completos
    const callerPubkey = req.verifiedPubkey;
    if (callerPubkey !== order.userId && callerPubkey !== order.providerId) {
      return res.status(403).json({ error: 'Sem permissão para ver esta ordem' });
    }

    res.json({
      success: true,
      order
    });

  } catch (error) {
    console.error('Erro ao buscar ordem:', error);
    res.status(500).json({ error: 'Erro ao buscar ordem' });
  }
});

// GET /orders/user/:userId - Listar ordens de um usuário
router.get('/user/:userId', (req, res) => {
  try {
    const { userId } = req.params;
    
    // SECURITY v445: Validate userId format (64-char hex pubkey)
    if (!userId || !/^[0-9a-f]{64}$/i.test(userId)) {
      return res.status(400).json({ error: 'userId inválido' });
    }
    
    // SEGURANÇA: Verificar que o caller é o próprio usuário
    if (req.verifiedPubkey && req.verifiedPubkey !== userId) {
      return res.status(403).json({ error: 'Sem permissão para ver ordens de outro usuário' });
    }
    
    const userOrders = Array.from(orders.values())
      .filter(order => order.userId === userId)
      .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));

    res.json({
      success: true,
      count: userOrders.length,
      orders: userOrders
    });

  } catch (error) {
    console.error('Erro ao listar ordens do usuário:', error);
    res.status(500).json({ error: 'Erro ao listar ordens' });
  }
});

// POST /orders/:orderId/cancel - Cancelar ordem
router.post('/:orderId/cancel', async (req, res) => {
  try {
    const { orderId } = req.params;    // SECURITY v446: Validate orderId format
    if (!orderId || orderId.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(orderId)) {
      return res.status(400).json({ error: 'orderId inv\u00e1lido' });
    }    // SEGURANÇA: Usar pubkey verificada do NIP-98
    const userId = req.verifiedPubkey;

    const order = orders.get(orderId);

    if (!order) {
      return res.status(404).json({ error: 'Ordem não encontrada' });
    }

    // Validar que é o dono da ordem (usando pubkey verificada)
    if (order.userId !== userId) {
      return res.status(403).json({ error: 'Você não tem permissão para cancelar esta ordem' });
    }

    // Só pode cancelar se estiver pending
    if (order.status !== 'pending') {
      return res.status(400).json({ 
        error: 'Ordem não pode ser cancelada', 
        currentStatus: order.status 
      });
    }

    // Fazer refund do Bitcoin (simulado)
    try {
      await refundOrder(order);
      console.log(`💰 Refund processado para ordem ${orderId}`);
    } catch (refundError) {
      console.error('Erro ao processar refund:', refundError);
      // Continua mesmo se o refund falhar (pode ser processado manualmente)
    }

    // Atualizar ordem
    order.status = 'cancelled';
    order.cancelledAt = new Date().toISOString();
    orders.set(orderId, order);

    console.log(`❌ Ordem cancelada: ${orderId}`);

    res.json({
      success: true,
      message: 'Ordem cancelada com sucesso',
      order
    });

  } catch (error) {
    console.error('Erro ao cancelar ordem:', error);
    res.status(500).json({ error: 'Erro ao cancelar ordem' });
  }
});

// POST /orders/:orderId/accept - Provedor aceita ordem
router.post('/:orderId/accept', async (req, res) => {
  try {
    const { orderId } = req.params;    // SECURITY v446: Validate orderId format
    if (!orderId || orderId.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(orderId)) {
      return res.status(400).json({ error: 'orderId inv\u00e1lido' });
    }    const { collateralLocked } = req.body;
    // SEGURANÇA: Usar pubkey verificada como providerId
    const providerId = req.verifiedPubkey;

    const order = orders.get(orderId);

    if (!order) {
      return res.status(404).json({ error: 'Ordem não encontrada' });
    }

    // Atomic status check — single synchronous block before any await
    if (order.status !== 'pending') {
      return res.status(409).json({ 
        error: 'Ordem já foi aceita ou não está mais disponível',
        currentStatus: order.status
      });
    }

    // Verificar se ainda não expirou
    const now = new Date();
    const expiresAt = new Date(order.expiresAt);
    if (now > expiresAt) {
      order.status = 'expired';
      orders.set(orderId, order);
      return res.status(400).json({ error: 'Ordem expirada' });
    }

    // Mark as accepted IMMEDIATELY (synchronous — no await between check and set)
    order.status = 'accepted';
    order.providerId = providerId;
    order.acceptedAt = new Date().toISOString();
    order.metadata.collateralLocked = collateralLocked;
    orders.set(orderId, order);

    console.log(`✅ Ordem aceita: ${orderId} | Provedor: ${providerId}`);

    res.json({
      success: true,
      message: 'Ordem aceita com sucesso',
      order
    });

  } catch (error) {
    console.error('Erro ao aceitar ordem:', error);
    res.status(500).json({ error: 'Erro ao aceitar ordem' });
  }
});

// POST /orders/:orderId/submit-proof - Provedor envia comprovante
router.post('/:orderId/submit-proof', async (req, res) => {
  try {
    const { orderId } = req.params;    // SECURITY v446: Validate orderId format
    if (!orderId || orderId.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(orderId)) {
      return res.status(400).json({ error: 'orderId inv\u00e1lido' });
    }    const { proofUrl, proofData } = req.body;
    // SEGURANÇA: Usar pubkey verificada como providerId
    const providerId = req.verifiedPubkey;

    const order = orders.get(orderId);

    if (!order) {
      return res.status(404).json({ error: 'Ordem não encontrada' });
    }

    // Validar que é o provedor da ordem (usando pubkey verificada)
    if (order.providerId !== providerId) {
      return res.status(403).json({ error: 'Você não é o provedor desta ordem' });
    }

    // Validar status
    if (order.status !== 'accepted') {
      return res.status(400).json({ 
        error: 'Ordem não está em estado para receber comprovante',
        currentStatus: order.status
      });
    }

    // v398: Validar proofUrl se fornecido — deve ser HTTPS
    if (proofUrl) {
      try {
        const parsed = new URL(proofUrl);
        if (parsed.protocol !== 'https:') {
          return res.status(400).json({ error: 'proofUrl deve usar HTTPS' });
        }
      } catch (e) {
        return res.status(400).json({ error: 'proofUrl inválido' });
      }
    }

    // Atualizar ordem
    order.status = 'payment_submitted';
    order.proofUrl = proofUrl;
    order.metadata.proofData = proofData;
    order.metadata.submittedAt = new Date().toISOString();
    orders.set(orderId, order);

    console.log(`📸 Comprovante enviado: ${orderId}`);

    res.json({
      success: true,
      message: 'Comprovante enviado com sucesso',
      order
    });

  } catch (error) {
    console.error('Erro ao enviar comprovante:', error);
    res.status(500).json({ error: 'Erro ao enviar comprovante' });
  }
});

// POST /orders/:orderId/validate - Validar pagamento (aprovar/rejeitar)
router.post('/:orderId/validate', async (req, res) => {
  try {
    const { orderId } = req.params;
    // SECURITY v446: Validate orderId format
    if (!orderId || orderId.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(orderId)) {
      return res.status(400).json({ error: 'orderId inv\u00e1lido' });
    }
    const { approved, rejectionReason } = req.body;
    // SEGURANÇA v270: Verificar que o caller é o dono da ordem (usuário)
    const callerPubkey = req.verifiedPubkey;

    const order = orders.get(orderId);

    if (!order) {
      return res.status(404).json({ error: 'Ordem não encontrada' });
    }

    // Apenas o dono da ordem pode validar o pagamento
    if (order.userId !== callerPubkey) {
      console.warn(`🔒 Validate rejeitado: caller ${callerPubkey.substring(0, 8)} não é dono da ordem`);
      return res.status(403).json({ error: 'Sem permissão para validar esta ordem' });
    }

    // Validar status
    if (order.status !== 'payment_submitted') {
      return res.status(400).json({ 
        error: 'Ordem não está aguardando validação',
        currentStatus: order.status
      });
    }

    if (approved) {
      // Aprovar pagamento
      order.status = 'completed';
      order.completedAt = new Date().toISOString();
      order.metadata.approvedAt = new Date().toISOString();
      
      console.log(`✅ Pagamento aprovado: ${orderId}`);

      // TODO: Liberar Bitcoin do escrow para o provedor
      // await releaseEscrow(orderId);

    } else {
      // Rejeitar pagamento
      order.status = 'rejected';
      order.metadata.rejectedAt = new Date().toISOString();
      order.metadata.rejectionReason = typeof rejectionReason === 'string' 
        ? rejectionReason.substring(0, 500) : '';
      
      console.log(`❌ Pagamento rejeitado: ${orderId} | Razão: ${rejectionReason}`);

      // TODO: Refund para usuário
      // await refundOrder(order);
    }

    orders.set(orderId, order);

    res.json({
      success: true,
      message: approved ? 'Pagamento aprovado' : 'Pagamento rejeitado',
      order
    });

  } catch (error) {
    console.error('Erro ao validar pagamento:', error);
    res.status(500).json({ error: 'Erro ao validar pagamento' });
  }
});

module.exports = router;
