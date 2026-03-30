# Copilot Instructions for Bro App

## CRITICAL: BRIX Payment System Rules

### NEVER use LNbits for BRIX payments
- Not even as "temporary bridge" or "fallback"
- This was tried multiple times and FAILED
- User explicitly forbade it 5+ times

### The server uses its own Spark wallet for offline fallback
- `@breeztech/breez-sdk-spark` running server-side in `server/services/wallet.js`
- Receives payments when app is offline, then forwards when app comes online
- This is NOT LNbits — it's the same Spark SDK the app uses

### Payment Flows (stable as of v1.0.133+416)

**ONLINE**: External wallet → LNURL → server creates invoice_request → FCM push → app generates Spark invoice → sender pays directly to recipient

**OFFLINE**: External wallet → LNURL → server creates its OWN Spark invoice → sender pays server → server holds → when app opens, polls `GET /brix/pending-payments` → app creates invoice → `POST /brix/claim` → server pays app's invoice

### Known Bug Patterns — DON'T REPEAT
1. **Early return in `_poll()`**: Never add `return` before the "Claim pending offline payments" section in `brix_relay_service.dart`. This blocks offline claims entirely.
2. **payment-forward.js not started**: Must call `paymentForward.start()` in server.js
3. **server_invoice not stored**: lnurl.js must store bolt11 in `server_invoice` column

## Nostr Protocol Reference
- Bro uses custom Nostr event kinds: 30078 (order), 30079 (accept), 30080 (payment proof/cancel), 30081 (complete)
- These are **parameterized replaceable events** (30000-39999 range) using `#d` tag = orderId
- Always use `#t` tag `bro-order` for orders
- See `.github/skills/nostr/SKILL.md` for full Nostr protocol reference

## Other Rules
- FCM MUST be data-only (no `notification` field)
- NEVER change marketing version (1.0.133) without asking. Only increment build number.
- env.json is in .gitignore — NEVER track it
