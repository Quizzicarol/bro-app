/**
 * v688: Canal redundante de entrega do billCode (backend + FCM).
 *
 * Motivo (caso real 72d248d8, 31/out): o billCode NIP-44 só viajava pelos
 * relays Nostr. Se o app do comprador acorda mas os relays falham no aparelho
 * dele, o provedor nunca recebe o código. Agora o comprador TAMBÉM posta o
 * blob cifrado aqui; o backend acorda o provedor via FCM silencioso e o
 * provedor busca o blob por GET.
 *
 * PRIVACIDADE: o blob é NIP-44 comprador→provedor — o servidor só transporta
 * ciphertext, igual a um relay público. Nada de plaintext por aqui.
 *
 * Anti-abuso:
 * - blob limitado a 100KB (imagem não passa aqui, só código)
 * - pareamento validado contra o cache do watchtower quando disponível
 *   (orderId → provedor que aceitou). Se o watchtower não conhece a ordem
 *   (ex.: pós-deploy), armazena mas NÃO empurra push (evita spam de push).
 * - 1 entrada por orderId (última vence), TTL 48h, máx 500 entradas.
 */
const express = require('express');
const fs = require('fs');
const path = require('path');

const FALLBACK_FILE = process.env.NODE_ENV === 'production'
  ? '/data/billcode_fallback.json'
  : path.join(__dirname, '..', 'data', 'billcode_fallback.json');

const TTL_MS = 48 * 60 * 60 * 1000;
const MAX_ENTRIES = 500;
const MAX_BLOB = 100 * 1024;

const HEX64 = /^[0-9a-f]{64}$/;

function loadStore() {
  try {
    if (!fs.existsSync(FALLBACK_FILE)) return {};
    const data = JSON.parse(fs.readFileSync(FALLBACK_FILE, 'utf8'));
    return data && typeof data === 'object' ? data : {};
  } catch (_) {
    return {};
  }
}

let saveTimer = null;
function scheduleSave(store) {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try {
      const dir = path.dirname(FALLBACK_FILE);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      const now = Date.now();
      const pruned = Object.fromEntries(
        Object.entries(store)
          .filter(([, v]) => v && typeof v.ts === 'number' && now - v.ts <= TTL_MS)
          .sort((a, b) => b[1].ts - a[1].ts)
          .slice(0, MAX_ENTRIES)
      );
      fs.writeFileSync(FALLBACK_FILE, JSON.stringify(pruned), { encoding: 'utf8', mode: 0o600 });
    } catch (e) {
      console.error(`[BillcodeFallback] persist falhou: ${e.message}`);
    }
  }, 2000);
}

module.exports = function createBillcodeFallbackRouter(watchtower) {
  const router = express.Router();
  const store = loadStore();

  // Comprador publica o blob cifrado (NIP-44) destinado ao provedor
  router.post('/billcode-fallback', async (req, res) => {
    try {
      const { orderId, providerPubkey, senderPubkey, blob } = req.body || {};
      if (typeof orderId !== 'string' || !/^[a-zA-Z0-9-]{8,64}$/.test(orderId)) {
        return res.status(400).json({ ok: false, error: 'orderId inválido' });
      }
      if (typeof providerPubkey !== 'string' || !HEX64.test(providerPubkey) ||
          typeof senderPubkey !== 'string' || !HEX64.test(senderPubkey)) {
        return res.status(400).json({ ok: false, error: 'pubkeys inválidas' });
      }
      if (typeof blob !== 'string' || blob.length < 32 || blob.length > MAX_BLOB) {
        return res.status(400).json({ ok: false, error: 'blob inválido' });
      }

      // Pareamento: se o watchtower conhece a ordem, o provedor tem que bater
      const knownProvider = watchtower && typeof watchtower.getProviderForOrder === 'function'
        ? watchtower.getProviderForOrder(orderId)
        : null;
      if (knownProvider && knownProvider !== providerPubkey) {
        console.log(`🚨 [BillcodeFallback] ${orderId.substring(0, 8)}: provider ${providerPubkey.substring(0, 8)} != aceitante conhecido — rejeitado`);
        return res.status(403).json({ ok: false, error: 'provider não confere com o aceite' });
      }

      store[orderId] = { providerPubkey, senderPubkey, blob, ts: Date.now() };
      scheduleSave(store);
      console.log(`📦 [BillcodeFallback] ${orderId.substring(0, 8)}: blob de ${senderPubkey.substring(0, 8)} → ${providerPubkey.substring(0, 8)} (${blob.length}ch)`);

      // Acorda o provedor (silencioso). Só empurra quando o pareamento é
      // conhecido — evita spam de push contra pubkeys arbitrárias.
      let pushed = false;
      if (knownProvider && watchtower && typeof watchtower.pushBillcodeFallback === 'function') {
        pushed = await watchtower.pushBillcodeFallback(providerPubkey, senderPubkey, orderId);
      }
      return res.json({ ok: true, pushed });
    } catch (e) {
      console.error(`[BillcodeFallback] POST erro: ${e.message}`);
      return res.status(500).json({ ok: false });
    }
  });

  // Provedor busca o blob (ciphertext — mesmo nível de exposição de um relay)
  router.get('/billcode-fallback/:orderId', (req, res) => {
    const entry = store[req.params.orderId];
    if (!entry || Date.now() - entry.ts > TTL_MS) {
      return res.status(404).json({ ok: false, error: 'não encontrado' });
    }
    return res.json({
      ok: true,
      providerPubkey: entry.providerPubkey,
      senderPubkey: entry.senderPubkey,
      blob: entry.blob,
      ts: entry.ts,
    });
  });

  return router;
};
