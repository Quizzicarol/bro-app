/**
 * Push notification routes
 * 
 * POST /push/register-token — Register FCM token (requires NIP-98 auth)
 * POST /push/notify         — Send push to another user (requires NIP-98 auth)
 * POST /push/broadcast       — Admin: send notification to ALL registered users (requires NIP-98 + ADMIN_PUBKEY)
 * GET  /push/status          — Push service status (public)
 */

const express = require('express');
const rateLimit = require('express-rate-limit');
const router = express.Router();
const pushService = require('../services/pushService');
const watchtower = require('../services/nostrWatchtowerService');

// Rate limiting: 10 notifications per minute per IP
const notifyLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many push requests. Try again in 1 minute.' },
});

// Rate limiting: 5 token registrations per minute per pubkey
const registerLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 5,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.verifiedPubkey || req.ip,
  validate: false,
  message: { error: 'Too many registration requests.' },
});

// Allowed push types and subtypes
const ALLOWED_TYPES = new Set(['order_update', 'brix_invoice_request']);
// v574: 'accept_relay' is a SILENT data-only push sent to the order creator
// after a provider accepts. It wakes the background isolate so it can encrypt
// the billCode via NIP-44 and publish kind 30080 — without requiring the app
// to be open. Plaintext billCode in kind 30078 still works for backward compat.
// v576: 'app_update_available' is a self-addressed informational push so the
// server can nudge users on outdated builds (pre-v575) to update.
// v622: 'autopay_nudge' is a SILENT data-only push sent to the ORDER CREATOR
// (buyer) right after the provider republishes a fresh invoice for a liquidated
// order. It wakes the buyer's app so it syncs and auto-pays the provider NOW
// instead of waiting for the next 15min background poll. No visible notification
// (would be spammy every 30min) — kept data-only like accept_relay.
const ALLOWED_SUBTYPES = new Set(['accepted', 'accept_relay', 'app_update_available', 'billcode_encrypted', 'payment_received', 'completed', 'disputed', 'cancelled', 'autopay_nudge']);

// v622: subtypes that must stay SILENT (data-only) — no visible notification.
const SILENT_SUBTYPES = new Set(['autopay_nudge']);

/**
 * POST /push/register-token
 * Body: { fcm_token: string }
 * Auth: NIP-98 (req.verifiedPubkey)
 */
router.post('/register-token', registerLimiter, async (req, res) => {
  const pubkey = req.verifiedPubkey;
  const { fcm_token, provider_enabled, app_build } = req.body;
  
  // v570: tighter length bounds. Real FCM tokens are ~142-200 chars; APNS
  // direct tokens are ~64-200. The previous 4096 upper bound was unnecessary
  // attack surface (40x larger than any real token).
  if (!fcm_token || typeof fcm_token !== 'string' || fcm_token.length < 64 || fcm_token.length > 512) {
    return res.status(400).json({ error: 'Invalid fcm_token' });
  }
  // SECURITY v448: Validate FCM token contains only base64url-safe chars + colons/dashes
  if (!/^[A-Za-z0-9_:.-]{64,512}$/.test(fcm_token)) {
    return res.status(400).json({ error: 'Invalid fcm_token format' });
  }

  // v544: provider_enabled is optional; when omitted, existing flag is preserved
  const providerFlag = (typeof provider_enabled === 'boolean') ? provider_enabled : undefined;

  // v576: app_build is optional integer (1..99999). Older clients won't send
  // it; treat as outdated for nudge purposes.
  let buildNum;
  if (typeof app_build === 'number' && Number.isInteger(app_build) && app_build > 0 && app_build < 100000) {
    buildNum = app_build;
  }

  const ok = pushService.registerToken(pubkey, fcm_token, providerFlag, buildNum);

  // v576: Fire-and-forget update nudge if registered build is below the
  // minimum recommended. Self-throttled to 1/24h inside maybeNudgeForUpdate
  // so we don't spam on the 1h token re-registration cycle.
  // MIN_RECOMMENDED_BUILD is set to 575 — the first build that omits plaintext
  // billCode from kind 30078 and uses NIP-44 only.
  const MIN_RECOMMENDED_BUILD = 575;
  pushService.maybeNudgeForUpdate(pubkey, MIN_RECOMMENDED_BUILD).catch((e) => {
    console.log(`[PUSH] maybeNudgeForUpdate error for ${pubkey.substring(0, 16)}...: ${e.message}`);
  });

  res.json({ ok, push_enabled: pushService.isEnabled() });
});

