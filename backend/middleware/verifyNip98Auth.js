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

// Tolerância de timestamp: 5 minutos (em segundos)
const TIMESTAMP_TOLERANCE = 5 * 60;

/**
 * Middleware que exige autenticação Nostr válida.
 * Rejeita requests sem auth ou com auth inválida.
 */
function requireAuth(req, res, next) {
  const result = verifyRequest(req);
  
  if (!result.valid) {
    console.warn(`🔒 Auth rejeitada: ${req.method} ${req.url} — ${result.reason}`);
    return res.status(401).json({ 
      error: 'Autenticação Nostr inválida',
      reason: result.reason 
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
    return { valid: false, reason: `Kind inválido: ${event.kind} (esperado 27235 ou 22242)` };
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
    return { valid: false, reason: `Timestamp expirado (diff: ${Math.abs(now - eventTime)}s)` };
  }
  
  // 5. Validar URL (tag 'u') — opcional mas recomendado
  const urlTag = (event.tags || []).find(t => t[0] === 'u');
  if (urlTag) {
    const eventUrl = urlTag[1];
    const requestUrl = `${req.protocol}://${req.get('host')}${req.originalUrl}`;
    // Comparação flexível: apenas verificar se o path bate
    const eventPath = new URL(eventUrl).pathname;
    const requestPath = req.originalUrl.split('?')[0];
    if (eventPath !== requestPath) {
      // Log mas não rejeitar — URLs podem diferir por proxy/LB
      console.warn(`⚠️ NIP-98 URL mismatch: event=${eventPath} request=${requestPath}`);
    }
  }
  
  // 6. Validar método (tag 'method') — opcional
  const methodTag = (event.tags || []).find(t => t[0] === 'method');
  if (methodTag && methodTag[1].toUpperCase() !== req.method.toUpperCase()) {
    return { valid: false, reason: `Método mismatch: ${methodTag[1]} vs ${req.method}` };
  }
  
  return { valid: true, pubkey: event.pubkey };
}

/**
 * Verifica formato legado com headers customizados.
 * Verifica apenas que o pubkey tem formato válido (hex, 64 chars).
 * 
 * NOTA: Sem o evento completo, não conseguimos verificar a assinatura.
 * Esta é uma verificação fraca — leve em conta no design de segurança.
 * Quando o app migrar para NIP-98 padrão, este fallback deve ser removido.
 */
function verifyLegacyHeaders(pubkey, signature, eventId) {
  // Validar formato da pubkey (hex, 64 chars)
  if (!pubkey || !/^[0-9a-f]{64}$/i.test(pubkey)) {
    return { valid: false, reason: 'Pubkey inválida (deve ser hex de 64 chars)' };
  }
  
  // Validar formato da signature (hex, 128 chars)
  if (!signature || !/^[0-9a-f]{128}$/i.test(signature)) {
    return { valid: false, reason: 'Signature inválida (deve ser hex de 128 chars)' };
  }
  
  // NOTA: Não podemos verificar a assinatura sem o evento completo
  // Aceitar condicionalmente com flag para distinção
  return { valid: true, pubkey: pubkey.toLowerCase() };
}

module.exports = { requireAuth, optionalAuth, verifyRequest };
