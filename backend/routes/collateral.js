const express = require('express');
const router = express.Router();
const { v4: uuidv4 } = require('uuid');
const { collaterals } = require('../models/database');

/**
 * Parse inteiro estrito — rejeita notação científica, hex, decimais.
 */
function parseStrictInt(val) {
  if (val === null || val === undefined || val === '') return NaN;
  const str = String(val);
  if (!/^-?\d+$/.test(str)) return NaN;
  return Number(str);
}

// POST /collateral/deposit - Criar invoice para depósito de garantia
router.post('/deposit', async (req, res) => {
  try {
    const { tierId, amountBrl, amountSats } = req.body;
    // SEGURANÇA: Usar pubkey verificada como providerId
    const providerId = req.verifiedPubkey;

    // Validação
    if (!providerId || !tierId || !amountBrl || !amountSats) {
      return res.status(400).json({ 
        error: 'Campos obrigatórios faltando',
        required: ['tierId', 'amountBrl', 'amountSats']
      });
    }

    // v270: Validação de range (v398: rejeitar notação científica)
    const satsParsed = parseStrictInt(amountSats);
    if (isNaN(satsParsed) || satsParsed <= 0 || satsParsed > 10000000) {
      return res.status(400).json({ error: 'amountSats deve ser entre 1 e 10.000.000' });
    }

    // Gerar invoice Lightning (simulado)
    const invoiceId = uuidv4();
    const invoice = `lnbc${satsParsed}n1...`; // Invoice fake para exemplo

    const depositRecord = {
      id: invoiceId,
      providerId,
      tierId,
      amountBrl: parseStrictInt(amountBrl) || 0,
      amountSats: satsParsed,
      status: 'pending',
      invoice,
      createdAt: new Date().toISOString(),
      paidAt: null
    };

    // Salvar temporariamente (em produção usar BD)
    collaterals.set(invoiceId, depositRecord);

    console.log(`💰 Invoice de garantia criada: ${invoiceId} | Provedor: ${providerId} | ${amountSats} sats`);

    res.json({
      success: true,
      invoice,
      invoiceId,
      amountSats: satsParsed
    });

  } catch (error) {
    console.error('Erro ao criar invoice de garantia:', error);
    res.status(500).json({ error: 'Erro ao criar invoice' });
  }
});

// POST /collateral/lock - Bloquear garantia ao aceitar ordem
router.post('/lock', async (req, res) => {
  try {
    const { orderId, lockedSats } = req.body;
    // SEGURANÇA: Usar pubkey verificada como providerId
    const providerId = req.verifiedPubkey;

    if (!providerId || !orderId || !lockedSats) {
      return res.status(400).json({ 
        error: 'Campos obrigatórios faltando',
        required: ['orderId', 'lockedSats']
      });
    }

    // TODO: Em produção, verificar se provedor tem saldo suficiente
    // e bloquear o valor no banco de dados

    console.log(`🔒 Garantia bloqueada: Provedor ${providerId} | Ordem ${orderId} | ${lockedSats} sats`);

    res.json({
      success: true,
      message: 'Garantia bloqueada com sucesso',
      lockedSats: parseStrictInt(lockedSats) || 0
    });

  } catch (error) {
    console.error('Erro ao bloquear garantia:', error);
    res.status(500).json({ error: 'Erro ao bloquear garantia' });
  }
});

// POST /collateral/unlock - Desbloquear garantia após conclusão
router.post('/unlock', async (req, res) => {
  try {
    const { orderId } = req.body;
    // SEGURANÇA: Usar pubkey verificada como providerId
    const providerId = req.verifiedPubkey;

    if (!providerId || !orderId) {
      return res.status(400).json({ 
        error: 'Campos obrigatórios faltando',
        required: ['orderId']
      });
    }

    // TODO: Em produção, desbloquear o valor no banco de dados

    console.log(`🔓 Garantia desbloqueada: Provedor ${providerId} | Ordem ${orderId}`);

    res.json({
      success: true,
      message: 'Garantia desbloqueada com sucesso'
    });

  } catch (error) {
    console.error('Erro ao desbloquear garantia:', error);
    res.status(500).json({ error: 'Erro ao desbloquear garantia' });
  }
});

// GET /collateral/:providerId - Consultar garantia de provedor
router.get('/:providerId', (req, res) => {
  try {
    const { providerId } = req.params;

    // SEGURANÇA: Verificar que o caller é o próprio provedor
    if (req.verifiedPubkey && req.verifiedPubkey !== providerId) {
      return res.status(403).json({ error: 'Sem permissão para ver garantias de outro provedor' });
    }

    // Buscar todas as garantias deste provedor
    const providerCollaterals = Array.from(collaterals.values())
      .filter(c => c.providerId === providerId && c.status === 'paid');

    const totalSats = providerCollaterals.reduce((sum, c) => sum + c.amountSats, 0);
    const currentTier = totalSats >= 3000 ? 'advanced' : 
                       totalSats >= 1000 ? 'intermediate' : 
                       totalSats >= 500 ? 'basic' : 'none';

    res.json({
      success: true,
      providerId,
      totalSats,
      currentTier,
      deposits: providerCollaterals.length
    });

  } catch (error) {
    console.error('Erro ao consultar garantia:', error);
    res.status(500).json({ error: 'Erro ao consultar garantia' });
  }
});

module.exports = router;
