/**
 * FCM Push Notification Service
 * 
 * Stores FCM tokens by Nostr pubkey and sends data-only push notifications.
 * Firebase Admin SDK is optional — if not configured, push is disabled gracefully.
 */

const path = require('path');
const fs = require('fs');

let admin = null;
let messaging = null;
let initDone = false; // SECURITY v445: Prevent double-init

// Token storage: pubkey → { token, updatedAt }
// Persisted to disk so tokens survive server restarts
const tokenStore = new Map();
const MAX_TOKENS = 10000; // Prevent memory exhaustion
const TOKEN_FILE = process.env.NODE_ENV === 'production' 
  ? '/data/push_tokens.json' 
  : path.join(__dirname, '..', 'data', 'push_tokens.json');

/**
 * Load tokens from disk (called on init)
 */
function _loadTokens() {
  try {
    if (fs.existsSync(TOKEN_FILE)) {
      const raw = fs.readFileSync(TOKEN_FILE, 'utf8');
      const data = JSON.parse(raw);
      if (typeof data === 'object' && data !== null) {
        for (const [pubkey, entry] of Object.entries(data)) {
          // Validate pubkey format (64-char hex) and entry structure
          if (/^[0-9a-f]{64}$/.test(pubkey) && entry && typeof entry.token === 'string') {
            tokenStore.set(pubkey, {
              token: entry.token,
              updatedAt: entry.updatedAt || Date.now(),
              providerEnabled: entry.providerEnabled === true,
              // v576: persisted appBuild & nudge throttle across restarts so
              // we don't spam users with "update your app" pushes.
              appBuild: typeof entry.appBuild === 'number' ? entry.appBuild : undefined,
              lastUpdateNudgeAt: typeof entry.lastUpdateNudgeAt === 'number'
                ? entry.lastUpdateNudgeAt
                : 0,
              // v588: persisted payment-method preferences for push filtering
              paymentMethods: Array.isArray(entry.paymentMethods) ? entry.paymentMethods : undefined,
              // v594: persisted accepted currencies (ISO-4217 codes) for
              // cross-currency order routing. Empty/undefined = legacy BRL-only.
              acceptedCurrencies: Array.isArray(entry.acceptedCurrencies) ? entry.acceptedCurrencies : undefined,
            });
          }
        }
        console.log(`[PUSH] Loaded ${tokenStore.size} tokens from disk`);
      }
    }
  } catch (e) {
    console.log(`[PUSH] Could not load tokens from disk: ${e.message}`);
  }
}

/**
 * Save tokens to disk (debounced to avoid excessive writes)
 */
let _saveTimeout = null;
function _saveTokens() {
  if (_saveTimeout) clearTimeout(_saveTimeout);
  _saveTimeout = setTimeout(() => {
    try {
      const dir = path.dirname(TOKEN_FILE);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      const data = {};
      for (const [pubkey, entry] of tokenStore) {
        data[pubkey] = entry;
      }
      fs.writeFileSync(TOKEN_FILE, JSON.stringify(data), { encoding: 'utf8', mode: 0o600 });
    } catch (e) {
      console.error(`[PUSH] Could not save tokens to disk: ${e.message}`);
    }
  }, 2000); // Debounce 2s
}

/**
 * Initialize Firebase Admin SDK.
 * Tries in order:
 * 1. GOOGLE_APPLICATION_CREDENTIALS env var (file path)
 * 2. FIREBASE_SERVICE_ACCOUNT env var (JSON string)
 * 3. FIREBASE_SA_PATH env var (explicit file path — no auto-detection)
 * 
 * SECURITY: No filesystem auto-detection. An attacker writing a malicious JSON
 * to backend/ could hijack credentials. Always use explicit env vars.
 */