/**
 * POST /push/provider-status
 * Body: { enabled: boolean }
 * Auth: NIP-98 (req.verifiedPubkey)
 *
 * v544: Toggles whether this pubkey receives 'Nova ordem disponivel' broadcast
 * pushes. Called by the app when the user enters/exits provider mode.
 */
router.post('/provider-status', registerLimiter, (req, res) => {
  const pubkey = req.verifiedPubkey;
  const { enabled } = req.body;
  if (typeof enabled !== 'boolean') {
    return res.status(400).json({ error: 'Invalid enabled flag' });
  }
  const ok = pushService.setProviderStatus(pubkey, enabled);
  res.json({ ok });
});

/**
 * POST /push/payment-methods
 * Body: { methods: string[] }
 * Auth: NIP-98 (req.verifiedPubkey)
 *
 * v588: Update the provider's payment-method preferences. The watchtower
 * uses this list to filter 'Nova ordem' broadcasts so providers only get
 * pushes for methods/currencies they actually handle.
 */
router.post('/payment-methods', registerLimiter, (req, res) => {
  const pubkey = req.verifiedPubkey;
  const { methods } = req.body;
  if (!Array.isArray(methods)) {
    return res.status(400).json({ error: 'Invalid methods array' });
  }
  if (methods.length > 50) {
    return res.status(400).json({ error: 'Too many methods (max 50)' });
  }
  // v615: validar cada elemento — ids curtos alfanuméricos (pix, boleto, mx_codi...)
  const allValid = methods.every(
    (m) => typeof m === 'string' && /^[a-z0-9_]{1,32}$/i.test(m)
  );
  if (!allValid) {
    return res.status(400).json({ error: 'Invalid method id in array' });
  }
  const ok = pushService.setProviderPaymentMethods(pubkey, methods);
  res.json({ ok });
});

/**
 * POST /push/accepted-currencies
 * Body: { currencies: string[] }  // ISO-4217 (e.g. ['MXN','THB'])
 * Auth: NIP-98 (req.verifiedPubkey)
 *
 * v594: Update the provider's accepted currencies for cross-currency order
 * routing. BRL is always accepted (default). The watchtower filters
 * non-BRL 'Nova ordem' broadcasts so only opted-in providers receive them.
 */
router.post('/accepted-currencies', registerLimiter, (req, res) => {
  const pubkey = req.verifiedPubkey;
  const { currencies } = req.body;
  if (!Array.isArray(currencies)) {
    return res.status(400).json({ error: 'Invalid currencies array' });
  }
  if (currencies.length > 32) {
    return res.status(400).json({ error: 'Too many currencies (max 32)' });
  }
  // v615: validar cada elemento — códigos ISO-4217 de 3 letras (BRL, MXN...)
  const allValid = currencies.every(
    (c) => typeof c === 'string' && /^[a-z]{3}$/i.test(c)
  );
  if (!allValid) {
    return res.status(400).json({ error: 'Invalid currency code in array' });
  }
  const ok = pushService.setProviderAcceptedCurrencies(pubkey, currencies);
  res.json({ ok });
});

/**
 * POST /push/notify
 * Body: { target_pubkey: string, type: string, subtype: string, order_id?: string }
 * Auth: NIP-98 (req.verifiedPubkey)
 * 
 * Sends a data-only push notification to the target user.
 * The sender's pubkey is included so the recipient knows who triggered it.
 */
