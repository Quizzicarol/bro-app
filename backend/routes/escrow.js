const express = require('express');
const router = express.Router();
const { escrows } = require('../models/database');
const { orders } = require('../models/database');

/**
 * Parse numérico estrito — rejeita notação científica, hex, strings vazias.
 */
function parseStrictNumber(val) {
  if (val === null || val === undefined || val === '') return NaN;
  const str = String(val);
  if (!/^-?\d+(\.\d+)?$/.test(str)) return NaN;
  return Number(str);
}

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
    // v270: Validação de range (v398: rejeitar notação científica)
    const btcAmountParsed = parseStrictNumber(btcAmount);
    if (isNaN(btcAmountParsed) || btcAmountParsed <= 0 || btcAmountParsed > 1) {
      return res.status(400).json({ error: 'btcAmount deve ser entre 0 e 1 BTC' });
    }
    const escrow = {
      id: orderId,
      userId,
      btcAmount: btcAmountParsed,
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
    res.status(500).json({ error: 'Erro ao criar escrow' });
  }
});

// POST /escrow/release - Liberar Bitcoin do escrow
router.post('/release', async (req, res) => {
  try {
    const { orderId } = req.body;
    // SEGURANÇA: Usar pubkey verificada como caller
    const callerPubkey = req.verifiedPubkey;

    if (!orderId || !callerPubkey) {
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

    // SEGURANÇA v270: Verificar que o caller é o dono do escrow (usuário que criou)
    // Apenas o usuário que depositou pode liberar os fundos
    if (escrow.userId !== callerPubkey) {
      // Verificar também se é o provedor da ordem associada
      const order = orders.get(orderId);
      if (!order || order.providerId !== callerPubkey) {
        console.warn(`🔒 Escrow release rejeitado: caller ${callerPubkey.substring(0, 8)} não é dono nem provedor`);
        return res.status(403).json({ error: 'Sem permissão para liberar este escrow' });
      }
    }

    // v398: Verificar que a ordem associada foi completada antes de liberar escrow
    const associatedOrder = orders.get(orderId);
    if (!associatedOrder) {
      return res.status(400).json({ error: 'Ordem associada não encontrada' });
    }
    if (associatedOrder.status !== 'completed') {
      console.warn(`🔒 Escrow release rejeitado: ordem ${orderId} status=${associatedOrder.status} (esperado: completed)`);
      return res.status(400).json({ 
        error: 'Ordem ainda não foi completada — pagamento precisa ser validado primeiro',
        currentOrderStatus: associatedOrder.status
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
    res.status(500).json({ error: 'Erro ao liberar escrow' });
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
    res.status(500).json({ error: 'Erro ao consultar escrow' });
  }
});

module.exports = router;