function init() {
  // SECURITY v445: Prevent double initialization
  if (initDone) return;
  initDone = true;

  try {
    const firebaseAdmin = require('firebase-admin');
    
    if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
      firebaseAdmin.initializeApp({
        credential: firebaseAdmin.credential.applicationDefault(),
      });
    } else if (process.env.FIREBASE_SERVICE_ACCOUNT) {
      const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
      firebaseAdmin.initializeApp({
        credential: firebaseAdmin.credential.cert(serviceAccount),
      });
    } else if (process.env.FIREBASE_SA_PATH) {
      // Explicit path from env var — no directory scanning
      const saPath = path.resolve(process.env.FIREBASE_SA_PATH);
      if (!fs.existsSync(saPath)) {
        console.log(`[PUSH] FIREBASE_SA_PATH file not found: ${saPath}`);
        return;
      }
      const serviceAccount = JSON.parse(fs.readFileSync(saPath, 'utf8'));
      firebaseAdmin.initializeApp({
        credential: firebaseAdmin.credential.cert(serviceAccount),
      });
      console.log(`[PUSH] Loaded credentials from FIREBASE_SA_PATH`);
    } else {
      console.log('[PUSH] No Firebase credentials — push notifications disabled');
      console.log('[PUSH] Set GOOGLE_APPLICATION_CREDENTIALS, FIREBASE_SERVICE_ACCOUNT, or FIREBASE_SA_PATH');
      return;
    }
    
    admin = firebaseAdmin;
    messaging = firebaseAdmin.messaging();
    console.log('[PUSH] Firebase Admin initialized — push notifications enabled');
    _startStaleTokenSweep(); // v676: cura automática de tokens velhos
  } catch (e) {
    console.log(`[PUSH] Firebase Admin not available: ${e.message}`);
    console.log('[PUSH] Push notifications disabled (install firebase-admin to enable)');
  }

  // Load persisted tokens regardless of Firebase status
  _loadTokens();
}

/**
 * Register or update FCM token for a pubkey
 *
 * v576: appBuild is the client's build number (parsed from PackageInfo on
 * the device). Stored on the token entry so we can flag clients running
 * outdated versions that may not understand newer protocol fields (e.g.
 * NIP-44-only billCode introduced in v575). Returns the entry's
 * appBuild so callers can decide to send an "update your app" push.
 */
function registerToken(pubkey, fcmToken, providerEnabled, appBuild) {
  if (!pubkey || !fcmToken) return false;

  // Evict oldest entry if at capacity (and not updating existing)
  if (!tokenStore.has(pubkey) && tokenStore.size >= MAX_TOKENS) {
    let oldest = null;
    let oldestTime = Infinity;
    for (const [key, val] of tokenStore) {
      if (val.updatedAt < oldestTime) {
        oldest = key;
        oldestTime = val.updatedAt;
      }
    }
    if (oldest) tokenStore.delete(oldest);
  }

  // Preserve existing providerEnabled if caller did not pass it explicitly
  const previous = tokenStore.get(pubkey);
  const finalProviderEnabled = (typeof providerEnabled === 'boolean')
    ? providerEnabled
    : (previous ? previous.providerEnabled === true : false);

  // v576: track app build. Older clients (pre-v576) won't send this and we
  // explicitly store undefined so we can distinguish "never seen" from
  // "explicitly old".
  const finalAppBuild = (typeof appBuild === 'number' && appBuild > 0 && appBuild < 100000)
    ? appBuild
    : (previous ? previous.appBuild : undefined);

  tokenStore.set(pubkey, {
    token: fcmToken,
    updatedAt: Date.now(),
    providerEnabled: finalProviderEnabled,
    appBuild: finalAppBuild,
    // Preserve the throttle timestamp across registrations so we don't
    // re-nudge every time the app reconnects (token re-registration runs
    // every ~1h on the client).
    lastUpdateNudgeAt: previous ? previous.lastUpdateNudgeAt : 0,
  });

  _saveTokens();
  console.log(`[PUSH] Token registered for ${pubkey.substring(0, 16)}... provider=${finalProviderEnabled} build=${finalAppBuild ?? '?'} (${tokenStore.size} total)`);
  return true;
}

/**
 * Update provider flag for a pubkey without touching the FCM token.
 * Returns true if updated, false if pubkey has no registered token.
 */
function setProviderStatus(pubkey, enabled) {
  if (!pubkey) return false;
  const entry = tokenStore.get(pubkey);
  if (!entry) return false;
  entry.providerEnabled = enabled === true;
  entry.updatedAt = Date.now();
  _saveTokens();
  console.log(`[PUSH] Provider flag for ${pubkey.substring(0, 16)}... = ${entry.providerEnabled}`);
  return true;
}