router.post('/notify', notifyLimiter, async (req, res) => {
  const senderPubkey = req.verifiedPubkey;
  const { target_pubkey, type, subtype, order_id } = req.body;
  
  // Validate target_pubkey (64-char hex)
  if (!target_pubkey || typeof target_pubkey !== 'string' || !/^[0-9a-f]{64}$/.test(target_pubkey)) {
    return res.status(400).json({ error: 'Invalid target_pubkey' });
  }
  
  // Whitelist allowed types
  if (!type || typeof type !== 'string' || !ALLOWED_TYPES.has(type)) {
    return res.status(400).json({ error: 'Invalid type' });
  }
  
  // Whitelist allowed subtypes
  if (subtype && !ALLOWED_SUBTYPES.has(subtype)) {
    return res.status(400).json({ error: 'Invalid subtype' });
  }
  
  // Validate order_id format (UUID-like, max 64 chars, alphanumeric + hyphens)
  if (order_id && (typeof order_id !== 'string' || order_id.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(order_id))) {
    return res.status(400).json({ error: 'Invalid order_id' });
  }
  
  // Prevent self-notify
  if (target_pubkey === senderPubkey) {
    return res.json({ ok: false, reason: 'self_notify' });
  }

  // vSEC: order-scoped notifications may only be sent between the two order
  // parties (creator <-> provider). This blocks the accept_relay billcode
  // leak: an attacker could previously push accept_relay with their own
  // pubkey to any order creator and trick the victim's background isolate
  // into NIP-44-encrypting the billCode for the attacker.
  if (type === 'order_update') {
    if (!order_id) {
      return res.status(400).json({ error: 'order_id required for order_update' });
    }
    const senderIsParty = watchtower.isOrderParty(order_id, senderPubkey);
    const targetIsParty = watchtower.isOrderParty(order_id, target_pubkey);
    if (!senderIsParty || !targetIsParty) {
      console.warn(`[PUSH] /notify REJECTED: sender=${senderPubkey.substring(0,8)} target=${target_pubkey.substring(0,8)} order=${String(order_id).substring(0,8)} senderParty=${senderIsParty} targetParty=${targetIsParty}`);
      return res.status(403).json({ error: 'Not a party to this order' });
    }
  }
  
  // Build data payload (all values must be strings for FCM)
  const data = {
    type: String(type),
    sender_pubkey: senderPubkey,
  };
  
  if (subtype) data.subtype = String(subtype);
  if (order_id) data.order_id = String(order_id);

  // Build notification for order_update → guaranteed background delivery
  // BRIX invoice requests stay data-only (need silent background processing)
  let notification = null;
  if (type === 'order_update' && !SILENT_SUBTYPES.has(subtype)) {
    const notifMap = {
      accepted:           { title: '🤝 Ordem aceita!',        body: 'Um Bro aceitou sua ordem' },
      payment_received:   { title: '📸 Comprovante recebido!', body: 'Verifique o comprovante e confirme' },
      completed:          { title: '✅ Ordem concluída!',      body: 'Troca finalizada com sucesso' },
      disputed:           { title: '⚠️ Disputa aberta',       body: 'Uma disputa foi aberta na sua ordem' },
      cancelled:          { title: '❌ Ordem cancelada',       body: 'Uma ordem foi cancelada' },
    };
    notification = notifMap[subtype] || { title: '📋 Atualização de ordem', body: 'Abra o app para ver as novidades' };
  }

  console.log(`[PUSH] /notify from=${senderPubkey.substring(0, 16)}... to=${target_pubkey.substring(0, 16)}... type=${type} subtype=${subtype || 'none'}`);

  const sent = await pushService.sendPush(target_pubkey, data, notification);
  
  console.log(`[PUSH] /notify result: sent=${sent} type=${type} subtype=${subtype || 'none'}`);
  res.json({ ok: sent });
});

