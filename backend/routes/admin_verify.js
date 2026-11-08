/**
 * v753 (dívida técnica, item 2 da auditoria): verificação da senha admin no
 * SERVIDOR. Hoje o SHA-256 da senha vai compilado dentro do APK — quem
 * extrai o APK quebra o hash offline (SHA-256 sem salt é rápido de forçar).
 *
 * Este endpoint vira a fonte de verdade: argon2id em env var
 * (ADMIN_PASSWORD_HASH_V2), rate limit 5/min/IP, log de tentativas falhas.
 *
 * TRANSIÇÃO: o app novo chama aqui; builds velhos seguem com o hash local
 * (janela de tolerância — decisão B-i: aceitar a janela + broadcast push
 * forçando update). Decisão A(a): a senha só destrava a TELA admin local;
 * as ações sensíveis já passam por NIP-98/ADMIN_PUBKEY no backend.
 */
const express = require('express');
const rateLimit = require('express-rate-limit');
const argon2 = require('argon2');

const router = express.Router();

const verifyLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 5,
  standardHeaders: true,
  legacyHeaders: false,
  message: { ok: false, error: 'Muitas tentativas. Aguarde um minuto.' },
});

router.post('/verify', verifyLimiter, async (req, res) => {
  try {
    const hash = process.env.ADMIN_PASSWORD_HASH_V2 || '';
    if (!hash) {
      // Nunca vazar se o endpoint existe sem config — resposta genérica.
      return res.status(503).json({ ok: false, error: 'não configurado' });
    }
    const password = req.body?.password;
    if (typeof password !== 'string' || password.length === 0 || password.length > 128) {
      return res.json({ ok: false });
    }
    const ok = await argon2.verify(hash, password);
    if (!ok) {
      console.warn(`[ADMIN-VERIFY] tentativa FALHA ip=${req.ip} ts=${new Date().toISOString()}`);
    } else {
      console.log(`[ADMIN-VERIFY] sucesso ip=${req.ip}`);
    }
    return res.json({ ok });
  } catch (_) {
    return res.json({ ok: false });
  }
});

module.exports = router;
