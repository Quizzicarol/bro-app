/**
 * NIP-98 HTTP Auth Middleware
 * 
 * Verifica autenticação Nostr em requests HTTP.
 * Suporta dois formatos:
 * 
 * 1. NIP-98 padrão: Authorization: Nostr <base64-encoded-event>
 * 2. Custom headers: X-Nostr-Pubkey + X-Nostr-Signature (formato legado do app)
 * 
 * O pubkey verificado é adicionado a req.verifiedPubkey para uso nas rotas.
 * 
 * @see https://github.com/nostr-protocol/nips/blob/master/98.md
 */

const { verifyEvent } = require('nostr-tools/pure');

// Tolerância de timestamp: 30 segundos
const TIMESTAMP_TOLERANCE = 30;

// SECURITY v615: NIP-98 host allowlist.
// Antes só validávamos o PATH da tag "u", não o host. Isso permitia que um
// evento NIP-98 assinado para https://attacker.com/orders/123 fosse reusado
// contra o servidor real (mesmo path). Agora exigimos que o host pertença a
// uma allowlist. Configurável via NIP98_ALLOWED_HOSTS (csv); default cobre os
// hosts conhecidos do app + fly.io interno. Em dev, localhost é aceito.
const NIP98_ALLOWED_HOSTS = (() => {
  const fromEnv = (process.env.NIP98_ALLOWED_HOSTS || '')
    .split(',')
    .map(h => h.trim().toLowerCase())
    .filter(Boolean);
  const defaults = [
    'api.brostr.app',
    'brix.brostr.app',
    'bro-api.fly.dev',
  ];
  // Em desenvolvimento aceitamos localhost / emulador Android.
  if (process.env.NODE_ENV !== 'production') {
    defaults.push('localhost', '127.0.0.1', '10.0.2.2');
  }
  return new Set([...defaults, ...fromEnv]);
})();

// Replay protection: track seen event IDs with TTL
const seenEventIds = new Map(); // eventId → expiresAt (timestamp ms)
const REPLAY_WINDOW_MS = (TIMESTAMP_TOLERANCE + 5) * 1000; // slightly beyond tolerance
const REPLAY_CLEANUP_INTERVAL = 60000; // cleanup every 60s
const REPLAY_MAX_SIZE = 100000; // v523: hard cap to prevent memory growth under load

// Periodic cleanup of expired event IDs
setInterval(() => {
  const now = Date.now();
  for (const [id, expiresAt] of seenEventIds) {
    if (now > expiresAt) seenEventIds.delete(id);
  }
}, REPLAY_CLEANUP_INTERVAL);

/**
 * Middleware que exige autenticação Nostr válida.
 * Rejeita requests sem auth ou com auth inválida.
 */
function requireAuth(req, res, next) {
  const result = verifyRequest(req);
  
  if (!result.valid) {
    console.warn(`🔒 Auth rejeitada: ${req.method} ${req.url} — ${result.reason}`);
    return res.status(401).json({ 
      error: 'Authorization failed',
    });
  }
  
  // Pubkey verificada criptograficamente — usar como identidade do usuário
  req.verifiedPubkey = result.pubkey;
  next();
}

/**
 * Middleware opcional: adiciona pubkey se auth presente, mas não rejeita sem auth.
 * Útil para rotas que funcionam para anônimos mas dão mais dados a autenticados.
 */
function optionalAuth(req, res, next) {
  const result = verifyRequest(req);
  
  if (result.valid) {
    req.verifiedPubkey = result.pubkey;
  }
  
  next();
}

/**
 * Verifica autenticação Nostr de um request.
 * @param {import('express').Request} req
 * @returns {{ valid: boolean, pubkey?: string, reason?: string }}
 */