/**
 * POST /push/test-self
 * Auth: NIP-98 (req.verifiedPubkey)
 * v539: Envia um push de teste para o proprio usuario, bypass do self_notify guard.
 * Usado pela tela de diagnostico para validar delivery end-to-end.
 */
router.post('/test-self', notifyLimiter, async (req, res) => {
  const pubkey = req.verifiedPubkey;
  const data = {
    type: 'order_update',
    sender_pubkey: pubkey,
    subtype: 'accepted',
    order_id: `test-${Date.now()}`,
  };
  const notification = {
    title: '🧪 Push de teste',
    body: 'Se voce ve isso, notificacoes funcionam!',
  };
  console.log(`[PUSH] /test-self pubkey=${pubkey.substring(0, 16)}...`);
  const sent = await pushService.sendPush(pubkey, data, notification);
  console.log(`[PUSH] /test-self result: sent=${sent}`);
  res.json({ ok: sent });
});

/**
 * GET /push/status
 * Returns push service status (no auth required)
 */
router.get('/status', (req, res) => {
  // vSEC: do not expose tokens_registered publicly — it leaks the registered
  // user count (base size / growth) to unauthenticated callers.
  res.json({
    enabled: pushService.isEnabled(),
  });
});

/**
 * GET /push/diagnose
 * Auth: NIP-98 (req.verifiedPubkey)
 * Returns whether THIS pubkey has a token registered.
 * Used by the app to detect silent registration failures on iOS.
 */
router.get('/diagnose', (req, res) => {
  const pubkey = req.verifiedPubkey;
  const state = pushService.hasToken(pubkey);
  // Log so we can see iOS devices calling in for diagnosis
  console.log(`[PUSH] /diagnose pubkey=${pubkey.substring(0, 16)}... registered=${state.registered}${state.registered ? ` age=${state.ageSeconds}s` : ''}`);
  res.json({
    pubkey_short: pubkey.substring(0, 8),
    push_enabled: pushService.isEnabled(),
    ...state,
  });
});

// Admin pubkey from env (v615: normalize to lowercase for consistent compare)
const ADMIN_PUBKEY = (process.env.ADMIN_PUBKEY || '').toLowerCase();

// Rate limiting: 1 broadcast per 5 minutes
const broadcastLimiter = rateLimit({
  windowMs: 5 * 60 * 1000,
  max: 1,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Broadcast rate limited. Try again in 5 minutes.' },
});

/**
 * POST /push/broadcast
 * Body: { title: string, body: string }
 * Auth: NIP-98 + ADMIN_PUBKEY required
 * 
 * Sends a visible notification to ALL registered users.
 * Throttled: 1 push/second per recipient to respect FCM quota.
 */
router.post('/broadcast', broadcastLimiter, async (req, res) => {
  // Verify admin
  if (!ADMIN_PUBKEY || !/^[0-9a-f]{64}$/.test(ADMIN_PUBKEY)) {
    return res.status(503).json({ error: 'ADMIN_PUBKEY not configured' });
  }
  if ((req.verifiedPubkey || '').toLowerCase() !== ADMIN_PUBKEY) {
    return res.status(403).json({ error: 'Admin access required' });
  }

  const { title, body } = req.body;

  if (!title || typeof title !== 'string' || title.length < 1 || title.length > 200) {
    return res.status(400).json({ error: 'title is required (1-200 chars)' });
  }
  if (!body || typeof body !== 'string' || body.length < 1 || body.length > 500) {
    return res.status(400).json({ error: 'body is required (1-500 chars)' });
  }

  const allPubkeys = pushService.getAllPubkeys();
  if (allPubkeys.length === 0) {
    return res.json({ success: true, sent: 0, failed: 0, total: 0, message: 'No registered users' });
  }

  console.log(`[PUSH] Broadcasting to ${allPubkeys.length} users: "${title}"`);

  // Send async — respond immediately, process in background
  res.json({
    success: true,
    total: allPubkeys.length,
    message: `Broadcasting to ${allPubkeys.length} users. Check server logs for progress.`,
  });

  // Process sends with 1s delay between each to respect FCM quota
  let sent = 0;
  let failed = 0;

  for (const pubkey of allPubkeys) {
    try {
      const ok = await pushService.sendPush(
        pubkey,
        { type: 'app_update', broadcast: 'true' },
        { title, body }
      );
      if (ok) sent++;
      else failed++;
    } catch (e) {
      failed++;
    }

    // Throttle: 1 push per second
    await new Promise(r => setTimeout(r, 1000));
  }

  console.log(`[PUSH] Broadcast complete: ${sent} sent, ${failed} failed, ${allPubkeys.length} total`);
});

