// Broadcast push notification to ALL registered bro users.
// Usage (PowerShell):
//   $env:ADMIN_NSEC="nsec1..."  (or 64-char hex)
//   $env:BROADCAST_TITLE="Atualize o Bro"
//   $env:BROADCAST_BODY="Nova versao 1.0.133+546 disponivel"
//   node scripts/broadcast_push.mjs
//
// Auth: NIP-98 kind 27235 signed with ADMIN_NSEC (must match server ADMIN_PUBKEY).
// Rate limit: 1 broadcast per 5 minutes on the server.

import { finalizeEvent, getPublicKey } from 'nostr-tools/pure';
import { nip19 } from 'nostr-tools';

const BACKEND_URL = process.env.BACKEND_URL || 'https://bro-api.fly.dev';
let ADMIN_NSEC = process.env.ADMIN_NSEC;

// v745 (auditoria item 5): REMOVIDO o fallback que lia a nsec de
// .admin_nsec.tmp — chave admin da plataforma nao deve ser persistida em
// plaintext no diretorio do repo. Agora: env var OU prompt mascarado
// interativo (a chave nunca aparece na tela, nunca vai para argv nem para
// historico de shell).
if (!ADMIN_NSEC) {
  ADMIN_NSEC = await promptMasked(
    'Cole a ADMIN_NSEC (nsec1... ou 64-hex) - entrada oculta: ',
  );
  if (ADMIN_NSEC) {
    console.log('[BROADCAST] nsec recebida via prompt oculto (nao persistida).');
  }
}

const TITLE = process.env.BROADCAST_TITLE || 'Nova versao do Bro disponivel';
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

// v745: zera a referencia assim que a chave e decodificada
ADMIN_NSEC = null;

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

// ---- v745: prompt mascarado (equivalente ao identify_key.ps1) ----
// A chave nao ecoa no terminal, nao vai para argv, nao e logada.
function promptMasked(promptText) {
  return new Promise((resolve) => {
    process.stdout.write(promptText);
    let value = '';
    const wasRaw = process.stdin.isRaw;
    if (process.stdin.isTTY && process.stdin.setRawMode) {
      process.stdin.setRawMode(true);
    }
    // v745 fix de revisão: sem setEncoding, 'data' entrega Buffer e as
    // comparações com '\r'/'\n'/'\u0003' nunca batem — o prompt travava pra
    // sempre (Enter não era detectado). UTF-8 primeiro, depois resume.
    process.stdin.setEncoding('utf8');
    process.stdin.resume();
    const onData = (ch) => {
      // Ctrl+C: aborta sem vazar
      if (ch === '\u0003') {
        cleanup();
        process.stdout.write('\n');
        process.exit(130);
      }
      // Enter: finaliza
      if (ch === '\r' || ch === '\n') {
        cleanup();
        process.stdout.write('\n');
        resolve(value.trim());
        return;
      }
      // Backspace
      if (ch === '\u007f' || ch === '\b') {
        if (value.length > 0) {
          value = value.slice(0, -1);
          process.stdout.write('\b \b');
        }
        return;
      }
      value += ch;
      process.stdout.write('*');
    };
    function cleanup() {
      process.stdin.off('data', onData);
      if (process.stdin.isTTY && process.stdin.setRawMode) {
        process.stdin.setRawMode(wasRaw ?? false);
      }
      process.stdin.pause();
    }
    process.stdin.on('data', onData);
  });
}
