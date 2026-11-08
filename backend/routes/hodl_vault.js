/**
 * Rotas do Cofre HODL (garantia real do provedor).
 * Montado em /hodl com requireAuth (NIP-98) — req.verifiedPubkey é o provedor.
 * Rotas /admin/* exigem ADMIN_PUBKEY.
 */
const express = require('express');
const router = express.Router();
const vault = require('../services/hodlVaultService');

function parseStrictInt(val) {
  if (val === null || val === undefined || val === '') return NaN;
  const str = String(val);
  if (!/^-?\d+$/.test(str)) return NaN;
  const num = Number(str);
  if (!Number.isSafeInteger(num)) return NaN;
  return num;
}

function requireAdmin(req, res, next) {
  const adminPk = (process.env.ADMIN_PUBKEY || '').toLowerCase();
  if (!adminPk || (req.verifiedPubkey || '').toLowerCase() !== adminPk) {
    return res.status(403).json({ error: 'admin only' });
  }
  next();
}

// POST /hodl/lock-invoice — cria o invoice HODL da garantia do provedor
router.post('/lock-invoice', async (req, res) => {
  try {
    const providerPubkey = req.verifiedPubkey;
    const { tierId, tierName, expirySecs } = req.body || {};
    const amountSats = parseStrictInt(req.body?.amountSats);
    if (!providerPubkey || !tierId || isNaN(amountSats)) {
      return res.status(400).json({ error: 'campos obrigatórios: tierId, amountSats' });
    }
    if (amountSats < 1000 || amountSats > 50000000) {
      return res.status(400).json({ error: 'amountSats fora do range (1.000–50.000.000)' });
    }
    const expiry = expirySecs !== undefined ? parseStrictInt(expirySecs) : undefined;
    const out = await vault.createLockInvoice({
      providerPubkey,
      tierId: String(tierId),
      tierName: tierName ? String(tierName).substring(0, 40) : undefined,
      amountSats,
      expirySecs: isNaN(expiry) ? undefined : expiry,
      upgrade: req.body?.upgrade === true,
    });
    res.json({ success: true, ...out, amountSats });
  } catch (e) {
    const disabled = String(e.message).includes('VAULT_WALLET_MNEMONIC');
    res.status(disabled ? 503 : 400).json({ error: e.message });
  }
});

// GET /hodl/status — garantia ativa do provedor autenticado
router.get('/status', (req, res) => {
  const r = vault.getActiveForProvider(req.verifiedPubkey);
  res.json({ guarantee: r ? vault._publicRecord(r) : null });
});

// POST /hodl/renew — pega o invoice de renovação quando perto do vencimento
router.post('/renew', async (req, res) => {
  try {
    const out = await vault.createRenewalInvoice(req.verifiedPubkey);
    res.json({ renewal: out }); // null = nada a renovar agora
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

// POST /hodl/request-release — provedor pede liberação. Sem pendências o
// servidor libera NA HORA (pré-assinatura); com pendência vai pra fila da admin.
router.post('/request-release', async (req, res) => {
  try {
    res.json({ success: true, guarantee: await vault.requestRelease(req.verifiedPubkey) });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

// GET /hodl/admin/list — admin vê todas as garantias
router.get('/admin/list', requireAdmin, (req, res) => {
  res.json({ guarantees: vault.listAll() });
});

// POST /hodl/admin/release — admin aprova liberação { paymentHash }
router.post('/admin/release', requireAdmin, async (req, res) => {
  try {
    res.json({ success: true, guarantee: await vault.adminApproveRelease(String(req.body?.paymentHash || '')) });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

// POST /hodl/admin/slash — admin avisa OU recolhe { paymentHash, reason, collect }
// POST /hodl/admin/payout — admin paga uma invoice bolt11 com a carteira do
// cofre (devolução de trial etc). Usa o SDK vivo do serviço.
router.post('/admin/payout', requireAdmin, async (req, res) => {
  try {
    const invoice = req.body?.invoice;
    const out = await vault.adminPayout(invoice);
    res.json({ success: true, ...out });
  } catch (e) {
    res.status(400).json({ success: false, error: e.message });
  }
});

router.post('/admin/slash', requireAdmin, async (req, res) => {
  try {
    const paymentHash = String(req.body?.paymentHash || '');
    const reason = String(req.body?.reason || '').substring(0, 300);
    const collect = req.body?.collect === true;
    const out = collect
      ? await vault.slashCollect(paymentHash, reason)
      : await vault.slashNotify(paymentHash, reason);
    res.json({ success: true, guarantee: out });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

module.exports = router;