function verifyRequest(req) {
  const authHeader = req.headers['authorization'] || '';
  const pubkeyHeader = req.headers['x-nostr-pubkey'];
  const sigHeader = req.headers['x-nostr-signature'];
  
  // ==============================
  // Formato 1: NIP-98 padrão
  // Authorization: Nostr <base64-encoded-event-json>
  // ==============================
  if (authHeader.startsWith('Nostr ')) {
    const token = authHeader.slice(6).trim();
    
    // Verificar se é base64 (NIP-98 padrão) ou apenas eventId (formato legado)
    // Base64 de JSON sempre começa com 'ey' (para '{') e é bem maior que 64 chars
    if (token.length > 64) {
      try {
        const eventJson = Buffer.from(token, 'base64').toString('utf-8');
        const event = JSON.parse(eventJson);
        
        return verifyNip98Event(event, req);
      } catch (e) {
        return { valid: false, reason: `Erro ao decodificar NIP-98: ${e.message}` };
      }
    }
    
    // Formato legado: Authorization: Nostr <eventId>
    // Precisa dos headers X-Nostr-Pubkey e X-Nostr-Signature
    if (pubkeyHeader && sigHeader) {
      return verifyLegacyHeaders(pubkeyHeader, sigHeader, token);
    }
    
    return { valid: false, reason: 'Formato de autorização incompleto (falta X-Nostr-Pubkey/Signature)' };
  }
  
  // ==============================
  // Formato 2: Apenas headers customizados (sem Authorization)
  // ==============================
  if (pubkeyHeader && sigHeader) {
    return verifyLegacyHeaders(pubkeyHeader, sigHeader);
  }
  
  return { valid: false, reason: 'Header Authorization ausente' };
}

/**
 * Verifica evento NIP-98 completo.
 * Valida: assinatura, kind, timestamp, URL e método.
 */