/**
 * POST /push/admin-wake-order
 * Body: { order_id: string }   // full orderId or unique short prefix (>=6 chars)
 * Auth: NIP-98 + ADMIN_PUBKEY required
 *
 * v612: Targeted "wake-up" push for a stuck order. Looks up the order's
 * creator pubkey in the watchtower's _orderUsers cache and sends BOTH a
 * silent accept_relay (to re-trigger NIP-44 billCode publish via the
 * background isolate) AND a visible nudge for the user to open the app.
 * Useful when leo77-style "Obtendo dados de pagamento" gets stuck because
 * the original silent push never reached the buyer (offline / killed iOS).
 */
router.post('/admin-wake-order', async (req, res) => {
  if (!ADMIN_PUBKEY || !/^[0-9a-f]{64}$/.test(ADMIN_PUBKEY)) {
    return res.status(503).json({ error: 'ADMIN_PUBKEY not configured' });
  }
  if ((req.verifiedPubkey || '').toLowerCase() !== ADMIN_PUBKEY) {
    return res.status(403).json({ error: 'Admin access required' });
  }

  const { order_id } = req.body;
  if (!order_id || typeof order_id !== 'string' || order_id.length < 6 || order_id.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(order_id)) {
    return res.status(400).json({ error: 'Invalid order_id (6-64 alphanumeric chars)' });
  }

  let match = watchtower.findOrderCreatorByPrefix(order_id);
  if (!match) {
    console.log(`[PUSH] /admin-wake-order cache miss for ${order_id}, querying relays...`);
    match = await watchtower.queryOrderCreatorByPrefix(order_id);
  }
  if (!match) {
    return res.status(404).json({ error: 'Order not found in cache OR relays (ambiguous prefix? try a longer one)' });
  }

  const { orderId, creatorPubkey } = match;
  const shortId = orderId.substring(0, 8);
  console.log(`[PUSH] /admin-wake-order order=${shortId} target=${creatorPubkey.substring(0, 16)}...`);

  // 1) Silent accept_relay → wakes background isolate to republish billCode (NIP-44)
  const silentData = {
    type: 'order_update',
    sender_pubkey: ADMIN_PUBKEY,
    subtype: 'accept_relay',
    order_id: orderId,
  };
  const silentOk = await pushService.sendPush(creatorPubkey, silentData, null);

  // 2) Visible nudge so the user opens the app even if isolate is dead
  const visibleData = {
    type: 'order_update',
    sender_pubkey: ADMIN_PUBKEY,
    subtype: 'accepted',
    order_id: orderId,
  };
  const visibleNotif = {
    title: '⏰ Sua ordem está esperando!',
    body: 'Abra o Bro para enviar o código PIX criptografado.',
  };
  const visibleOk = await pushService.sendPush(creatorPubkey, visibleData, visibleNotif);

  console.log(`[PUSH] /admin-wake-order ${shortId}: silent=${silentOk} visible=${visibleOk}`);
  res.json({
    ok: silentOk || visibleOk,
    order_id: orderId,
    target_short: creatorPubkey.substring(0, 8),
    silent_sent: silentOk,
    visible_sent: visibleOk,
  });
});

module.exports = router;
