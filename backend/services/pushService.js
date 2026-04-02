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

// In-memory token storage: pubkey → { token, updatedAt }
const tokenStore = new Map();
const MAX_TOKENS = 10000; // Prevent memory exhaustion

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
  } catch (e) {
    console.log(`[PUSH] Firebase Admin not available: ${e.message}`);
    console.log('[PUSH] Push notifications disabled (install firebase-admin to enable)');
  }
}

/**
 * Register or update FCM token for a pubkey
 */
function registerToken(pubkey, fcmToken) {
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
  
  tokenStore.set(pubkey, {
    token: fcmToken,
    updatedAt: Date.now(),
  });
  
  console.log(`[PUSH] Token registered for ${pubkey.substring(0, 16)}... (${tokenStore.size} total)`);
  return true;
}

/**
 * Send a data-only push notification to a pubkey
 * @param {string} targetPubkey - Recipient's Nostr pubkey
 * @param {object} data - Data payload (all values must be strings)
 * @returns {boolean} success
 */
async function sendPush(targetPubkey, data) {
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
    // Data-only message — no notification field (per copilot-instructions.md)
    await messaging.send({
      token: entry.token,
      data: data,
      android: {
        priority: 'high',
      },
      apns: {
        headers: {
          'apns-priority': '10',
        },
        payload: {
          aps: {
            'content-available': 1,
          },
        },
      },
    });
    
    console.log(`[PUSH] Sent to ${targetPubkey.substring(0, 16)}... type=${data.type}`);
    return true;
  } catch (e) {
    console.error(`[PUSH] Send failed for ${targetPubkey.substring(0, 16)}...: ${e.message}`);
    
    // Remove invalid tokens
    if (e.code === 'messaging/registration-token-not-registered' ||
        e.code === 'messaging/invalid-registration-token') {
      tokenStore.delete(targetPubkey);
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

/**
 * Get token count (for health check)
 */
function getTokenCount() {
  return tokenStore.size;
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
    console.log(`[PUSH] Cleanup: removed ${removed} stale tokens (${tokenStore.size} remaining)`);
  }
}

// Daily cleanup of stale tokens
setInterval(cleanupStaleTokens, 24 * 60 * 60 * 1000);

module.exports = { init, registerToken, sendPush, isEnabled, getTokenCount };
