const express = require('express');
const router = express.Router();
const { escrows } = require('../models/database');

// POST /escrow/create - Criar escrow com Bitcoin do usuário
router.post('/create', async (req, res) => {
  try {
    const { orderId, btcAmount } = req.body;
    // SEGURANÇA: Usar pubkey verificada como userId
    const userId = req.verifiedPubkey;

    if (!orderId || !userId || !btcAmount) {
      return res.status(400).json({ 
        error: 'Campos obrigatórios faltando',
        required: ['orderId', 'btcAmount']
      });
    }

    const escrow = {
      id: orderId,
      userId,
      btcAmount: parseFloat(btcAmount),
      status: 'locked',
      createdAt: new Date().toISOString(),
      releasedAt: null
    };

    escrows.set(orderId, escrow);

    console.log(`🔐 Escrow criado: ${orderId} | ${btcAmount} BTC`);

    res.json({
      success: true,
      escrow
    });

  } catch (error) {
    console.error('Erro ao criar escrow:', error);
    res.status(500).json({ error: 'Erro ao criar escrow', message: error.message });
  }
});

// POST /escrow/release - Liberar Bitcoin do escrow
router.post('/release', async (req, res) => {
  try {
    const { orderId } = req.body;
    // SEGURANÇA: Usar pubkey verificada como providerId
    const providerId = req.verifiedPubkey;

    if (!orderId || !providerId) {
      return res.status(400).json({ 
        error: 'Campos obrigatórios faltando',
        required: ['orderId']
      });
    }

    const escrow = escrows.get(orderId);

    if (!escrow) {
      return res.status(404).json({ error: 'Escrow não encontrado' });
    }

    if (escrow.status !== 'locked') {
      return res.status(400).json({ 
        error: 'Escrow já foi liberado',
        currentStatus: escrow.status
      });
    }

    // Calcular fees
    const providerFee = 0.03; // 3%
    const platformFee = 0.02; // 2%
    const totalFees = providerFee + platformFee; // 5%

    const providerAmount = escrow.btcAmount * (1 - totalFees);
    const platformAmount = escrow.btcAmount * platformFee;

    // Atualizar escrow
    escrow.status = 'released';
    escrow.releasedAt = new Date().toISOString();
    escrow.providerAmount = providerAmount;
    escrow.platformAmount = platformAmount;
    escrows.set(orderId, escrow);

    // TODO: Em produção, enviar pagamento Lightning para o provedor
    console.log(`💸 Escrow liberado: ${orderId} | Provedor: ${providerAmount.toFixed(8)} BTC | Plataforma: ${platformAmount.toFixed(8)} BTC`);

    res.json({
      success: true,
      message: 'Escrow liberado com sucesso',
      distribution: {
        provider: providerAmount,
        platform: platformAmount,
        totalFees: totalFees * 100 + '%'
      }
    });

  } catch (error) {
    console.error('Erro ao liberar escrow:', error);
    res.status(500).json({ error: 'Erro ao liberar escrow', message: error.message });
  }
});

// GET /escrow/:orderId - Consultar status do escrow
router.get('/:orderId', (req, res) => {
  try {
    const { orderId } = req.params;
    const escrow = escrows.get(orderId);

    if (!escrow) {
      return res.status(404).json({ error: 'Escrow não encontrado' });
    }

    // SEGURANÇA: Verificar que o caller é parte do escrow
    if (req.verifiedPubkey && escrow.userId !== req.verifiedPubkey && escrow.providerId !== req.verifiedPubkey) {
      return res.status(403).json({ error: 'Sem permissão para ver este escrow' });
    }

    res.json({
      success: true,
      escrow
    });

  } catch (error) {
    console.error('Erro ao consultar escrow:', error);
    res.status(500).json({ error: 'Erro ao consultar escrow', message: error.message });
  }
});

module.exports = router;