/**
 * Send a push notification to a pubkey
 * @param {string} targetPubkey - Recipient's Nostr pubkey
 * @param {object} data - Data payload (all values must be strings)
 * @param {object|null} notification - Optional { title, body } for visible notification (guaranteed delivery)
 * @returns {boolean} success
 */
async function sendPush(targetPubkey, data, notification = null) {
  if (!messaging) {
    console.log(`[PUSH] Push skipped (Firebase not configured) → ${targetPubkey.substring(0, 16)}...`);
    return false;
  }
  
  const entry = tokenStore.get(targetPubkey);
  if (!entry) {
    console.log(`[PUSH] No token for ${targetPubkey.substring(0, 16)}...`);
    return false;
  }
  
  try {
    const message = {
      token: entry.token,
      data: data,
      android: {
        priority: 'high',
      },
      apns: {
        headers: {
          'apns-priority': '10',
          'apns-push-type': 'background',
        },
        payload: {
          aps: {
            'content-available': 1,
          },
        },
      },
    };

    // Add notification field for guaranteed background delivery (order_update)
    // BRIX invoice requests stay data-only for silent background processing
    if (notification && notification.title) {
      // Use ONLY apns.payload.aps for iOS (avoid conflict with message.notification)
      message.notification = {
        title: notification.title,
        body: notification.body || '',
      };
      message.android.notification = {
        // v573: align with AndroidManifest default_notification_channel_id.
        // 'bro_orders_rt' is auto-created by flutter_local_notifications only
        // AFTER its first .show() — if the app was killed before that ever
        // happened, Android silently DROPS FCM notifications targeting an
        // unknown channel. Using the manifest default guarantees delivery
        // even on first install / cold start.
        channelId: 'bro_app_channel',
        priority: 'high',
        defaultSound: true,
      };
      // iOS: explicit alert payload with push-type: alert
      // v534: NAO incluir content-available: 1 aqui. content-available eh para
      // silent pushes (BRIX) e requer Background Modes entitlement. Com alert+content-available,
      // iOS pode silenciosamente descartar o push se o entitlement nao estiver exatamente
      // configurado. Para alert visivel, so precisamos de alert+sound+push-type=alert.
      message.apns.headers['apns-push-type'] = 'alert';
      message.apns.payload.aps = {
        alert: {
          title: notification.title,
          body: notification.body || '',
        },
        sound: 'default',
      };
    }

    const messageId = await messaging.send(message);

    // v572: log FCM messageId so we can correlate server-side dispatch with
    // device-side delivery (or the lack of it) when debugging missing pushes.
    const subtype = data.subtype || data.type;
    console.log(`[PUSH] Sent to ${targetPubkey.substring(0, 16)}... type=${data.type} subtype=${subtype} mid=${messageId || '?'}`);
    return true;
  } catch (e) {
    console.error(`[PUSH] Send failed for ${targetPubkey.substring(0, 16)}...: ${e.message}`);
    
    // Remove invalid tokens
    if (e.code === 'messaging/registration-token-not-registered' ||
        e.code === 'messaging/invalid-registration-token') {
      tokenStore.delete(targetPubkey);
      _saveTokens();
      console.log(`[PUSH] Removed invalid token for ${targetPubkey.substring(0, 16)}...`);
    }
    
    return false;
  }
}

/**
 * Check if push is available
 */
function isEnabled() {
  return messaging !== null;
}

// ── v676: stale-token sweep (cura invisível) ─────────────────────────
// Tokens sem re-registro há > 3 dias recebem um push SILENCIOSO (data-only,
// zero UI) a cada 6h: o app acorda em background e re-registra o token
// (refreshFcmTokenFromPush no app). Tokens mortos (FCM not-registered) são
// removidos pelo sendPush existente. Caso real 20/out: iPhone sem abrir o app
// por dias → token velho → broadcasts de novas ordens não chegaram. Tudo no
// backend; o usuário nunca é incomodado.
const STALE_TOKEN_AGE_MS = 3 * 24 * 60 * 60 * 1000;   // > 3 dias sem re-registro
const STALE_TOKEN_SWEEP_MS = 6 * 60 * 60 * 1000;      // varre a cada 6h
let _staleSweepTimer = null;

