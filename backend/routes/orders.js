const express = require('express');
const router = express.Router();
const { v4: uuidv4 } = require('uuid');
const { orders } = require('../models/database');
const { refundOrder } = require('../services/bitcoinService');

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
      billValue: parseFloat(billValue),
      btcAmount: parseFloat(btcAmount),
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
    res.status(500).json({ error: 'Erro ao criar ordem', message: error.message });
  }
});

// GET /orders/:orderId - Buscar ordem por ID
router.get('/:orderId', (req, res) => {
  try {
    const { orderId } = req.params;
    const order = orders.get(orderId);

    if (!order) {
      return res.status(404).json({ error: 'Ordem não encontrada' });
    }

    res.json({
      success: true,
      order
    });

  } catch (error) {
    console.error('Erro ao buscar ordem:', error);
    res.status(500).json({ error: 'Erro ao buscar ordem', message: error.message });
  }
});

// GET /orders/user/:userId - Listar ordens de um usuário
router.get('/user/:userId', (req, res) => {
  try {
    const { userId } = req.params;
    
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
    res.status(500).json({ error: 'Erro ao listar ordens', message: error.message });
  }
});

// POST /orders/:orderId/cancel - Cancelar ordem
router.post('/:orderId/cancel', async (req, res) => {
  try {
    const { orderId } = req.params;
    // SEGURANÇA: Usar pubkey verificada do NIP-98
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
    res.status(500).json({ error: 'Erro ao cancelar ordem', message: error.message });
  }
});

// GET /orders/available - Listar ordens disponíveis para provedores
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

    res.json({
      success: true,
      count: availableOrders.length,
      orders: availableOrders
    });

  } catch (error) {
    console.error('Erro ao listar ordens disponíveis:', error);
    res.status(500).json({ error: 'Erro ao listar ordens', message: error.message });
  }
});

// POST /orders/:orderId/accept - Provedor aceita ordem
router.post('/:orderId/accept', async (req, res) => {
  try {
    const { orderId } = req.params;
    const { collateralLocked } = req.body;
    // SEGURANÇA: Usar pubkey verificada como providerId
    const providerId = req.verifiedPubkey;

    const order = orders.get(orderId);

    if (!order) {
      return res.status(404).json({ error: 'Ordem não encontrada' });
    }

    // Validar status
    if (order.status !== 'pending') {
      return res.status(400).json({ 
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

    // Atualizar ordem
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
    res.status(500).json({ error: 'Erro ao aceitar ordem', message: error.message });
  }
});

// POST /orders/:orderId/submit-proof - Provedor envia comprovante
router.post('/:orderId/submit-proof', async (req, res) => {
  try {
    const { orderId } = req.params;
    const { proofUrl, proofData } = req.body;
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
    res.status(500).json({ error: 'Erro ao enviar comprovante', message: error.message });
  }
});

// POST /orders/:orderId/validate - Validar pagamento (aprovar/rejeitar)
router.post('/:orderId/validate', async (req, res) => {
  try {
    const { orderId } = req.params;
    const { approved, rejectionReason } = req.body;

    const order = orders.get(orderId);

    if (!order) {
      return res.status(404).json({ error: 'Ordem não encontrada' });
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
      order.metadata.rejectionReason = rejectionReason;
      
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
    res.status(500).json({ error: 'Erro ao validar pagamento', message: error.message });
  }
});

module.exports = router;