function verifyNip98Event(event, req) {
  // 1. Validar estrutura básica
  if (!event || !event.id || !event.pubkey || !event.sig || !event.kind) {
    return { valid: false, reason: 'Evento NIP-98 mal-formado' };
  }
  
  // 2. Kind deve ser 27235 (NIP-98) ou 22242 (formato usado pelo app)
  if (event.kind !== 27235 && event.kind !== 22242) {
    return { valid: false, reason: 'Kind inválido' };
  }
  
  // 3. Verificar assinatura criptográfica
  try {
    // nostr-tools v2 espera o evento no formato correto
    const eventToVerify = {
      id: event.id,
      pubkey: event.pubkey,
      created_at: event.created_at,
      kind: event.kind,
      tags: event.tags || [],
      content: event.content || '',
      sig: event.sig,
    };
    
    const isValid = verifyEvent(eventToVerify);
    if (!isValid) {
      return { valid: false, reason: 'Assinatura Nostr inválida' };
    }
  } catch (e) {
    return { valid: false, reason: `Erro na verificação: ${e.message}` };
  }
  
  // 4. Validar timestamp (não pode ser muito antigo ou futuro)
  const now = Math.floor(Date.now() / 1000);
  const eventTime = event.created_at;
  if (Math.abs(now - eventTime) > TIMESTAMP_TOLERANCE) {
    // SECURITY v492: Don't leak exact diff to attacker
    return { valid: false, reason: 'Timestamp expirado' };
  }
  
  // 4b. Replay protection — reject reused event IDs
  if (seenEventIds.has(event.id)) {
    return { valid: false, reason: 'Replay detected: event ID already used' };
  }
  // v523: Cap set size to prevent unbounded growth under burst load
  if (seenEventIds.size >= REPLAY_MAX_SIZE) {
    // Evict oldest 10% by insertion order (Map preserves it)
    const evict = Math.floor(REPLAY_MAX_SIZE / 10);
    let i = 0;
    for (const key of seenEventIds.keys()) {
      if (i++ >= evict) break;
      seenEventIds.delete(key);
    }
  }
  seenEventIds.set(event.id, Date.now() + REPLAY_WINDOW_MS);
  
  // 5. Validar URL (tag 'u') — REQUIRED for security
  const urlTag = (event.tags || []).find(t => t[0] === 'u');
  if (!urlTag || !urlTag[1]) {
    return { valid: false, reason: 'NIP-98: tag "u" (URL) é obrigatória' };
  }
  const eventUrl = urlTag[1];
  // SECURITY v615: validar HOST (allowlist) + PATH. Antes só o path era checado,
  // permitindo replay de um evento assinado para outro host com o mesmo path.
  let parsedEventUrl;
  try {
    parsedEventUrl = new URL(eventUrl);
  } catch (_) {
    return { valid: false, reason: 'NIP-98: URL inválida na tag "u"' };
  }
  const eventHost = parsedEventUrl.hostname.toLowerCase();
  if (!NIP98_ALLOWED_HOSTS.has(eventHost)) {
    // Não vazar o host esperado para o atacante
    return { valid: false, reason: 'URL host mismatch' };
  }
  const eventPath = parsedEventUrl.pathname;
  const requestPath = req.originalUrl.split('?')[0];
  if (eventPath !== requestPath) {
    // SECURITY v492: Don't leak path details to attacker
    return { valid: false, reason: 'URL path mismatch' };
  }
  
  // 6. Validar método (tag 'method') — REQUIRED for security
  const methodTag = (event.tags || []).find(t => t[0] === 'method');
  if (!methodTag || !methodTag[1]) {
    return { valid: false, reason: 'NIP-98: tag "method" é obrigatória' };
  }
  if (methodTag[1].toUpperCase() !== req.method.toUpperCase()) {
    // SECURITY v492: Don't leak method details to attacker
    return { valid: false, reason: 'HTTP method mismatch' };
  }

  // v566: NIP-98 payload tag — binds auth event to request body (replay protection).
  // Strict when present; lenient when absent (transitional).
  const payloadTag = (event.tags || []).find(t => t[0] === 'payload');
  const methodHasBody = ['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method.toUpperCase());
  if (payloadTag) {
    const expected = (typeof payloadTag[1] === 'string' ? payloadTag[1] : '').toLowerCase();
    const rawBody = (req.rawBody && req.rawBody.length) ? req.rawBody : Buffer.alloc(0);
    const actual = require('crypto').createHash('sha256').update(rawBody).digest('hex');
    if (expected !== actual) {
      return { valid: false, reason: 'NIP-98 payload hash mismatch' };
    }
  } else if (methodHasBody && req.rawBody && req.rawBody.length > 0) {
    // v747 (auditoria B1): flag pra EXIGIR a tag payload quando o app novo já
    // domina o campo (o app assina payload desde v566). Sem a tag, o corpo do
    // request não está vinculado à assinatura (janela de MITM/replay).
    // Ligar com NIP98_PAYLOAD_REQUIRED=1 ~30 dias após a v747 estabilizar.
    if (process.env.NIP98_PAYLOAD_REQUIRED === '1') {
      return { valid: false, reason: 'NIP-98: tag "payload" obrigatória com body' };
    }
    // Transitional: log only. Older clients still accepted.
    if (process.env.LOG_NIP98_PAYLOAD_WARN === '1') {
      console.log(`[NIP98] WARN ${req.method} ${req.originalUrl}: missing payload tag (transitional)`);
    }
  }

  return { valid: true, pubkey: event.pubkey };
}

/**
 * Verifica formato legado com headers customizados.
 * 
 * REMOVIDO na v270 (Phase 3 Security) — formato legado não verifica assinatura.
 * Todas as requests devem usar NIP-98 padrão com evento base64 completo.
 */
function verifyLegacyHeaders(pubkey, signature, eventId) {
  return { valid: false, reason: 'Formato legado descontinuado. Use NIP-98 padrão (Authorization: Nostr <base64-event>)' };
}

module.exports = { requireAuth, optionalAuth, verifyRequest };