function _startStaleTokenSweep() {
  if (_staleSweepTimer) return;
  _staleSweepTimer = setInterval(_sweepStaleTokens, STALE_TOKEN_SWEEP_MS);
  if (_staleSweepTimer.unref) _staleSweepTimer.unref();
  console.log('[PUSH] Stale-token sweep ativo (a cada 6h, idade > 3 dias)');
}

async function _sweepStaleTokens() {
  if (!messaging) return;
  const now = Date.now();
  let nudged = 0;
  for (const [pubkey, entry] of tokenStore) {
    const updatedAt = typeof entry.updatedAt === 'number' ? entry.updatedAt : 0;
    if (now - updatedAt < STALE_TOKEN_AGE_MS) continue;
    nudged++;
    // data-only (notification=null) → apns-push-type: background +
    // content-available: 1 (default do sendPush) → acorda o isolate de fundo.
    await sendPush(pubkey, { type: 'system', subtype: 'token_refresh' }, null);
  }
  if (nudged > 0) console.log(`[PUSH] stale-token sweep: ${nudged} token(s) cutucados`);
}

/**
 * Get token count (for health check)
 */
function getTokenCount() {
  return tokenStore.size;
}

/**
 * Get all registered pubkeys (for watchtower broadcast)
 */
function getAllPubkeys() {
  return Array.from(tokenStore.keys());
}

/**
 * Get pubkeys of users that currently have provider mode ENABLED.
 * v544: Used by watchtower to scope 'new_order' broadcasts to providers only.
 *
 * v588: When `billType` is passed, additionally filter by the provider's
 * declared payment methods. A provider with no `paymentMethods` set (legacy
 * client) is treated as accepting all methods.
 */
function getProviderPubkeys(billType, currency) {
  const wantCur = typeof currency === 'string' && currency ? currency.toUpperCase() : null;
  const out = [];
  for (const [pubkey, entry] of tokenStore) {
    if (!entry || entry.providerEnabled !== true) continue;
    if (billType && Array.isArray(entry.paymentMethods) && entry.paymentMethods.length > 0) {
      if (!entry.paymentMethods.includes(billType)) continue;
    }
    // v594: currency filter. If a non-BRL currency is requested, the provider
    // MUST have it in `acceptedCurrencies`. BRL is treated as default and
    // delivered to every provider (back-compat with all legacy clients).
    if (wantCur && wantCur !== 'BRL') {
      const list = Array.isArray(entry.acceptedCurrencies) ? entry.acceptedCurrencies : [];
      if (!list.includes(wantCur)) continue;
    }
    out.push(pubkey);
  }
  return out;
}

/**
 * v588: Update payment-method preferences for a pubkey. Used by the
 * watchtower to filter 'new_order' broadcasts. `methods` is an array of
 * billType ids (e.g. ['pix','boleto','mx_codi']). Empty array = no methods
 * (provider won't receive any new-order pushes). null/undefined or absent
 * field = treat as "all methods" (legacy clients).
 */
function setProviderPaymentMethods(pubkey, methods) {
  if (!pubkey) return false;
  const entry = tokenStore.get(pubkey);
  if (!entry) return false;
  if (!Array.isArray(methods)) return false;
  // Sanitize: keep only short alphanumeric strings, dedup, cap at 50 entries.
  const clean = [];
  const seen = new Set();
  for (const m of methods) {
    if (typeof m !== 'string') continue;
    const v = m.trim().toLowerCase();
    if (!v || v.length > 32) continue;
    if (!/^[a-z0-9_]+$/.test(v)) continue;
    if (seen.has(v)) continue;
    seen.add(v);
    clean.push(v);
    if (clean.length >= 50) break;
  }
  entry.paymentMethods = clean;
  entry.updatedAt = Date.now();
  _saveTokens();
  console.log(`[PUSH] Payment methods for ${pubkey.substring(0, 16)}... = [${clean.join(',')}]`);
  return true;
}

/**
 * v594: Update accepted-currencies preferences for a pubkey. `currencies` is
 * an array of ISO-4217 codes (e.g. ['MXN','THB']). Empty array = provider
 * only accepts BRL. null/undefined = legacy default (BRL only).
 */
