// Broadcast push notification to ALL registered bro users.
// Usage (PowerShell):
//   $env:ADMIN_NSEC="nsec1..."  (or 64-char hex)
//   $env:BROADCAST_TITLE="Atualize o Bro"
//   $env:BROADCAST_BODY="Nova versão 1.0.133+546 disponível"
//   node scripts/broadcast_push.mjs
//
// Auth: NIP-98 kind 27235 signed with ADMIN_NSEC (must match server ADMIN_PUBKEY).
// Rate limit: 1 broadcast per 5 minutes on the server.

import { finalizeEvent, getPublicKey } from 'nostr-tools/pure';
import { nip19 } from 'nostr-tools';

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const NSEC_FILE = join(__dirname, '..', '.admin_nsec.tmp');

const BACKEND_URL = process.env.BACKEND_URL || 'https://bro-api.fly.dev';
let ADMIN_NSEC = process.env.ADMIN_NSEC;
if (!ADMIN_NSEC && existsSync(NSEC_FILE)) {
  ADMIN_NSEC = readFileSync(NSEC_FILE, 'utf-8').trim();
  console.log('[BROADCAST] Loaded nsec from .admin_nsec.tmp (will NOT be deleted by this script).');
}
const TITLE = process.env.BROADCAST_TITLE || 'Nova versão do Bro disponível';
const BODY =
  process.env.BROADCAST_BODY ||
  'Atualize para a v1.0.133+546 em https://github.com/Brostr/bro/releases/latest';

if (!ADMIN_NSEC) {
  console.error('ERROR: set $env:ADMIN_NSEC="nsec1..." (or 64-char hex) before running.');
  process.exit(1);
}

// Decode nsec or hex
let sk;
try {
  if (ADMIN_NSEC.startsWith('nsec1')) {
    const decoded = nip19.decode(ADMIN_NSEC);
    if (decoded.type !== 'nsec') throw new Error('Not an nsec');
    sk = decoded.data; // Uint8Array
  } else if (/^[0-9a-f]{64}$/i.test(ADMIN_NSEC)) {
    sk = Uint8Array.from(Buffer.from(ADMIN_NSEC, 'hex'));
  } else {
    throw new Error('Invalid ADMIN_NSEC format (expected nsec1... or 64-char hex)');
  }
} catch (e) {
  console.error('ERROR decoding ADMIN_NSEC:', e.message);
  process.exit(1);
}

const pubkey = getPublicKey(sk);
console.log(`[BROADCAST] Signing pubkey: ${pubkey}`);

const url = `${BACKEND_URL}/push/broadcast`;
const method = 'POST';
const body = JSON.stringify({ title: TITLE, body: BODY });

// Compute payload hash (NIP-98 requires SHA-256 of request body hex-encoded)
const { createHash } = await import('node:crypto');
const payloadHash = createHash('sha256').update(body).digest('hex');

// Build NIP-98 auth event (kind 27235)
const authEvent = finalizeEvent(
  {
    kind: 27235,
    created_at: Math.floor(Date.now() / 1000),
    tags: [
      ['u', url],
      ['method', method],
      ['payload', payloadHash],
    ],
    content: '',
  },
  sk,
);

const authHeader = 'Nostr ' + Buffer.from(JSON.stringify(authEvent)).toString('base64');

console.log(`[BROADCAST] POST ${url}`);
console.log(`[BROADCAST] Title: ${TITLE}`);
console.log(`[BROADCAST] Body:  ${BODY}`);

const res = await fetch(url, {
  method,
  headers: {
    'Content-Type': 'application/json',
    Authorization: authHeader,
  },
  body,
});

const text = await res.text();
console.log(`[BROADCAST] HTTP ${res.status}`);
console.log(text);
