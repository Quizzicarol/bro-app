# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Bro, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, open a **private security advisory** on GitHub:
https://github.com/Brostr/bro/security/advisories/new

Or contact via Nostr DM to the project maintainer.

Include:
- A clear description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge your report within 48 hours and work with you to understand and address the issue before any public disclosure.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | ✅ Active |
| < 1.0   | ❌ Not supported |

## Security Architecture

### Encryption

- **NIP-44v2** (XChaCha20-Poly1305): All payment proofs are encrypted end-to-end between participants. Admin mediator receives a separate encrypted copy for dispute resolution.
- **NIP-04**: Used for direct messages/chat between users.
- **FlutterSecureStorage**: Private keys and seeds stored in platform-encrypted storage (Android EncryptedSharedPreferences, iOS Keychain).

### Authentication

- **Nostr Keys**: Login via BIP-39 mnemonic seed or direct nsec import. No passwords, no accounts.
- **NIP-98 HTTP Auth**: All backend API calls are authenticated with Nostr event signatures — the backend verifies the caller's identity cryptographically.
- **Event Signature Verification**: All incoming Nostr events are verified before processing, both in foreground and background tasks.

### Input Validation

- **Dispute authorization**: Only order participants (user or provider) can open disputes. Third-party dispute attempts are rejected.
- **Future timestamp rejection**: Events with timestamps more than 15 minutes in the future are discarded (prevents replay/manipulation attacks).
- **Status transition guards**: Terminal statuses (cancelled, completed) cannot be overridden. Status must follow valid progression.

### Data Protection

- **Clipboard auto-clear**: Private keys and seed phrases are automatically cleared from clipboard after 2 minutes.
- **Production logging**: All logging uses `broLog()` which is disabled in release builds — no sensitive data leaks via logs.
- **No credentials in code**: All secrets are loaded via `--dart-define-from-file=env.json` at build time. The env.json file is gitignored.

### Background Security

- **WorkManager tasks**: Background notification and auto-liquidation tasks verify event signatures before processing.
- **Race condition lock**: A 2-minute TTL lock prevents simultaneous auto-liquidation from foreground and background processes.

### Backend Security

- **Helmet**: Standard security headers on all responses.
- **Rate limiting**: 200 requests/15min per IP (general), 5 requests/min per IP (write operations like order creation).
- **CORS**: Configurable allowed origins via environment variable.
- **No raw SQL**: Backend does not use a database — all state is managed via Nostr events.

### Content Safety

- **NSFW detection**: Payment proof images are scanned for illicit content before acceptance.
- **Image size limits**: Proof images are validated to prevent relay rejection from oversized payloads.

## Best Practices for Contributors

1. **Never** hardcode API keys, private keys, or secrets in source code
2. Use `String.fromEnvironment()` for compile-time configuration
3. Use `FlutterSecureStorage` for runtime sensitive data
4. Use `broLog()` instead of `print()` or `debugPrint()`
5. Encrypt all user-facing data with NIP-44 before publishing to Nostr
6. Verify event signatures on all incoming Nostr events
7. Validate authorization before processing status changes
8. Clear sensitive data from clipboard after a short timeout

## Known Security Considerations

### Self-Custodial Risks
Bro uses a self-custodial Lightning wallet (Breez SDK Spark). Users are responsible for their own funds. Lost keys = lost funds.

### Relay Trust
Nostr relays can see event metadata (pubkeys, timestamps, event kinds) but not encrypted content. Users should connect to trusted relays. The app does not verify relay TLS certificates beyond standard platform validation.

### Provider Trust
The P2P model requires some trust in providers. The reputation and collateral systems mitigate risk but do not eliminate it. Users should verify payment receipts independently.