function setProviderAcceptedCurrencies(pubkey, currencies) {
  if (!pubkey) return false;
  const entry = tokenStore.get(pubkey);
  if (!entry) return false;
  if (!Array.isArray(currencies)) return false;
  const clean = [];
  const seen = new Set();
  for (const c of currencies) {
    if (typeof c !== 'string') continue;
    const v = c.trim().toUpperCase();
    if (!/^[A-Z]{3}$/.test(v)) continue;
    if (seen.has(v)) continue;
    seen.add(v);
    clean.push(v);
    if (clean.length >= 32) break;
  }
  entry.acceptedCurrencies = clean;
  entry.updatedAt = Date.now();
  _saveTokens();
  console.log(`[PUSH] Accepted currencies for ${pubkey.substring(0, 16)}... = [${clean.join(',')}]`);
  return true;
}

/**
 * Clean up stale tokens older than 90 days
 */
function cleanupStaleTokens() {
  const maxAge = 90 * 24 * 60 * 60 * 1000;
  const now = Date.now();
  let removed = 0;
  for (const [pubkey, entry] of tokenStore) {
    if (now - entry.updatedAt > maxAge) {
      tokenStore.delete(pubkey);
      removed++;
    }
  }
  if (removed > 0) {
    _saveTokens();
    console.log(`[PUSH] Cleanup: removed ${removed} stale tokens (${tokenStore.size} remaining)`);
  }
}

// Daily cleanup of stale tokens
setInterval(cleanupStaleTokens, 24 * 60 * 60 * 1000);

/**
 * Check if a pubkey has a registered token (for diagnostics)
 *
 * v559: Also surfaces providerEnabled so the device can self-diagnose
 * "why am I not receiving 'Nova ordem' broadcasts?" without a server log.
 */
function hasToken(pubkey) {
  const entry = tokenStore.get(pubkey);
  if (!entry) return { registered: false };
  return {
    registered: true,
    updatedAt: entry.updatedAt,
    ageSeconds: Math.floor((Date.now() - entry.updatedAt) / 1000),
    providerEnabled: entry.providerEnabled === true,
    appBuild: entry.appBuild,
  };
}

/**
 * v576: Send an "update your app" push if the registered build is below
 * `minBuild`. Throttled to 1 nudge per 24h per pubkey via a persisted
 * timestamp on the token entry, so users don't get nagged on every
 * 1h token re-registration cycle.
 *
 * Returns true if a nudge was actually sent, false otherwise.
 *
 * The push is a visible notification (title+body) so it works even when
 * the app is killed. Data field carries the type so the app can deep-link
 * to the update screen if needed.
 */
async function maybeNudgeForUpdate(pubkey, minBuild) {
  const entry = tokenStore.get(pubkey);
  if (!entry) return false;

  // Build is sufficient → no nudge
  if (typeof entry.appBuild === 'number' && entry.appBuild >= minBuild) {
    return false;
  }

  // Throttle: 1 nudge per 24h per pubkey
  const NUDGE_INTERVAL_MS = 24 * 60 * 60 * 1000;
  const lastNudge = entry.lastUpdateNudgeAt || 0;
  if (Date.now() - lastNudge < NUDGE_INTERVAL_MS) {
    return false;
  }

  const ok = await sendPush(
    pubkey,
    {
      type: 'order_update',
      subtype: 'app_update_available',
      sender_pubkey: pubkey, // self-addressed informational push
      source: 'version_gate',
    },
    {
      title: '🔄 Atualize o Bro',
      body: 'Novas ordens podem não aparecer corretamente sem a versão mais recente. Toque para atualizar.',
    },
  );

  if (ok) {
    entry.lastUpdateNudgeAt = Date.now();
    _saveTokens();
    console.log(`[PUSH] Update nudge sent to ${pubkey.substring(0, 16)}... (build=${entry.appBuild ?? 'unknown'} < ${minBuild})`);
  }
  return ok;
}

module.exports = { init, registerToken, setProviderStatus, setProviderPaymentMethods, setProviderAcceptedCurrencies, sendPush, isEnabled, getTokenCount, getAllPubkeys, getProviderPubkeys, hasToken, maybeNudgeForUpdate };
